# kb3lyb-sway — setup & operations runbook

Operational checklists for building, testing, installing, and updating this image.
For *why* any of this is the way it is, see `DESIGN.md` (referenced as §N below).

---

## 1. One-time GitHub / CI setup

Done once per repo clone. CI is `.github/workflows/`:
`build.yml` (nightly + push/PR/manual, signs & pushes to GHCR) and
`fedora-version-bump.yml` (weekly; opens a PR when a new stable Fedora ships, §5).

- [ ] **Push to a public GitHub repo** (§2 — the image is public).
- [ ] **`SIGNING_SECRET` in the Actions secret store** = contents of `cosign.key`
      (empty-password cosign private key; pairs with the committed `cosign.pub`):
      ```
      gh secret set SIGNING_SECRET < cosign.key
      ```
- [ ] **`SIGNING_SECRET` in the *Dependabot* secret store too** — Dependabot PRs run
      in a restricted context and don't get Actions secrets, so their build checks
      fail on signing without this:
      ```
      gh secret set SIGNING_SECRET --app dependabot < cosign.key
      ```
- [ ] **Settings → Actions → Workflow permissions:** *Read and write* + tick
      *Allow GitHub Actions to create and approve pull requests* (version-bump needs it).
- [ ] **Make the `ghcr.io/<owner>/kb3lyb-sway` package public** after the first
      successful build creates it.

> `cosign.key` is gitignored — never commit it. If it's ever lost, regenerate the
> pair (`cosign generate-key-pair`), commit the new `cosign.pub`, and update the
> secret in both stores.

---

## 2. Local build loop (§8.2)

Iterate locally, never via GitHub Actions, and **never `rpm-ostree rebase` the daily
driver** (§8.1) — build and validate images only.

```
./build-local.sh                 # generate Containerfile + podman build -> localhost/kb3lyb-sway:44
./build-local.sh recipes/codec-test.yml   # isolated codec depsolve smoke test (the fragile module, §9.2)
```

`build-local.sh` runs the BlueBuild CLI in a container to template the Containerfile,
then builds with rootless podman + `--security-opt label=disable` (SELinux exec
workaround for the module scripts).

---

## 3. VM testing (§9.4)

The laptop is not touched until a VM boots this image to a usable niri session (§9).
bootc-image-builder is **rootful**, so the disk build needs `sudo`; QEMU boot does not.

```
bash vm/export-image.sh          # refresh vm/kb3lyb-sway.oci from the CURRENT image (do this first!)
sudo bash vm/build-qcow2.sh      # build the qcow2 (rootful)
bash vm/boot-check.sh            # boot headless; screenshot greeter; leave VM on VNC
#   -> VNC 127.0.0.1:5901, log in test/test, confirm niri renders
bash vm/boot-check.sh --shutdown # stop it
```

**Comprehensive re-test** (boots + 17 in-guest assertions, then hands to VNC):
```
bash vm/retest.sh export         # refresh oci
sudo bash vm/build-qcow2.sh
bash vm/retest.sh verify
```

> QEMU must use `virtio-vga-gl` + `egl-headless` (boot-check.sh does) or niri exits
> for lack of a GPU render node — a VM artifact, not an image bug.

---

## 4. Build the installer ISO (§9.8 / §10)

```
bash vm/export-image.sh          # from the current image
sudo bash vm/build-iso.sh        # -> vm/output/bootiso/install.iso  (~4 GB)
```

This is an **Anaconda installer**, not a live desktop (§10). Booting it installs the
image onto a target disk; first boot of the installed system is the final niri desktop.
Partitioning, LUKS, btrfs, and your user account are chosen interactively.

> ⚠️ **`anaconda-iso` is UNATTENDED by default — it silently wipes the first disk
> it finds, no prompt, no encryption** (it already destroyed one machine's internal
> NVMe). `build-iso.sh` only stays interactive because it mounts `vm/iso-config.toml`
> (an empty installer kickstart, §10). **Never delete that file or add
> `autopart`/`clearpart`/`reboot` to it** — the script refuses to build without it.
> When in doubt, prefer the §5 fallback: install stock Fedora Sway Atomic and
> `rpm-ostree rebase` (README). Fedora's Anaconda is interactive and never
> auto-installs.

---

## 5. Installing (§9.9 / §10)

Order matters more than anything else here (§10). **Rehearse on external USB first.**

Before booting the installer:
- [ ] **Pull the Framework storage-expansion card** (`/var/mnt/data` — it's a
      removable USB device). A card that isn't plugged in can't be selected by mistake.
- [ ] Write `install.iso` to a USB stick (≥8 GB). Boot menu: **F12**.

During Anaconda:
- [ ] **Confirm the target disk by serial/size** before proceeding — this is the
      dangerous step. For the trial run, target an **external USB-C NVMe** (not a
      flash drive — it'll feel terrible and give a false negative), *not* the internal NVMe.
- [ ] Custom partitioning: **btrfs subvols on LUKS** (`/root`, `/home`, `/var`),
      separate ext4 `/boot`, vfat ESP — reproduce the current layout (§1).
- [ ] Secure Boot can stay enabled (Fedora shim/kernel are signed; no akmods planned).

Trial: **daily-drive the USB install for a week** (§9.9) — it's the only way to test
the fingerprint reader, the 200-DPI panel at 1.35, the amdgpu PSR karg, HDMI, wifi,
bluetooth audio, and suspend/resume. Only then wipe the internal drive (§9.10).

---

## 6. First-boot / post-install

- [ ] `kb3lyb-bootstrap` — clones dotfiles (prompts for a token), stows them, installs
      brew + Brewfile, SDKMAN, JetBrains Toolbox into `$HOME` (§6).
- [ ] `fprintd-enroll` — re-enroll fingerprints (not portable, §10).
- [ ] **Make the login keyring passwordless** (needed once fingerprint login is set
      up). `pam_fprintd` is `sufficient` and first in `system-auth`, so a fingerprint
      login never captures a password — and `pam_gnome_keyring` then can't unlock the
      login keyring. Symptom: VS Code "keychain"/Secret Service errors, Evolution can't
      store its OAuth token, `secret-tool` fails. Fix (leans on LUKS FDE for at-rest
      protection): open **Seahorse** (Passwords and Keys) → right-click the **Login**
      keyring → **Change Password** → old = your login password, new = **blank** →
      accept "Use Unsafe Storage". It then auto-unlocks at every login regardless of
      how you authenticate. Verify: `busctl --user get-property org.freedesktop.secrets
      /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection
      Locked` → `b false`. (Alternative: log in with your password instead of the
      finger — the keyring then unlocks the normal way, no blank password needed.)
- [ ] `sudo tailscale up` — re-authenticate the node (identity isn't portable, §10).
- [ ] Restore by hand, encrypted (never via repo/image, §10): `~/.ssh`, `~/.gnupg`,
      `~/.config/rclone/rclone.conf`, the atuin key (`~/.local/share/atuin/key`), then
      `atuin login` to resume sync.
- [ ] Recreate `/var/mnt/data`: `/etc/crypttab` entry + mount unit (capture these
      *before* wiping, don't reconstruct from memory).
- [ ] Evolution: use the **Microsoft 365 / Graph** account type, not EWS (§3).
- [ ] *(optional)* **Show the text boot instead of the Plymouth splash.** The base
      image's cmdline carries `rhgb quiet`. To see the console/systemd boot messages:
      ```
      sudo rpm-ostree kargs --delete=rhgb --delete=quiet   # drop just rhgb to keep kernel quiet
      systemctl reboot
      ```
      This is a *local* karg change (persists across `rpm-ostree upgrade`, but not baked
      — bootc `kargs.d` only appends, it can't remove the base `rhgb quiet`), so redo it
      after a fresh reinstall.

---

## 7. Backup checklist (§10) — do BEFORE wiping the internal drive

Not dotfiles. The easy-to-forget, painful-to-lose things:
- [ ] **Atuin key** `~/.local/share/atuin/key` (unrecoverable if lost). Back up first.
- [ ] `~/.ssh`, `~/.gnupg`, `~/.config/rclone/rclone.conf` (OAuth tokens).
- [ ] WireGuard configs + NetworkManager connection profiles.
- [ ] Browser profiles (or confirm synced), Evolution/Thunderbird profile.
- [ ] VS Code settings + `code --list-extensions`; JetBrains config + licenses.
- [ ] `brew bundle dump` (→ refreshes `~/dotfiles/Brewfile`).
- [ ] `flatpak list --app --columns=application` + `~/.var/app`.
- [ ] Ham radio logs, anything under `~/.local/share`.
- [ ] Hand-edited `/etc`; anything unique on `/var/mnt/data`.

Protect the backup itself:
- [ ] **Back up the expansion card's LUKS header** (`cryptsetup luksHeaderBackup`),
      store it somewhere *other* than the card.
- [ ] Don't keep the only copy of the card passphrase on the machine being wiped.
- [ ] Put a second encrypted copy of the tiny irreplaceables (atuin/ssh/gpg/rclone)
      on the homelab TrueNAS or OneDrive.
- [ ] **Restore the backup into a VM and confirm it works** — a backup that hasn't
      been restored once is a hypothesis (§10).

---

## 8. Updates & rollback (§5)

- Base is **pinned** (`image-version` in the recipes), bumped only by the
  `fedora-version-bump` PR — merge it **only when its build is green** (the build is
  the depsolve gate; codecs are the likely failure point).
- Rolling back to a specific known-good timestamped GHCR tag is preferable to
  `rpm-ostree rollback` (which only reaches the previous deployment).
- Before any major rebase: `ostree admin pin 0` so a known-good deployment survives.

---

## 9. Not yet baked / known follow-ups

Still open:
- **HDMI presenting (§2):** a `kanshi` profile for the external output is still needed.
  kanshi is installed; the profile isn't written — it keys on the specific output/EDID,
  so it's easiest to author with a display plugged in.
- **`fw-fanctrl` (§3):** explicitly deferred; battery charge limit is set in BIOS.

Done since the first cut (kept for history):
- **Ghostty terminal (§2):** baked from the `scottames/ghostty` COPR (the source
  ghostty's own install docs endorse; the §3 `pgdev/ghostty` guess never existed).
  Installed as a plain package so its `zlib-ng` dep resolves from Fedora (the scoped
  `repo: copr:…` form broke the build). Primary terminal (`Super+Return`); `foot` stays
  a fallback.
- **Bazaar app store (§7):** added — `io.github.kolunmi.Bazaar` (Flathub, ID verified).
- **Host auto-update timers (§5):** baked + enabled — `rpm-ostreed-automatic.timer`
  (staging), `flatpak-update.timer`, and the user `brew-upgrade.timer`. The rpm-ostree
  one is confirmed working (it staged an image update in normal use).
- **Electron Wayland overrides (§4):** confirmed on the real install — Slack renders
  sharp and dark.
- **Mail:** Evolution + evolution-ews baked (M365/Graph + personal; mako notifications).
- **Automatic power profiles:** niri has no GNOME power panel, so `kb3lyb-power-profile`
  (script + `.timer` + a `power_supply` udev rule) drives tuned-ppd: **performance on
  AC, balanced on battery, power-saver below 20%**. udev handles plug/unplug instantly;
  the 2-min timer catches the 20% line. A polkit rule
  (`net.hadess.PowerProfiles.switch-profile` → allow root) lets the session-less service
  switch profiles. Check: `busctl --system get-property org.freedesktop.UPower.PowerProfiles
  /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile`.
  Override manually and it re-asserts within 2 min; `systemctl mask
  kb3lyb-power-profile.timer` to disable. Thresholds live in `/usr/bin/kb3lyb-power-profile`.
