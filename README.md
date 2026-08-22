# kb3lyb-sway &nbsp; [![build](https://github.com/mark-iid/frameworkimage/actions/workflows/build.yml/badge.svg)](https://github.com/mark-iid/frameworkimage/actions/workflows/build.yml)

A personal [Fedora Sway Atomic](https://fedoraproject.org/atomic-desktops/sway/)
image, built with [BlueBuild](https://blue-build.org/) and tailored for a
**Framework 13 (AMD Ryzen)** laptop running a **niri** tiling session.

It exists so that the fragile parts of a daily-driver setup — codec swaps against
RPM Fusion, hardware quirks, the whole compositor stack — are resolved in CI
(a red X on GitHub, the laptop keeps running the last good image) instead of on
the machine mid-rebase. The image is published to
**`ghcr.io/mark-iid/kb3lyb-sway`** and rebuilt nightly against its pinned Fedora
base so upstream updates flow through untouched.

> This is a personal image built for one specific machine. You're welcome to read
> it, fork it, or borrow from it, but it is not intended as a general-purpose
> distro — hardware kargs, scaling, and package choices are all Framework-13-AMD
> specific.

## What's inside

- **Base:** `quay.io/fedora-ostree-desktops/sway-atomic`, pinned by Fedora version
  in [`recipes/recipe.yml`](recipes/recipe.yml) (never a floating tag; bumped by an
  automated PR — see DESIGN §5).
- **Session:** niri + xwayland-satellite, greetd + tuigreet, waybar, mako, fuzzel,
  gtklock, kanshi, grim/slurp, cliphist. Ghostty is the primary terminal (foot as a
  dependency-light fallback).
- **Codecs:** RPM Fusion `ffmpeg` swap + `mesa-va-drivers-freeworld` for hardware
  VA-API. The most fragile module; isolated in [`recipes/common/codecs.yml`](recipes/common/codecs.yml)
  and smoke-tested on its own via [`recipes/codec-test.yml`](recipes/codec-test.yml).
- **Hardware / system:** fprintd fingerprint auth (via authselect), Tailscale,
  power-profiles-daemon with an automatic AC/battery profile switch, blueman,
  NetworkManager applet.
- **Apps:** VS Code layered from Microsoft's repo; Evolution (Microsoft 365 / Graph
  backend, not EWS) for mail; a large set of Flatpaks (Firefox, ungoogled-chromium,
  Bazaar app store, LibreOffice, Steam, and more) with Electron apps forced onto
  native Wayland for sharp HiDPI.
- **Not baked:** `$HOME`-scoped installers (brew, SDKMAN, JetBrains Toolbox) and the
  live desktop config, which are delivered by the separate **dotfiles** repo via GNU
  stow. The image ships sane defaults; dotfiles overlay the configs actually being
  iterated on. See DESIGN §6.

## Documentation

- **[DESIGN.md](DESIGN.md)** — the source of truth for *what* is built and *why*:
  locked decisions, the HiDPI strategy, the update/release model, the config-baking
  split, and the clean-install sequencing and backup plan.
- **[SETUP.md](SETUP.md)** — the operations runbook: CI setup, the local build loop,
  VM testing, building the installer ISO, installing, first-boot steps, and
  updates/rollback.
- **[HISTORY.md](HISTORY.md)** — frozen planning-phase archive. Not authoritative,
  and parts of it are now wrong on purpose; kept only for the reasoning.

## Installation

> [!WARNING]
> [Native container rebasing](https://docs.fedoraproject.org/en-US/bootc/) is a
> supported-but-advanced path. These images are for one specific laptop; read
> DESIGN §10 before installing on real hardware.

To rebase an existing atomic Fedora install to this image:

```bash
# 1. Rebase to the unsigned image first, to pull in the signing keys + policy:
rpm-ostree rebase ostree-unverified-registry:ghcr.io/mark-iid/kb3lyb-sway:latest
systemctl reboot

# 2. Then rebase to the signed image:
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mark-iid/kb3lyb-sway:latest
systemctl reboot
```

`latest` follows the most recent build, which always stays on the Fedora version
pinned in `recipe.yml` — so you won't be jumped to the next major release by
surprise. BlueBuild also publishes timestamped tags for pinning/rollback.

For a clean install rather than a rebase, generate an installer ISO — see
[SETUP.md §4](SETUP.md) and the tooling under [`vm/`](vm/).

> [!CAUTION]
> The generated `anaconda-iso` is **unattended by default and will silently wipe
> the first disk it finds.** The build tooling here forces Anaconda to run
> interactively via an empty kickstart; never build the ISO without it. Read
> DESIGN §10 in full first.

## Verification

Images are signed with [Sigstore](https://www.sigstore.dev/)'s
[cosign](https://github.com/sigstore/cosign). Verify with the [`cosign.pub`](cosign.pub)
key in this repo:

```bash
cosign verify --key cosign.pub ghcr.io/mark-iid/kb3lyb-sway
```

## Repository layout

| Path | What it is |
|---|---|
| `recipes/recipe.yml` | The image definition (base, modules, packages, flatpaks). |
| `recipes/common/`, `recipes/codec-test.yml` | Shared / testable module fragments. |
| `files/system/` | Files baked into the image root (configs, units, scripts). |
| `modules/` | Custom BlueBuild module(s). |
| `vm/` | Local build + VM test + ISO build tooling. |
| `.github/workflows/` | Nightly build and the Fedora version-bump PR workflow. |
| `DESIGN.md`, `SETUP.md` | Design rationale and operations runbook. |
| `HISTORY.md` | Frozen planning archive; superseded by the recipe. |
| `files/scripts/image-assert.sh` | Build-time postconditions — fails the build if the image isn't what the recipe describes. |

## License

See [LICENSE](LICENSE).
