# kb3lyb-sway: custom Fedora Atomic image

Design decisions for a personal BlueBuild image. This document is the source of
truth for *what* is being built and *why*. It was produced in a planning session
and is intended to seed a Claude Code session that does the actual implementation.

Read this whole file before writing any code.

---

## 1. Context

**Machine:** Framework 13 (AMD Ryzen). 2256x1504 internal display, ~200 DPI.
Currently running Aurora DX (Universal Blue, KDE Plasma) at 135% fractional scale.

**Goal:** move to a tiling-WM setup with less UI in the way, without giving up the
things Aurora was quietly handling (codecs, hardware accel, unified updates).

**Why a custom image rather than a hand-modified install:** the operator tracks
Fedora releases as they land. RPM Fusion lags Fedora GA by days to weeks, so
codec overrides fail to depsolve on rebase day. In a recipe, that failure happens
in CI (red X on GitHub, laptop keeps running the last good image) instead of on
the daily driver mid-rebase. The work does not disappear; it moves somewhere
harmless.

**Deployment method: clean wipe and reinstall.** Not a rebase from the existing
Aurora install. This is elective, so nothing has to be preserved in place, but it
also means there is no rollback to the old system once it starts. See §10.

**Existing system facts, and whether they still apply:**

- Kernel arg `amdgpu.dcdebugmask=0x10` (fixes a display engine hang from PSR on
  this APU). **Hardware issue, definitely still needed.** Reapply.
- Text boot, no Plymouth: `plymouth.enable=0 loglevel=3`, `rhgb`/`quiet` removed.
  Still wanted. Reapply.
- `systemd-remount-fs.service` was masked because it failed on composefs-backed
  read-only root. **Do not blindly reapply.** Verify whether it recurs on a fresh
  Sway Atomic install first; this may have been Aurora-specific or since fixed.
- ZFS and v4l2loopback autoload were disabled because Aurora shipped them enabled.
  **Moot on this base.** Drop entirely.
- LUKS full-disk encryption. btrfs subvols on LUKS (`/root`, `/home`, `/var`),
  a separate LUKS ext4 volume at `/var/mnt/data`, ext4 `/boot`, vfat ESP. Now a
  free choice rather than a constraint, but reproducing it is the default plan.
- rclone FUSE mounts under `~` for OneDrive and company/leadership file shares.
  Config and systemd user units need backing up; see §10.
- zsh with starship, atuin, eza/bat/ugrep/zoxide/direnv, plus zsh-autosuggestions
  and zsh-fast-syntax-highlighting. **No oh-my-zsh** (deliberately dropped).
- atuin needs `atuin init` enabled by hand (Aurora ships it commented out), and
  `[search] shells = "all"` in `config.toml`.

**Parity target:** the same `.zshrc` must also work on an Apple Silicon Mac Mini.
Source brew plugins via `$(brew --prefix)`, never a hardcoded path, because Linux
brew lives at `/home/linuxbrew/.linuxbrew` and macOS brew at `/opt/homebrew`.

---

## 2. Locked decisions

| Item | Decision | Notes |
|---|---|---|
| Base image | Fedora Sway Atomic (`sericea`) | Lean base; we add rather than subtract |
| Compositor | **niri**, not sway | No i3 muscle memory to preserve, and niri has xwayland-satellite integration built in, which matters a lot at 135% scale |
| Display scale | 1.35 on eDP-1 | Matches current setup |
| Greeter | greetd + tuigreet | |
| Terminal | Ghostty | Kitty graphics protocol for pasting images into Claude Code; configurable keybinds for Shift+Enter |
| Shell | zsh + starship + brew plugins | No oh-my-zsh, no framework |
| Multiplexer | tmux | Terminal's own tabs/splits go unused; niri splits, tmux persists |
| Registry | GHCR, personal account, public | |
| Version bumps | Automated detection, manual merge | See §5 |
| Config delivery | Baked into the image | Operator wants help with this; see §4 |
| VS Code | Layered RPM from Microsoft repo | Not flatpak (devcontainer/podman friction) |
| JetBrains | Toolbox App in `$HOME` | Not layered, not flatpak. Self-updating |
| Java | SDKMAN in `$HOME` | For SailPoint IIQ work |
| Browsers | Firefox + ungoogled-chromium | Both flatpak |
| Email | Evolution | **See warning in §3** |
| App store | Bazaar (flatpak) | Also solves the missing software center |
| VPN | Tailscale (layered), WireGuard (layered tools + NM), Cisco via openconnect | |
| rclone | Layered RPM | Plus systemd user units for the mounts |
| Fingerprint | fprintd + fprintd-pam + authselect | |
| Screen sharing | Not a requirement | Operator never presents/shares from this machine |
| External display | HDMI only, for LibreOffice presenting | kanshi profile needed |

---

## 3. Things to verify before or during implementation

**Evolution and EWS — this one is time-sensitive.** Microsoft begins blocking
Exchange Web Services in Exchange Online on **October 1, 2026**, with permanent
shutdown April 1, 2027. `evolution-ews` also ships a newer **Microsoft 365 (Graph)**
account backend. When configuring Evolution, use the Microsoft 365 / Graph account
type, **not** the Exchange Web Services type. Validate that it authenticates
against the tenant before committing to Evolution as the mail client. Fallback:
Thunderbird with OAuth2 IMAP/SMTP, or OWA in the browser.

Evolution pulls GTK and evolution-data-server, but not a desktop environment.
It runs fine under niri. The GNOME dependency concern is unfounded.

**Package availability on current Fedora.** Verify each of these exists in Fedora
repos at the target version, and identify a COPR only where it does not:

- `niri` (should be in Fedora repos)
- `ghostty` (may require COPR, e.g. `pgdev/ghostty`)
- `greetd` and tuigreet (tuigreet packaging name varies; may require COPR)
- `xwayland-satellite` (check whether niri's packaging pulls it automatically)
- `bazaar`

**Framework battery charge limit.** On Framework 13 AMD this is settable in the
BIOS directly. Do that first and skip `fw-ectool` entirely unless something
specific is missing. Fan control (`fw-fanctrl`) is fiddly on atomic and is
explicitly deferred — do not include it in the first build.

**Containers.** Requires a decision the operator flagged as unclear:

- `toolbox` ships with the base and is fine for throwaway Fedora shells.
- `distrobox` is worth adding if non-Fedora images are wanted. Not required.
- **Devcontainers in VS Code are separate from both.** The Dev Containers
  extension drives podman/docker directly. Needs `podman` (present in base) plus
  either `podman-docker` or the extension configured with `docker.dockerPath`
  set to podman, and the podman socket enabled as a user unit. Get this working
  and verified, because it's an actual workflow dependency.

---

## 4. HiDPI: the part most likely to go wrong

Target is `scale 1.35` on the internal panel. Wayland-native apps render sharp at
that scale via `fractional-scale-v1`. The problem is XWayland only.

Known-native (no action needed): Ghostty, Firefox, foot, most GTK4/Qt6 apps.

Electron apps (VS Code, Slack, Discord) default to XWayland and must be forced
native with `--enable-features=UseOzonePlatform --ozone-platform=wayland`, via
flatpak overrides for the flatpak ones and `*-flags.conf` for layered ones. Do
this; it's the difference between sharp and soft for three daily apps.

Steam is XWayland forever and will look soft. Accepted.

For remaining X11 stragglers, set toolkit-side scaling so they render at native
resolution and scale themselves, rather than being bitmap-scaled by the
compositor:

- GTK3: `GDK_SCALE=2` **and** `GDK_DPI_SCALE=0.675` (GDK_SCALE is integer-only;
  this combination yields an effective 1.35)
- Qt: `QT_SCALE_FACTOR=1.35`
- `Xft.dpi`: approximately 130

**Critical gotcha:** these must live in `~/.config/environment.d/` or the
compositor's exec chain. Putting them in `.zshrc` does nothing, because apps
launched from a launcher never source a shell rc file.

**Mixed DPI caveat:** X11 scaling is global, so when the HDMI output is attached
at 1x for presenting, XWayland apps will be the wrong size on one of the two
screens. LibreOffice under Wayland is unaffected. This is a known, accepted
limitation given HDMI is only used for presenting.

---

## 5. Update and release strategy

- `image-version` is **pinned explicitly** in `recipe.yml`. The base image is
  never pointed at a floating tag.
- Automation should be a **scheduled workflow that detects a new Fedora Atomic
  release and opens a PR** bumping `image-version`. The operator merges it. This
  gives automatic detection without letting Fedora pick the upgrade date.
- Nightly rebuild against the current pinned base, so upstream Fedora updates
  flow through without any action.
- On the host: enable `rpm-ostreed-automatic.timer` with the staging policy.
  There is no software center and no `uupd` on this base, so also add user timers
  for `flatpak update -y` and `brew upgrade`. All three were previously handled by
  Aurora's uupd in one unit; their absence will be noticed on day two.
- Before any major version rebase, run `ostree admin pin 0` so a known-good
  deployment survives repeated reboots.
- BlueBuild publishes timestamped tags alongside `latest`. Rolling back to a
  specific known-good build from weeks ago is preferable to `rpm-ostree rollback`,
  which only reaches the single previous deployment.

---

## 6. Config-baking approach (operator requested help here)

Recommended split, to avoid rebuilding the image for every keybind tweak:

- **Baked into the image** via the `files` module: sane defaults for niri,
  waybar, mako, tuigreet, Ghostty, and a minimal `.zshrc`. Ship these to
  `/usr/etc/skel` or `/etc/skel` so a fresh user gets a working system.
- **Live in the existing dotfiles repo, deployed with GNU stow:** the configs
  actually being iterated on. The operator already uses stow; do not invent a
  second mechanism. A bootstrap script clones the repo and runs `stow`.

Baked defaults and stow must not collide. Baked config goes to `/etc/skel` or
`/usr/etc/skel` and provides a working system for a fresh user; stow then
overlays the real config into `$HOME`. If stow refuses to link because a real
file is in the way, the baked default was placed too aggressively.

The test: if changing it should require a reboot, bake it. If changing it should
take effect on `niri msg action reload-config`, keep it in git.

Do not bake secrets, tokens, or rclone credentials into the image. The image is
public.

**Desktop session behavior lives in the dotfiles repo, not here** (per the split
above): global dark mode (GTK `settings.ini` + `gsettings color-scheme prefer-dark`),
idle-lock (swayidle → gtklock), the tray applets (nm-applet/blueman), clipboard
persistence (wl-clip-persist), and a `graphical-session-bind.service`.

That last one is a non-obvious workaround worth recording. greetd launches niri as a
bare `niri --session`, **not** via `niri.service` — so `graphical-session.target` is
never activated, and because `xdg-desktop-portal` has
`Requisite=graphical-session.target`, the portal never starts. A dead portal silently
breaks the dark-mode `color-scheme` signal (Electron/libadwaita apps), file-chooser
portals, and screencasting. The dotfiles ship a tiny oneshot user unit that
`BindsTo`/`Before` `graphical-session.target` (mirroring `niri.service`) and start it
from niri `spawn-at-startup` to pull the target up. A cleaner fix would be to launch
niri via `niri.service` from greetd, but that's login-critical and untested — the
dotfiles workaround is low-risk and reversible.

Note also the fingerprint↔keyring interaction (SETUP §6): fingerprint login never
captures a password, so `pam_gnome_keyring` can't unlock the login keyring — the
chosen resolution is a passwordless login keyring (relying on LUKS FDE).

---

## 7. Recipe skeleton

Starting point only. Every value needs verification against current BlueBuild
docs and current Fedora package names.

```yaml
name: kb3lyb-sway
description: Framework 13 AMD, niri, minimal
base-image: quay.io/fedora-ostree-desktops/sericea
image-version: 42   # pinned; bumped by PR, never floating

modules:
  - type: files
    files:
      - source: system
        destination: /

  - type: rpm-ostree
    repos:
      # tailscale, vscode, and any COPRs go here
      # use %OS_VERSION% so repo URLs follow the version bump
    install:
      # compositor + session
      - niri
      - xwayland-satellite
      - greetd
      - waybar
      - mako
      - fuzzel
      - kanshi
      - cliphist
      - grim
      - slurp
      - gtklock
      # hardware + system
      - fprintd
      - fprintd-pam
      - brightnessctl
      - playerctl
      - power-profiles-daemon
      - blueman
      - network-manager-applet
      - NetworkManager-openconnect-gnome
      - wireguard-tools
      - tailscale
      # userland
      - zsh
      - tmux
      - rclone
      - fuse3
      - code
      - evolution
      - evolution-ews

  # codecs: RPM Fusion + ffmpeg swap + freeworld VA drivers.
  # Most fragile module. Expect this to be what breaks on a version bump.
  - type: rpm-ostree
    repos:
      - https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-%OS_VERSION%.noarch.rpm
      - https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-%OS_VERSION%.noarch.rpm
    replace:
      - from-repo: rpmfusion-free
        packages:
          - ffmpeg
      - from-repo: rpmfusion-free
        packages:
          - mesa-va-drivers-freeworld

  - type: default-flatpaks
    notify: true
    system:
      install:
        - org.mozilla.firefox
        - io.github.ungoogled_software.ungoogled_chromium
        - com.slack.Slack
        - com.discordapp.Discord
        - com.valvesoftware.Steam
        - org.libreoffice.LibreOffice
        # bazaar - verify flatpak ID
      remove: []

  - type: script
    scripts:
      - authselect-fingerprint.sh
      - brew-install.sh
      - electron-wayland-flags.sh

  - type: systemd
    system:
      enabled:
        - greetd.service
        - rpm-ostreed-automatic.timer
        - fprintd.service
        - tailscaled.service

  - type: signing
```

---

## 8. Rules for the implementation session

1. **Never run `rpm-ostree rebase` on the daily driver.** Build and validate
   images only. The operator performs rebases manually, with a pinned deployment.
2. Iterate locally with the BlueBuild CLI in a distrobox
   (`ghcr.io/blue-build/cli`). Do not use GitHub Actions as the edit-compile-test
   loop.
3. Read the actual machine before asking about it: `rpm-ostree status` for kargs
   and layered packages, `flatpak list` for what's really in use, the existing
   `.zshrc`, and the existing rclone systemd units.
4. Verify package names against the real repos rather than assuming. Several
   names in §7 are guesses.
5. Prefer `$HOME` over layering, and layering over overrides. Overrides are the
   only category that carries a recurring maintenance cost.

## 9. Suggested first tasks

1. Scaffold from `blue-build/template` and get a trivial image building locally.
2. Add the codec module alone and confirm it depsolves. This is the risky one;
   find out early.
3. Add niri, greetd/tuigreet, waybar, and enough config to reach a usable session.
4. Test in a VM. Keep testing in a VM. The laptop is not touched until a VM boots
   this image to a usable niri session with working audio and networking.
5. Layer everything else once a session boots.
6. Build out the dotfiles repo and verify `stow` deploys cleanly onto a fresh
   user in the VM.
7. Wire up the scheduled version-bump PR workflow.
8. Generate an installer ISO from the image.
9. Install to an external USB SSD and daily-drive it for a week on real hardware.
10. Only then: back up, verify the backup, and wipe the internal drive.

---

## 10. Clean install: sequencing and backup

The laptop is the daily driver and there is no rollback once it is wiped. Order
matters more than anything else in this document.

### Disk topology (resolved)

`/var/mnt/data` is a **Framework storage expansion card**, so it is a separate,
physically removable, USB-attached device. Two consequences:

**Pull the card before booting the installer.** Do not rely on being careful at
Anaconda's disk selection screen. A device that is not plugged in cannot be
selected by mistake. Reinsert after the install completes.

**It cannot serve as both the backup target and the USB test-install target.** A
second external drive is needed for the week-long hardware test in the section
below, or the backup has to live somewhere else. Expansion cards are USB 3.2
Gen 2 and workable, but a 2280 NVMe in a USB-C enclosure is the better test rig.

### Protecting the backup itself

The expansion card is LUKS ext4 and is currently the only backup target. Two
things follow:

- **Back up its LUKS header** with `cryptsetup luksHeaderBackup` and store that
  copy somewhere other than the card. A corrupted header means the backup is
  unrecoverable, which is a bad way to discover that a single point of failure
  was a single point of failure.
- **Do not store the only copy of the card's passphrase on the machine being
  wiped.** Obvious in hindsight, easy to do at 11pm.
- The irreplaceable items are tiny (atuin key, SSH and GPG keys, rclone config).
  Put a second encrypted copy on the homelab TrueNAS or in OneDrive. Everything
  else on the card is reconstructible; those are not.

### Restore steps specific to this volume

After reinstall, remounting `/var/mnt/data` means recreating the `/etc/crypttab`
entry and the corresponding mount unit or fstab line. Capture the current ones
before wiping rather than reconstructing them from memory.

### Install path

Install from an ISO generated from the custom image, so first boot is already the
final system. Fall back to installing stock Fedora Sway Atomic and rebasing
(unverified registry first, then the signed ref) if ISO generation gives trouble.

**Important distinction:** the ISO produced by BlueBuild's ISO generation and by
`bootc-image-builder --type anaconda-iso` is an **Anaconda installer**, not a live
desktop session. Booting it does not get you a working niri desktop to poke at.
A true live ISO is possible with bootc-image-builder but requires adding
`dracut-live` and `squashfs-tools` to the image and rebuilding the initramfs with
the `dmsquash-live` module. There is also an open upstream request for a plain
`iso` target that boots the container image directly, CoreOS-style, but that is
distinct from `anaconda-iso` and not something to depend on.

**Critical: `anaconda-iso` is UNATTENDED by default and will silently wipe a
disk.** With no kickstart, `bootc-image-builder --type anaconda-iso` emits an
installer that installs to the *first disk it finds* — no prompt, no target
selection, no encryption. This is not hypothetical: a build that trusted an
earlier (wrong) claim of interactivity overwrote a live machine's internal NVMe
this exact way. `vm/build-iso.sh` therefore mounts `vm/iso-config.toml`, whose
empty `[customizations.installer.kickstart]` forces Anaconda to run interactively
(bootc-image-builder still injects the `ostreecontainer` line that installs the
image; an empty kickstart adds *no* `autopart`/`clearpart`/`reboot`, so it stops
at the hub and waits). The build script refuses to run if that config is missing.
**Never build this ISO without it, and never add autopart/clearpart/reboot to it.**
If in any doubt, use the stock-Fedora-plus-rebase fallback above — Fedora's own
Anaconda is interactive and trusted, and never runs unattended.

### Hardware validation before wiping (do this, not a live CD)

A VM cannot test the things most likely to fail on this specific machine: the
fingerprint reader, the 200 DPI panel at 1.35 scale, the amdgpu PSR hang the
`dcdebugmask` karg works around, HDMI output for presenting, wifi, bluetooth
audio, and suspend/resume. A live ISO tests those only briefly and cannot test
persistence, fprintd enrollment, or the update path at all.

**Better: do a full install onto an external USB SSD and daily-drive it for a
week.** Same installer ISO, different target disk. Nothing on the internal NVMe is
touched.

- Use an external NVMe in a USB-C 10Gbps enclosure. **Not a USB flash drive** —
  a flash drive will make the whole system feel terrible and produce a false
  negative on the design.
- Framework's own expansion-card SSDs work but are slower; the 2280 enclosure is
  the better test rig.
- Boot menu on the Framework 13 is F12, or set boot order in BIOS.
- **Anaconda target selection is the dangerous step.** Confirm the target device
  by serial/size before proceeding, especially if `/var/mnt/data` turns out to
  live on the internal NVMe.
- This also exercises the real install flow: partitioning, LUKS setup, first
  boot, greeter. Those are worth rehearsing once before doing them for keeps.
- Secure Boot can stay enabled. Fedora's shim and kernel are signed and no
  out-of-tree kernel modules are planned (no NVIDIA, no akmods). If akmods ever
  get added, that changes and a MOK enrollment becomes necessary.

Only after a week on the USB install with no unresolved problems should the
internal drive be wiped.

### Backup checklist

Not dotfiles. These are the things that are easy to forget and painful to lose:

- **Atuin encryption key** (`~/.local/share/atuin/key`). Unrecoverable if lost;
  the synced history becomes undecryptable. Back this up first.
- `~/.ssh` and `~/.gnupg`.
- `~/.config/rclone/rclone.conf` (contains OAuth tokens).
- WireGuard configs and any NetworkManager connection profiles worth keeping.
- Browser profiles, or confirm everything is in sync and skip.
- Evolution/Thunderbird profile, or plan to re-authenticate.
- VS Code settings and an extension list (`code --list-extensions`).
- JetBrains config and any IDE licenses.
- `brew bundle dump` for the brew package list.
- `flatpak list --app --columns=application` and `~/.var/app` for flatpak app data.
- Ham radio logs and any application data under `~/.local/share`.
- Contents of `/etc` worth diffing later, especially anything hand-edited.
- Anything on `/var/mnt/data` that only exists there.

**Secrets rule:** the GHCR image is public and the dotfiles repo may be. Nothing
in the list above with a token, key, or credential goes into either. Those move
by hand, encrypted, to storage the operator controls.

**Not portable, plan to redo:** fingerprint enrollment (re-enroll with
`fprintd-enroll`), Tailscale node identity (just re-authenticate), LUKS keys
(new install, new keys).

### Verify before wiping

Restore the backup into the VM and confirm it produces a working environment
there. A backup that has not been restored once is a hypothesis.
