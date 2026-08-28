#!/usr/bin/env bash
# Postconditions for the built image. Runs LAST, after every other module.
#
# WHY THIS EXISTS. A green build proves the recipe depsolved. It does not prove
# the image is the one we meant to build, and this repo has already shipped at
# least three defects that a depsolve gate cannot see:
#
#   * The `files` module used to run FIRST, so any config it laid down that a
#     later rpm also owned was silently replaced by the package default.
#     /etc/pam.d/gtklock shipped as the stock file and the build was green.
#   * `unrar` resolves to RPM Fusion's RARLAB build (7.x) ONLY because the codec
#     module runs first and persists the rpmfusion repos. Reorder the modules and
#     it quietly degrades to Fedora's 0.3.x unrar-free wrapper — no build error,
#     RAR extraction just stops working.
#   * A seeded flatpak override on Discord puts its renderer in a segfault loop.
#     Nothing in the build would notice the file coming back.
#
# Each check below corresponds to a hazard that is documented in prose somewhere
# in this repo. Prose cannot fail a build. These can.
#
# WHAT THIS CANNOT CATCH. Everything here is evaluated inside the build
# container, so it only sees build-time truth. Anything whose value is resolved
# again on the installed system — most importantly NUMERIC uid/gid, which is what
# a chown/chgrp actually records — can be correct here and wrong on the laptop.
# That is not hypothetical: see the kismet group note in kismet-suid-scope.sh.
# Checks of that class belong on the host, not here.
#
# Style: this does NOT `set -e`. Every assertion runs so one build reports every
# problem, and the script exits nonzero at the end if any of them failed.
set -uo pipefail

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
# Non-fatal. For conditions that are real but not ours to fix, where failing the
# build would only teach everyone to ignore the output.
warn() { printf '  warn %s\n' "$1" >&2; }

# assert <description> <command...> — passes when the command succeeds.
assert() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

# refute <description> <command...> — passes when the command FAILS. A separate
# helper rather than a leading `!`, which is shell syntax and not a command, so it
# cannot survive being passed through "$@".
refute() { if "${@:2}"; then fail "$1"; else pass "$1"; fi; }

# assert_file_has <description> <file> <extended-regex>
assert_file_has() {
  if [ -r "$2" ] && grep -Eq "$3" "$2"; then pass "$1"; else fail "$1 ($2)"; fi
}

echo "image-assert: checking postconditions"

# --- Baked config survived the module ordering -------------------------------
# The `files` module must run after every dnf module. These are the paths an rpm
# also owns, i.e. the ones that get silently reverted if that ordering breaks.
for f in /etc/niri/config.kdl /etc/greetd/config.toml /etc/xdg/waybar/config \
         /etc/xdg/mako/config /etc/xdg/foot/foot.ini /etc/rpm-ostreed.conf; do
  assert "baked config present and non-empty: $f" test -s "$f"
done
assert_file_has "rpm-ostreed stages updates rather than applying them" \
  /etc/rpm-ostreed.conf '^[[:space:]]*AutomaticUpdatePolicy[[:space:]]*=[[:space:]]*stage'

# --- Fingerprint scoping (the login-keyring invariant) ------------------------
# pam_fprintd belongs in exactly two places. It must NOT be in system-auth: as
# `sufficient` there it short-circuits pam_unix, no password token is captured,
# and the login keyring cannot be unlocked. That is the whole reason the global
# authselect feature stays off.
assert_file_has "fingerprint wired into the screen locker" \
  /etc/pam.d/gtklock 'pam_fprintd\.so'
assert_file_has "fingerprint wired into sudo" \
  /etc/pam.d/sudo 'pam_fprintd\.so'
if grep -q 'pam_fprintd' /etc/pam.d/system-auth 2>/dev/null; then
  fail "pam_fprintd leaked into system-auth — this breaks the login keyring"
else
  pass "system-auth is free of pam_fprintd (login keyring stays encrypted)"
fi

# --- Codec swap actually happened --------------------------------------------
# The most fragile module. If the swap silently no-ops we get the free builds
# back and lose hardware VA-API, with a green build either way.
assert "ffmpeg (RPM Fusion) installed"           rpm -q --quiet ffmpeg
refute "ffmpeg-free replaced, not co-installed"  rpm -q --quiet ffmpeg-free
assert "mesa-va-drivers-freeworld installed"     rpm -q --quiet mesa-va-drivers-freeworld
refute "mesa-va-drivers replaced"                rpm -q --quiet mesa-va-drivers

# --- unrar resolved to RARLAB's build, not the unrar-free wrapper -------------
# Fedora ships unrar 0.3.x (a wrapper around unrar-free, no RAR5); RPM Fusion
# ships RARLAB's 7.x. Version comparison picks the latter ONLY while the codec
# module runs first. A leading 0 here means the module order regressed.
unrar_major=$(rpm -q --qf '%{VERSION}' unrar 2>/dev/null | cut -d. -f1)
if [ "${unrar_major:-0}" -ge 1 ] 2>/dev/null; then
  pass "unrar is RARLAB's build (${unrar_major}.x), not the unrar-free wrapper"
else
  fail "unrar degraded to Fedora's unrar-free wrapper — check module ordering"
fi

# --- kismet setuid surface ----------------------------------------------------
# kismet-suid-scope.sh must have narrowed the capture helpers. The invariant is
# "no helper is both setuid and world-executable"; the group it was narrowed TO
# is deliberately not asserted here, because the recorded gid is a build-time
# number that means something else on the installed system.
if [ -z "$(find /usr/bin -name 'kismet_cap_*' -perm -4000 -perm -o+x -print -quit 2>/dev/null)" ]; then
  pass "no kismet capture helper is both setuid and world-executable"
else
  fail "a setuid kismet helper is still world-executable"
fi

# --- The wrapper both flatpak timers exec ------------------------------------
# Neither timer may call `flatpak update` directly; the bare command reports
# success while updating nothing. A missing wrapper means silent no-op updates.
assert "flatpak update wrapper is present and executable" \
  test -x /usr/bin/kb3lyb-flatpak-update

# --- Discord must have NO seeded flatpak override ----------------------------
# Any override on this app — even sockets alone — segfaults its renderer in a
# loop behind a stuck "Discord Updater" splash. Bisected on real hardware.
assert "no seeded flatpak override for Discord" \
  test ! -e /usr/share/factory/var/lib/flatpak/overrides/com.discordapp.Discord
if grep -q '^[^#]*com\.discordapp\.Discord' /usr/lib/tmpfiles.d/kb3lyb-flatpak-overrides.conf 2>/dev/null; then
  fail "tmpfiles.d would seed a Discord override — this breaks Discord"
else
  pass "tmpfiles.d seeds no Discord override"
fi

# --- Pinned GIDs --------------------------------------------------------------
# A chgrp records a number. Any group that owns a file in /usr and is allocated
# dynamically will get a different number in the build container than on an
# installed machine, and the file then belongs to a group that means something
# else there. Three of them were wrong at once before this was pinned; the
# kismet capture helpers and /usr/bin/dumpcap were both hardened into
# unusability, with a green build. See /usr/lib/sysusers.d/00-kb3lyb-gids.conf.
PIN_FILE=/usr/lib/sysusers.d/00-kb3lyb-gids.conf
assert "pinned-GID file present" test -r "$PIN_FILE"
pinned_gids=""
if [ -r "$PIN_FILE" ]; then
  while read -r kind name want _rest; do
    [ "$kind" = "g" ] || continue
    case "$want" in ''|*[!0-9]*) continue ;; esac
    pinned_gids="$pinned_gids $want"
    have=$(getent group "$name" | cut -d: -f3)
    if [ -z "$have" ]; then
      pass "group '$name' not created in this build (nothing stamped with it)"
    elif [ "$have" = "$want" ]; then
      pass "group '$name' is pinned at $want"
    else
      fail "group '$name' is $have, should be $want — pin-gids.sh did not run or failed"
    fi
  done < "$PIN_FILE"
fi

# Anything else in /usr owned by a dynamically-allocated group has the same
# latent bug. Statically-allocated groups (gid < 201, e.g. lp/lock/dbus) are
# stable across systems and are fine.
#
# This WARNS rather than fails, because the remaining cases come from the base
# image — sssd, polkitd, openvpn and brlapi all ship /usr files owned by their
# own dynamically-allocated groups. Pinning those would mean renumbering groups
# that polkit and sssd authenticate against, to fix a bug we did not introduce,
# on files we do not build. Not worth the blast radius. Anything OURS that shows
# up here should be added to the pin file instead.
unpinned=""
for gid in $(find /usr -xdev \! -gid 0 -printf '%G\n' 2>/dev/null | sort -u); do
  case "$gid" in *[!0-9]*|'') continue ;; esac
  [ "$gid" -ge 201 ] 2>/dev/null || continue
  getent group "$gid" >/dev/null 2>&1 || continue    # unnamed: base-image inheritance
  case " $pinned_gids " in *" $gid "*) continue ;; esac
  unpinned="$unpinned $gid($(getent group "$gid" | cut -d: -f1))"
done
if [ -n "$unpinned" ]; then
  warn "unpinned dynamic group(s) own files in /usr:$unpinned"
  warn "  ^ base-image groups are expected here; add anything of OURS to $PIN_FILE"
else
  pass "every dynamic group owning files in /usr is pinned"
fi

# The fonts module runs as the build user; pin-gids.sh resets what it leaves.
if [ -n "$(find /usr -xdev -gid +999 -print -quit 2>/dev/null)" ]; then
  fail "files in /usr are owned by a build-user gid (>=1000)"
else
  pass "no /usr file carries a build-user gid"
fi

assert "GID reconcile migration present and executable" \
  test -x /usr/bin/kb3lyb-gid-reconcile

# --- Staleness alarm ----------------------------------------------------------
# The update model's safety property (a broken build leaves the laptop on the last
# good image) is silent by design. This is the only thing that breaks that silence.
assert "image staleness checker present and executable" \
  test -x /usr/bin/kb3lyb-image-age
# It is written against jq, which until recently was present only as a transitive
# dependency of the base image's grimshot. Declared now, and asserted so a base
# bump that drops it fails here rather than at runtime.
assert "jq present (kb3lyb-image-age and the dotfiles comms script need it)" \
  rpm -q --quiet jq

# --- Kernel arguments ---------------------------------------------------------
# dcdebugmask disables PSR on this APU and works around a display-engine hang.
# Losing it does not fail anything at build time; it hangs the laptop.
assert_file_has "amdgpu PSR workaround karg present" \
  /usr/lib/bootc/kargs.d/00-kb3lyb.toml 'amdgpu\.dcdebugmask=0x10'

# --- Icon font for the bar ----------------------------------------------------
# waybar's style.css asks for "Symbols Nerd Font" by name; without it every
# status glyph renders as tofu.
assert "Symbols Nerd Font installed for waybar" \
  sh -c 'find /usr/share/fonts -iname "SymbolsNerdFont*" -print -quit | grep -q .'

# --- Unit enablement ----------------------------------------------------------
# `systemctl is-enabled` reads unit files and symlinks; it needs no running
# manager, so it works inside the build container.
for u in greetd.service kb3lyb-console-font.service tailscaled.service \
         rpm-ostreed-automatic.timer flatpak-update.timer kb3lyb-power-profile.timer; do
  assert "system unit enabled: $u" sh -c "systemctl is-enabled '$u' >/dev/null 2>&1"
done
for u in brew-upgrade.timer flatpak-update-user.timer kb3lyb-image-age.timer; do
  assert "user unit enabled globally: $u" \
    sh -c "systemctl --global is-enabled '$u' >/dev/null 2>&1"
done
# The base ships SDDM; greetd replaces it. Both enabled would race for the tty.
assert "sddm disabled in favour of greetd" \
  sh -c '[ "$(systemctl is-enabled sddm.service 2>/dev/null)" != enabled ]'

# --- Superseded signing key -------------------------------------------------
# The key was rotated 2026-08-27, so every GHCR tag built before then is signed
# with a key no host trusts any more. SETUP §8's rollback procedure repoints
# policy.json at this file to reach one of those images; it is baked in precisely
# so that recovery needs no network and no repo checkout. Lose the file and the
# documented procedure silently stops working — at the exact moment it is needed,
# which is when a current build has gone bad.
assert "superseded signing key available for rollback" \
  sh -c 'grep -q "BEGIN PUBLIC KEY" /etc/pki/containers/kb3lyb-sway-old.pub'
# The two must not be the same key, or the rollback path trusts nothing extra and
# the file is cargo cult. Guarded because the `signing` module runs AFTER this
# script (see the recipe comment above image-assert), so on a normal build the
# active key is not laid down yet and there is genuinely nothing to compare. An
# unguarded `cmp` would "pass" on the missing file — an assertion that can only
# succeed is worse than none, since it reads as coverage.
if [ -r /etc/pki/containers/kb3lyb-sway.pub ]; then
  refute "superseded key differs from the active one" \
    sh -c 'cmp -s /etc/pki/containers/kb3lyb-sway-old.pub /etc/pki/containers/kb3lyb-sway.pub'
fi

# -----------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  echo "image-assert: $fails postcondition(s) FAILED — the image is not what the recipe describes" >&2
  exit 1
fi
echo "image-assert: all postconditions hold"
