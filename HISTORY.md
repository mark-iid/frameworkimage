# kb3lyb-sway: planning archive

Frozen record of the planning phase, moved out of [`DESIGN.md`](DESIGN.md) so that
document holds only decisions that are still load-bearing.

**Nothing here is authoritative.** These sections describe checks that have since
been carried out, and draft values that the real recipe superseded — several are
now actively wrong (§7 still names the retired `sericea` base and Fedora 42). They
are kept because the *reasoning* is occasionally worth rereading, not because the
content is true.

For current truth: [`recipes/recipe.yml`](recipes/recipe.yml) for what ships,
[`SETUP.md`](SETUP.md) for how to build/test/install it, and
[`DESIGN.md`](DESIGN.md) for why it is shaped the way it is.

Section numbers are kept as they were in DESIGN.md so existing `§3` / `§7`
references still resolve here.

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

## 7. Recipe skeleton

Starting point only, and now **superseded by the real recipe**,
[`recipes/recipe.yml`](recipes/recipe.yml). The skeleton below still names the old
`sericea` base and Fedora 42 and carries unverified package guesses; the shipping
image is on `sway-atomic` at a later Fedora with corrected names. Kept for
historical context — read the recipe for current truth.

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

