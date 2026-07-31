# HANDOFF — session continuation notes (2026-07-30)

> Temporary working note for the Claude Code instance picking this up **on the
> Framework laptop itself**. Delete this file once the machine is settled and the
> outstanding items below are done. Nothing here is secret; still, don't add
> secrets to it — it's committed to the repo.

## TL;DR of what happened

A previous automated run built an installer from this repo and it **silently wiped
the Framework's internal NVMe with no prompt** — because `bootc-image-builder
--type anaconda-iso` is *unattended by default* and installs to the first disk it
finds. The machine was recovered by:

1. Installing **stock Fedora Sway Atomic 44** from the official ISO (interactive
   Anaconda), with **btrfs-on-LUKS encryption** chosen in the installer.
2. `rpm-ostree rebase` onto the custom image (unverified → signed), per
   [README](README.md).
3. Booting into the niri session and fixing a series of image bugs (below).

The disk is now **encrypted** (LUKS), which is what the operator wanted all along.
Login user is `mark`. This is the daily driver going forward.

## Repo state

All of the following are **committed and pushed to `origin/main`** this session
(newest first):

| Commit | What |
|--------|------|
| `zsh: install it and make it the login shell in bootstrap` | recipe now installs `zsh`; `kb3lyb-bootstrap` sets it as login shell via `sudo chsh` |
| `recipe: install zsh` | (paired with above) |
| `bootstrap: fix JetBrains Toolbox install racing with tmp cleanup` | Toolbox was launched from a mktemp dir that got `rm -rf`'d immediately, deleting it mid-install; now staged into `~/.local/bin` first |
| `niri: autostart nm-applet + blueman-applet` | waybar tray was empty — no SNI provider was running |
| `Fix anaconda-iso silently wiping disks: force interactive install` | **the big one** — `vm/build-iso.sh` now mounts `vm/iso-config.toml` (empty installer kickstart) to force interactive Anaconda, and refuses to build without it; documented in DESIGN §10 / SETUP §4 |
| `Install Symbols Nerd Font so waybar icons render` | recipe installs `NerdFontsSymbolsOnly` via the BlueBuild fonts module; icons were tofu |
| `bootstrap: fix Homebrew install failing on sudo permission check` | `NONINTERACTIVE=1` suppressed the sudo prompt brew needs to create `/home/linuxbrew`; now primes `sudo -v` first |

CI (`build.yml`) rebuilds + signs + pushes `ghcr.io/mark-iid/kb3lyb-sway:latest` on
push. **Verify the latest Actions run is green before pulling.**

## IMMEDIATE NEXT STEP — pull the newest image

The running machine got an earlier upgrade (for the font fix) but predates the
tray/zsh/JetBrains commits. To land those:

```bash
# If a zsh layer was staged with `rpm-ostree install zsh`:
#   - not yet rebooted into it:   rpm-ostree cleanup -p     (discard the pending layer)
#   - already booted into it:     rpm-ostree uninstall zsh  (remove before upgrading)
# zsh is now baked into the base, so a leftover layer will collide with it.
rpm-ostree status          # check for a pending deployment / LayeredPackages: zsh
rpm-ostree upgrade         # pulls the newest signed :latest (already on the signed ref)
systemctl reboot
```

Run rpm-ostree on the **host shell, not inside a toolbox** (host commands aren't
in toolbox — that surfaced as `rpm-ostree: command not found` earlier). If this
build is bootc-managed instead, the equivalent is `sudo bootc upgrade`.

If `rpm-ostree upgrade` reports "No upgrade available" right after CI goes green,
it's registry propagation — wait a minute and retry.

## VERIFY after the upgrade + reboot

- `rpm-ostree status` — booted deployment is the newest build timestamp.
- Waybar renders real glyphs (battery/network/volume), not tofu. `fc-list | grep -i "symbols nerd"` lists the font.
- Tray populated: network + bluetooth icons appear (nm-applet/blueman-applet autostart).
- `getent passwd "$USER"` ends in `/usr/bin/zsh`; a fresh login drops into zsh.
- `brew` is on PATH in the shell (login shell = zsh, whose `.zshrc` from dotfiles loads brew). If not: `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`.

## OUTSTANDING — post-install tasks (SETUP §6/§7, not yet done)

- Run `kb3lyb-bootstrap` as `mark` (idempotent) to finish dotfiles/brew/JetBrains/shell.
- `fprintd-enroll` — re-enroll fingerprints (not portable).
- `sudo tailscale up` — re-auth the node.
- Hand-restore, encrypted, never via repo/image: `~/.ssh`, `~/.gnupg`,
  `~/.config/rclone/rclone.conf`, atuin key (`~/.local/share/atuin/key`), then `atuin login`.
- Recreate `/var/mnt/data` (Framework expansion card): `/etc/crypttab` entry + mount unit.
  NOTE: the card is a **removable USB device**; if it wasn't plugged in during the
  wipe, its data is intact.
- Evolution: use the **Microsoft 365 / Graph** account type, not EWS.

## OUTSTANDING — still unbaked in the image (SETUP §9)

- Verify the host auto-update timers actually work on a real install
  (`rpm-ostreed-automatic.timer`, `flatpak-update.timer`, user `brew-upgrade.timer`).
- `kanshi` profile for HDMI/external output (presenting).
- Confirm the Electron Wayland flatpak overrides took effect (slack/discord/bitwarden sharp).
- Ghostty terminal (interim is `foot`); `fw-fanctrl` deferred.

## GOTCHAS / lessons from this session

- **Never build the installer ISO without `vm/iso-config.toml`.** Without the
  empty kickstart it's an unattended disk-wiper. `build-iso.sh` now hard-refuses,
  but never "clean up" that file or add autopart/clearpart/reboot to it. When in
  doubt, prefer the stock-Fedora-ISO + `rpm-ostree rebase` path (README) — it uses
  Fedora's trusted interactive Anaconda and never auto-installs.
- The image is **keyboard-driven niri** (no file manager, no start menu). Launcher
  is `Super+D` (fuzzel); terminal `Super+Return` (foot); see
  [files/system/etc/niri/config.kdl](files/system/etc/niri/config.kdl).
- Nothing that belongs in **dotfiles** should be added to the image (DESIGN §6).
  The `/etc/*` configs here are fallbacks that stow'd dotfiles override at runtime.
- These fixes were verified by **reading**, not by running a build/boot. The real
  tests are: the next CI build going green, and the post-upgrade verification above.
