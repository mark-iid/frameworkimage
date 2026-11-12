# kb3lyb-sway — AGENTS.md

A **BlueBuild** recipe that assembles a custom Fedora Sway Atomic image (`kb3lyb-sway`) for a Framework 13 AMD laptop running niri. Everything centers on one YAML file: the recipe depsolve → install → bake files → assert.

---

## Core command

```bash
./build-local.sh                          # default recipe → localhost/kb3lyb-sway:<version>
./build-local.sh recipes/codec-test.yml   # test just the codec module
TAG=custom-name REGISTRY=my.io ./build-local.sh  # custom tag + registry
```

Under the hood: BlueBuild CLI (pulled via container) generates a `Containerfile`, then `podman build --security-opt label=disable` builds it. The SELinux opt is required — module scripts exec on read-only bind mounts otherwise fail with "Permission denied".

CI (`build.yml`): nightly at 06:00 UTC + PR/push. Skips Dependabot actors (no signing key access). 45-minute timeout. Signs images with cosign via `SIGNING_SECRET` secret.

## File layout at a glance

| Path | Role |
|---|---|
| `recipes/recipe.yml` | **The image definition.** Base, modules (dnf packages, files, scripts), flatpak overrides. Every package, config, and unit lives here or is referred to by it. |
| `recipes/common/codecs.yml` | Shared codec module (RPM Fusion + ffmpeg swap + VA-API). Included by both the recipe and `codec-test.yml`. |
| `recipes/codec-test.yml` | Isolated smoke test for the codec module alone — fast depsolve check. |
| `files/system/` | Files baked into `/` in the image: configs, systemd units, udev rules, scripts, flatpak overrides. |
| `files/scripts/` | Build-time postconditions (`image-assert.sh`) and hardening (`pin-gids.sh`, `kismet-suid-scope.sh`). |
| `lib.sh` | Shared shell helpers (`recipe_field`, `recipe_tag`). Sourced, never executed directly. |
| `modules/` | Custom BlueBuild module directory (currently empty). |
| `vm/` | VM testing + ISO build tooling. All scripts source `lib.sh`. |

## The recipe is the source of truth

`recipes/recipe.yml` drives everything. It follows this module order and it **matters**:

1. **dnf remove** — strip unwanted base packages (e.g., Firefox RPM)
2. **from-file: codecs.yml** — RPM Fusion + ffmpeg swap (most fragile; runs first so repos persist for later dnf modules)
3. **dnf install (session)** — niri, greetd, waybar, mako, foot, wl-clipboard, cliphist, gtklock, kanshi, wmctrl, polkit, wtype, xdg-desktop-portal backends
4. **dnf install (COPR: wl-clip-persist)** — clipboard persistence from COPR; use plain `packages:` name not scoped `repo:` form so deps resolve from Fedora too
5. **dnf install (COPR: ghostty)** — same reasoning as #4 (zlib-ng dep lives in Fedora)
6. **fonts** — NerdFontsSymbolsOnly for waybar glyphs
7. **dnf install (doc fonts + document fonts + font clones)** — Carlito, Caladea, Cascadia Mono
8. **dnf install (hardware/app layer)** — VS Code (MS repo), tailscale, kismet (setuid hardening needed), wireshark-cli, picocom, rpi-imager, etc.
9. **systemd** — masked units, enabled services/timers, `flatpak-update` wrapper
10. **files** — configs and system files baked into `/`
11. **script: pin-gids.sh** — reconcile build-container group GIDs against the pinned file in sysusers.d (must run after all dnf + all files modules)
12. **flatpak install/override** — Electron apps forced onto native Wayland; Browser overrides go to `/usr/share/factory/var/lib/flatpak/overrides/`
13. **script: kismet-suid-scope.sh** — strip world-executable from kismet setuid helpers, leave group-executable (4750 root:kismet)
14. **script: image-assert.sh** — build-time postconditions; runs last

### Module ordering gotchas

- If `files` runs before dnf modules, any config a package also owns gets overwritten by the rpm default → green build, wrong config at runtime (e.g., `/etc/pam.d/gtklock`).
- The `unrar` binary resolves to RPM Fusion's RARLAB 7.x only while codecs runs first; reorder and it degrades silently to Fedora's unrar-free wrapper.
- GID reconciliation must happen after everything that creates groups, because the build container allocates dynamic GIDs in a different order than the installed system would.

## Key files that matter when editing the recipe

- **`files/system/usr/lib/bootc/kargs.d/00-kb3lyb.toml`** — Kernel arguments baked into the image (amdgpu.dcdebugmask, btrfs compression, vconsole font). The `vconsole.font=` karg replaced a broken systemctl service.
- **`files/scripts/image-assert.sh`** — Build-time assertions. Does NOT use `set -e`; runs every check so one build reports all failures. Contains helpers: `assert`, `refute`, `assert_file_has`. Add postconditions here for anything that could silently degrade.
- **`files/scripts/pin-gids.sh`** — Reconciles dynamically-allocated GIDs against pinned values in `00-kb3lyb-gids.conf`. Restamps file ownership. Must run after all group-creating dnf modules and the files module.
- **`files/system/usr/lib/sysusers.d/00-kb3lyb-gids.conf`** — Pinned GID assignments (kismet, wireshark, dialout). Files in `/usr` owned by dynamic groups resolve to different numbers on the build container vs the laptop — this prevents silent ownership corruption.
- **`files/sysytem/etc/greetd/config.toml`** — greetd/tuigreet config. The recipe's files module lays this down at `/etc`. Any RPM that also owns paths under `/etc/pam.d/` will overwrite it if files runs before dnf.

## VM testing (required for Fedora version bumps)

```bash
bash vm/export-image.sh           # export current image to vm/kb3lyb-sway.oci
sudo bash vm/build-qcow2.sh       # rootful: build qcow2 disk via bootc-image-builder
bash vm/boot-check.sh             # boot headless; capture greeter screenshot; leave VNC open
bash vm/boot-check.sh --shutdown  # power off

# Comprehensive re-test (boots + 17 assertions):
bash vm/retest.sh export
sudo bash vm/build-qcow2.sh
bash vm/retest.sh verify
```

**Prerequisite:** QEMU with `virtio-vga-gl` (virglrenderer). The Homebrew bottle lacks it — use Fedora's `qemu-device-display-virtio-vga-gl` for the full check. Without 3D acceleration, niri exits immediately; tuigreet greeter check still works via the 2D path.

## ISO building

```bash
sudo bash vm/build-iso.sh   # -> vm/output/bootiso/install.iso (~4 GB)
```

**⚠️ Anaconda iso is unattended by default — silently wipes the first disk.** The script forces interactivity via `vm/iso-config.toml` (empty installer kickstart). **Never delete or modify `iso-config.toml` to include autopart/clearpart — the script refuses without it.**

## Config delivery model

The image ships `/etc` defaults under `files/system/`. The operator's `$HOME` configs come from a separate dotfiles repo via GNU stow at runtime. Don't add desktop user configs to this recipe — they belong in stow. Only bake in system-level defaults (`/etc/niri/config.kdl`, `/etc/greetd/config.toml`, etc.) that the operator will then override.

## Flatpak overrides

Electron flatpaks (Discord, Teams, Slack) get a `GDK_BACKEND=wayland` override shipped via `tmpfiles.d` mechanism (`/usr/lib/tmpfiles.d/kb3lyb-flatpak-overrides.conf`). Each app's override lands in `/usr/share/factory/var/lib/flatpak/overrides/`. The image-assert check verifies **Discord has no seeded override** — an override on Discord puts its renderer into a segfault loop.

## Fedora version bumps

The `fedora-version-bump.yml` workflow checks weekly for new Fedora releases. On detection, it opens a PR bumping `image-version` in both `recipe.yml` and `codec-test.yml`. **Do NOT merge until the PR's build passes** — RPM Fusion typically lags Fedora GA by days to weeks, so the codec module (RPM Fusion repos + ffmpeg swap) is what will fail first. The workflow auto-retries stale builds each week while waiting for RPM Fusion.

## Security

- Images signed with cosign (`cosign.pub` committed; `cosign.key` must NOT be in the repo). Host verifies: `cosign verify --key cosign.pub ghcr.io/mark-iid/kb3lyb-sway`.
- Install path via rebase: go through `ostree-unverified-registry:` first to pull signing keys, then switch to signed.
- CI skips Dependabot PR builds — a third-party action bump shouldn't execute with the image signing key in hand before review.

## Rebase instructions (for the host machine)

```bash
# Step 1: rebase to unsigned (pulls cosign key + policy)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/mark-iid/kb3lyb-sway:latest
systemctl reboot

# Step 2: rebase to signed image
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mark-iid/kb3lyb-sway:latest
systemctl reboot
```

`latest` follows the most recent build. Timestamped tags available for pinning/rollback.
