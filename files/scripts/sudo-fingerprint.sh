#!/usr/bin/env bash
# DESIGN §2/§7: allow fingerprint authentication for `sudo`, and ONLY for sudo.
# Runs at image build time, AFTER the dnf module that installs fprintd-pam.
#
# WHY NOT THE GLOBAL authselect FEATURE
#
# `authselect enable-feature with-fingerprint` is all-or-nothing: it puts
# pam_fprintd into system-auth, which greetd, sudo AND polkit all include. That
# is what broke the login keyring — `sufficient` short-circuits pam_unix, so
# LOGIN captured no password token and pam_gnome_keyring had nothing to unlock
# with, which is what forced the blank-password keyring this setup used to
# carry. See files/scripts/authselect-fingerprint.sh for the full history.
#
# The cost was always specific to the LOGIN path. sudo does not unlock the login
# keyring and never did, so scoping the finger to sudo alone reintroduces none
# of it: login still goes through pam_unix, the keyring is still properly
# encrypted and auto-unlocked. The earlier writeup treated the global feature's
# cost as if it were sudo's cost; it is not.
#
# WHY A SCRIPT AND NOT A BAKED files/system/etc/pam.d/sudo
#
# Because /etc/pam.d/sudo is an rpm %config file:
#
#     $ rpm -qc sudo
#     /etc/pam.d/sudo          <-- marked %config, owned by the sudo package
#
# whereas /etc/pam.d/gtklock is shipped by gtklock but NOT marked %config, which
# is why baking that one wholesale is safe. Shipping our own full copy of a
# %config file would silently PIN the sudo PAM stack: if a future Fedora sudo
# update adds a line (a pam_faillock rollout, say), our copy would override it
# and nothing would ever say so. Pinning a stale PAM stack for the privilege
# boundary is a bad trade for the convenience of a static file.
#
# So this inserts one line into whatever the rpm shipped and hard-fails if the
# file does not look the way it is expected to — the same "assert, then modify,
# never silently no-op" shape as kismet-suid-scope.sh.
#
# FAILURE MODE. `sufficient` means: finger recognised -> auth succeeds. If
# fprintd is not enrolled, not running, times out, or fails, the stack falls
# through to the normal `include system-auth` and sudo prompts for the password.
# It cannot lock you out of sudo.
#
# KNOWN ANNOYANCE, ACCEPTED DELIBERATELY: `sudo` in an SSH session will also
# reach for the reader and sit there asking for a finger you cannot physically
# provide, until it times out and falls back to the password. The guarded
# variant (skip pam_fprintd unless XDG_SEAT=seat0 via pam_succeed_if) was
# considered and NOT taken — it is more moving parts in the sudo stack, and the
# fallback already works. If remote sudo becomes irritating, that is the fix.
#
# Per-user enrollment is still a runtime step and cannot be baked:
#
#     fprintd-enroll        # then: sudo -k && sudo true   to test
#
set -euo pipefail

readonly PAM_FILE='/etc/pam.d/sudo'
readonly FPRINTD_MODULE='/usr/lib64/security/pam_fprintd.so'
readonly FPRINTD_LINE='auth       sufficient   pam_fprintd.so'

# Fail loudly rather than no-op. Module order is build order; a silent skip here
# would ship an image that claims fingerprint sudo and does not have it.
if [[ ! -f $PAM_FILE ]]; then
  echo "sudo-fingerprint: $PAM_FILE is missing" >&2
  exit 1
fi

if [[ ! -f $FPRINTD_MODULE ]]; then
  echo "sudo-fingerprint: $FPRINTD_MODULE absent — fprintd-pam is not installed," \
       'so module ordering is wrong' >&2
  exit 1
fi

# Idempotent: re-running must not stack duplicate lines.
if grep -q 'pam_fprintd\.so' "$PAM_FILE"; then
  echo "sudo-fingerprint: pam_fprintd already present in $PAM_FILE, nothing to do"
  exit 0
fi

# Assert the shape we are about to edit. Fedora's stock file has exactly one
# auth line, `auth include system-auth`. If that ever changes, stop rather than
# guess where the finger belongs in an unfamiliar stack.
auth_lines="$(grep -c '^auth' "$PAM_FILE" || true)"
if [[ $auth_lines -ne 1 ]]; then
  echo "sudo-fingerprint: expected exactly 1 auth line in $PAM_FILE, found $auth_lines —" \
       'the packaged stack changed, review before editing' >&2
  exit 1
fi

if ! grep -qE '^auth[[:space:]]+include[[:space:]]+system-auth[[:space:]]*$' "$PAM_FILE"; then
  echo "sudo-fingerprint: the single auth line in $PAM_FILE is not the expected" \
       "'auth include system-auth' — review before editing" >&2
  exit 1
fi

# Insert ABOVE the include, so the finger is tried before falling through to
# pam_unix. Order matters: below the include it would never be reached.
sed -i "/^auth[[:space:]]\+include[[:space:]]\+system-auth[[:space:]]*$/i $FPRINTD_LINE" "$PAM_FILE"

# Verify rather than trust sed's exit code.
if ! grep -q 'pam_fprintd\.so' "$PAM_FILE"; then
  echo "sudo-fingerprint: insertion reported success but $PAM_FILE is unchanged" >&2
  exit 1
fi

if [[ "$(grep -m1 '^auth' "$PAM_FILE")" != "$FPRINTD_LINE" ]]; then
  echo "sudo-fingerprint: pam_fprintd is present but is not the FIRST auth line —" \
       'it would never be reached' >&2
  exit 1
fi

echo "sudo-fingerprint: pam_fprintd scoped to $PAM_FILE (login and polkit unchanged)"
