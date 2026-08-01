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
      brew + Brewfile, SDKMAN, JetBrains Toolbox, and native Discord into `$HOME` (§6).
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
- [x] Recreate `/var/mnt/data`: LUKS2 (keyfile auto-unlock via `/etc/luks/data.key`)
      + ext4, `/etc/crypttab` + `/etc/fstab` (both `nofail`). Done 2026-07-31 with
      `sfdisk`/`cryptsetup` (the image has no `sgdisk`/`parted`). Confirm auto-unlock
      survives a reboot: `findmnt /var/mnt/data`.
- [ ] Evolution: use the **Microsoft 365 / Graph** account type, not EWS (§3).
- [ ] **Adopt the big console font.** The image ships `FONT=latarcyrheb-sun32` (16x32,
      ~2x the stock size) as its `/etc/vconsole.conf` default, but the installer writes a
      real `/etc/vconsole.conf` (`eurlatgr`) at install time, so ostree treats it as
      machine-owned and never overwrites it on upgrade — the big font silently never
      applies. Adopt the image default once (persists; also lets future upgrades track it):
      ```
      sudo cp /usr/etc/vconsole.conf /etc/vconsole.conf   # sun32; the image default
      sudo setfont -C /dev/tty1 latarcyrheb-sun32         # apply to the greeter VT now
      ```
      Still too small on the 200-DPI panel? `solar24x32` is wider (24x32) — swap the name
      in `/etc/vconsole.conf`.
- [ ] **Boot style — graphical splash is the default (and preferred).** The base
      cmdline carries `rhgb quiet`, i.e. the Plymouth graphical splash + a graphical LUKS
      passphrase box. Keep it. If a fresh reinstall or an earlier experiment left `rhgb`
      off (text console boot), put it back:
      ```
      sudo rpm-ostree kargs --append-if-missing=rhgb
      systemctl reboot
      ```
      Text boot was tried and reverted: dropping `rhgb` (`kargs --delete=rhgb`) shows the
      console/systemd boot, but the initramfs LUKS prompt then renders on the bare console
      and the noisy kernel ring buffer overwrites it (looks blank until you type) and bleeds
      over the tuigreet login screen — Plymouth avoids all of that. **Always keep `quiet`**
      regardless; if it ever goes missing, `sudo rpm-ostree kargs --append-if-missing=quiet`.
      These are *local* karg changes (persist across `rpm-ostree upgrade`, not baked — bootc
      `kargs.d` can only append, not remove the base `rhgb quiet`), so redo after a fresh
      reinstall. To read the full kernel log after any boot: `journalctl -b -k`.

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
- **Alpine TUI mail:** configure `alpine` for the **personal IMAP** account (NOT the
  M365 one — that needs OAuth2/Graph, which Alpine doesn't do cleanly; Evolution stays
  the M365 client). Needs alpine installed (layer the `alpine` rpm or `brew install
  alpine`) + a `~/.pinerc` with the IMAP/SMTP servers and folder collection; store the
  password in the keyring or an app password, never in the config. A TUI complement to
  Evolution for quick terminal mail.

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
- **Discord — native, not flatpak:** the `com.discordapp.Discord` flatpak's zypak
  sandbox breaks the Wayland splash→main-window handoff under niri (web app loads, main
  window never maps; stuck "Discord Updater / Starting" splash — the renderer also
  segfaulted on a corrupt GPU/shader cache). Removed from the recipe + its flatpak
  override; `kb3lyb-bootstrap` now installs the official tarball into `$HOME`
  (`~/.local/share/Discord`, self-updating, launches on host Wayland/GPU). Verified: main
  window maps, zero crashes.
- **Mail:** Evolution + evolution-ews baked (M365/Graph + personal; mako notifications).
- **Portal FileChooser fix (open/save dialogs):** the stock niri portal config
  (`/usr/share/xdg-desktop-portal/niri-portals.conf`) has `default=gnome;gtk`, routing
  the FileChooser to xdg-desktop-portal-**gnome**. Under niri there's no GNOME session, so
  its delegation fails (`The name is not activatable`) and the *calling* app hangs on a
  file dialog that never appears (hit with Nextcloud's "Choose a different folder"). Baked
  `/etc/xdg-desktop-portal/niri-portals.conf` prefers **gtk** (implements FileChooser +
  all UI portals; works on wlroots), keeps screencast/screenshot on wlr and secrets on
  gnome-keyring; dark mode still flows via the gtk Settings portal. A live per-user copy
  in `~/.config/xdg-desktop-portal/` applies the same fix before the image lands.
- **Speaker DSP (EasyEffects):** `cab404/framework-dsp` presets are installed to
  `~/.var/app/com.github.wwmm.easyeffects/config/easyeffects/{output,irs}` (the three
  output presets + the convolver impulse-responses; `%CFG%` in each preset is rewritten
  to that absolute path so the Flatpak sandbox finds the IRs). **Gracefu's Edits** is
  the loaded output preset. It's applied live and reasserted every login by an
  EasyEffects `--service-mode` background process (niri `spawn-at-startup`, dotfiles).
  To switch presets: open EasyEffects → Presets → pick another, or
  `flatpak run com.github.wwmm.easyeffects -l "HifiScan+EEGuide"`. Re-run the upstream
  installer to update the presets (this is per-user `$HOME` data, not baked).
- **Norton-blue login + wallpaper + big console font:** the tuigreet greeter runs via
  `/usr/bin/kb3lyb-greeter`, which redefines console palette color 0 to `#0000AA` so the
  *whole* login screen is one Norton blue (not just the prompt box), then execs tuigreet
  with the Norton palette. `/etc/vconsole.conf` sets `FONT=latarcyrheb-sun32` (a 16x32
  glyph, ~double the stock size) so login/boot text is legible on the 200-DPI panel. The
  niri session paints a matching solid `#0000AA` wallpaper via `swaybg -c 0000AA`
  (dotfiles `spawn-at-startup`). All three are LOGIN-adjacent; the greeter change is
  login-critical — verify after upgrade, roll back from the boot menu if login breaks.
- **Automatic power profiles:** niri has no GNOME power panel, so `kb3lyb-power-profile`
  (script + `.timer` + a `power_supply` udev rule) drives tuned-ppd: **performance on
  AC, balanced on battery, power-saver below 20%**. udev handles plug/unplug instantly;
  the 2-min timer catches the 20% line. A polkit rule
  (`net.hadess.PowerProfiles.switch-profile` → allow root) lets the session-less service
  switch profiles. Check: `busctl --system get-property org.freedesktop.UPower.PowerProfiles
  /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile`.
  Override manually and it re-asserts within 2 min; `systemctl mask
  kb3lyb-power-profile.timer` to disable. Thresholds live in `/usr/bin/kb3lyb-power-profile`.
