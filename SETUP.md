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
- [ ] **Do NOT put `SIGNING_SECRET` in the Dependabot secret store.** It used to be
      there so Dependabot PR builds could sign, but that handed the image signing
      key to third-party action code *before* anyone reviewed the bump proposing
      it. `build.yml` now skips Dependabot runs entirely (`if: github.actor !=
      'dependabot[bot]'`), so nothing needs it. If a copy still exists:
      ```
      gh secret delete SIGNING_SECRET --app dependabot
      ```
      The cost is that action bumps merge without a green build. Acceptable: a
      broken build on main just means "no new image today" and the laptop keeps
      running the last good signed deployment (§5).

> **Why not keyless signing?** Sigstore keyless (OIDC → Fulcio → Rekor, no
> long-lived key) would remove this whole class of problem, and the workflow
> already grants `id-token: write`. It is **not available**: `blue-build/github-
> action` declares `cosign_private_key` as a *required* input and its `action.yml`
> contains no keyless/OIDC/Fulcio/Rekor path. Verified against the action
> definition on `main`, not assumed. Revisit if upstream adds support — this key
> is the single credential that can put root on the laptop via a signed update.
- [ ] **Settings → Actions → Workflow permissions:** *Read repository contents
      and packages permissions* + tick *Allow GitHub Actions to create and approve
      pull requests*. The default is deliberately **read-only**: both workflows
      declare the write scopes they need in their own `permissions:` block
      (`build.yml` job-level, `fedora-version-bump.yml` top-level), so a
      read-only default costs nothing and means any *future* workflow starts
      with no write token by accident. The create-and-approve tick, despite its
      name, is what lets `peter-evans/create-pull-request` open the version-bump
      PR at all — untick it and that workflow fails with "GitHub Actions is not
      permitted to create or approve pull requests."
- [ ] **Settings → Actions → General: require actions to be pinned to a full-length
      commit SHA.** Every `uses:` in this repo is already SHA-pinned for the reason
      in `build.yml`'s comment; this makes the policy enforced rather than a
      convention that erodes. A workflow referencing a mutable tag now fails to
      start instead of silently running whatever that tag points at today.
- [ ] **Make the `ghcr.io/<owner>/kb3lyb-sway` package public** after the first
      successful build creates it.

- [ ] **Back up `cosign.key` off this machine, in the same sitting that generates
      it.** `Documents/keys/kb3lyb-sway-cosign.key` in Nextcloud, mode 0600,
      alongside a `README-kb3lyb-sway-cosign.md` saying what it signs and where
      else it must exist. This checklist item is not optional bookkeeping: the
      first key was lost exactly this way — gitignored (correctly), therefore
      present in one working directory and nowhere else, and gone the moment that
      directory was. It survived only as an Actions secret, which cannot be read
      back out. Rotated 2026-08-27 for that reason, not because of any compromise.

> `cosign.key` is gitignored — never commit it. Push protection is on, so an
> accidental paste is blocked at `git push`, but do not rely on that. If the key
> is lost or suspected compromised, regenerate the pair
> (`COSIGN_PASSWORD="" cosign generate-key-pair`), **copy both halves to Nextcloud
> first**, commit the new `cosign.pub`, keep the outgoing one as
> `cosign-old.pub`, and re-set `SIGNING_SECRET` in the Actions store (only — see
> the Dependabot note above). Every host that has already rebased needs the new
> public key before it will accept a build signed with the new private one; the
> procedure for that is §8.

### 1.1 Security tab

One-time repo settings, all under **Settings → Advanced Security** and
**Settings → Rules** unless noted. Reportable as `gh api repos/<owner>/<repo>
--jq .security_and_analysis`.

- [ ] **Dependabot alerts** and **Dependabot security updates** — on. `dependabot.yml`
      only configures *version* updates (weekly, grouped); alerts are a separate
      switch and were off, which meant a known-vulnerable pinned action would
      have produced no signal at all.
- [ ] **Secret scanning** + **push protection** — on. Push protection is the one
      that matters here: it blocks a `cosign.key` paste at `git push` time rather
      than reporting it after it is already public.
- [ ] **Private vulnerability reporting** — on. This is what `SECURITY.md` points
      reporters at; without it the only channel is a public issue, which is the
      wrong place for anything touching the signing chain.
- [ ] **Code scanning: CodeQL default setup, `actions` language.** CodeQL cannot
      analyse shell or the recipe YAML, so it is not looking at the modules — it
      is auditing `.github/workflows/` for the workflow-specific failure modes
      (expression injection into `run:`, unpinned or over-privileged steps,
      artifact/secret leakage). That is the right target: the workflows are where
      `SIGNING_SECRET` lives, and the scripts are covered by review plus
      `image-assert.sh`. Default setup rather than a committed workflow, so there
      is no extra `uses:` to keep pinned.
- [ ] **Ruleset `protect-main`** — active on the default branch, blocking
      **deletion** and **non-fast-forward (force) pushes**. Deliberately *not*
      requiring pull requests: this is a single-operator repo and direct pushes to
      `main` are the normal workflow. What the rules buy is that `main`'s history
      cannot be silently rewritten — which matters because whatever is on `main`
      gets built, signed, and staged onto the laptop overnight without anyone
      looking at it.
- [ ] **Validity checks** and **non-provider patterns** for secret scanning —
      enable in the UI if offered. The REST API accepts the PATCH and leaves both
      `disabled`, so they appear to be gated to Secret Protection / GHAS rather
      than free public repos; not worth chasing.

---

## 2. Local build loop (§8.2)

Iterate locally, never via GitHub Actions, and **never `rpm-ostree rebase` the daily
driver** (§8.1) — build and validate images only.

```
./build-local.sh                 # generate Containerfile + podman build -> localhost/kb3lyb-sway:<image-version>
./build-local.sh recipes/codec-test.yml   # isolated codec depsolve smoke test (the fragile module, §9.2)
```

`build-local.sh` runs the BlueBuild CLI in a container to template the Containerfile,
then builds with rootless podman + `--security-opt label=disable` (SELinux exec
workaround for the module scripts). The tag is derived from the recipe's own `name`
and `image-version`, so it follows a Fedora bump automatically.

The last module in the recipe is `files/scripts/image-assert.sh`, so a local build
either ends with `image-assert: all postconditions hold` or fails with the specific
postconditions that broke. It is the same gate CI runs — there is no separate
verification step to remember.

---

## 3. VM testing (§9.4)

The laptop is not touched until a VM boots this image to a usable niri session (§9).
bootc-image-builder is **rootful**, so the disk build needs `sudo`; QEMU boot does not.

**QEMU is a prerequisite and is NOT in this image.** It never has been — the `vm/`
tooling was written on the old Aurora host, which shipped it, and the gap went
unnoticed because a green build says nothing about whether the gate that follows it
can run. Install it before the first VM test on a fresh machine.

Which QEMU you install decides how much of the test you get:

| | greeter check | niri renders |
|---|---|---|
| `brew install qemu` | yes | **no** |
| Fedora `qemu-system-x86-core` + `qemu-device-display-virtio-vga-gl` | yes | yes |

Homebrew's bottle is built without virglrenderer, so it has `virtio-vga` (2D) but no
`virtio-vga-gl`. `boot-check.sh` detects that, falls back to 2D and says loudly what
is lost. The fallback is still worth running — tuigreet is an fbcon TTY program and
needs no compositor, so the whole boot path through greetd is genuinely exercised
and the screenshot means what it says. What you do **not** get is niri: it exits
immediately with no render node, so a green 2D run is proof the image boots to a
login prompt and nothing more. Do not read it as proof of a working desktop.

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

> niri needs `virtio-vga-gl` + `egl-headless` to have a GPU render node; without one
> it exits immediately. That is a VM artifact, not an image bug. `boot-check.sh`
> picks the 3D pair when the QEMU build offers it and degrades to 2D with a warning
> when it does not — see the table above for what each mode actually proves.

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
- [ ] **Give the login keyring a REAL password.** This reverses the old
      "passwordless keyring" step, which stored every Secret Service credential
      (Evolution M365 OAuth tokens, Nextcloud, VS Code) encrypted with the empty
      string — readable by any process running as you, and readable straight out of
      any `/var/home` backup.

      That workaround existed only because `pam_fprintd` was `sufficient` at the top
      of `system-auth`: it short-circuited `pam_unix`, so login never captured a
      password and `pam_gnome_keyring` had nothing to unlock with. The image no
      longer enables the global fingerprint feature — it is scoped to
      `/etc/pam.d/gtklock` instead — so login goes through `pam_unix` again and the
      normal mechanism works.

      In **Seahorse** → right-click the **Login** keyring → **Change Password** →
      old = **blank**, new = **your login password**. They must match, or
      `pam_gnome_keyring` cannot auto-unlock it at login.

      Verify after a fresh login:
      ```
      busctl --user get-property org.freedesktop.secrets \
        /org/freedesktop/secrets/collection/login \
        org.freedesktop.Secret.Collection Locked      # -> b false
      ```
      If it reports `b true`, the keyring password does not match the login
      password. Symptom of a still-locked keyring: VS Code "keychain"/Secret
      Service errors, Evolution unable to store its OAuth token, `secret-tool`
      failing.
- [ ] **Scope fingerprint to the screen lock on an EXISTING machine.**
      `/etc/authselect` is machine-owned, so the build-time change does not reach an
      already-installed system. Run it once:
      ```
      sudo authselect disable-feature with-fingerprint
      sudo authselect apply-changes
      grep pam_fprintd /etc/pam.d/system-auth || echo "clear — fingerprint is out of system-auth"
      ```
      After this: login wants your password; the screen lock still takes your finger
      (via the baked `/etc/pam.d/gtklock`, which arrives with the image — check it is
      present before running the above, or you lose the finger at the locker too
      until you reboot into the new deployment).

      `sudo` also takes the finger, as of 2026-08-18. That is NOT the global feature
      coming back — it is `files/scripts/sudo-fingerprint.sh` inserting one line into
      `/etc/pam.d/sudo` at build time. The global feature stays off because it writes
      into `system-auth`, which login includes; scoping to the `sudo` file alone has
      no effect on login or the keyring. polkit still prompts for the password.

      Unlike `/etc/authselect` above, this one should reach an existing machine on
      its own: `/etc/pam.d/sudo` is unmodified locally, so rpm-ostree's `/etc` merge
      takes the new default. Verify after rebooting into a deployment built on or
      after 2026-08-18:
      ```
      head -3 /etc/pam.d/sudo        # expect: auth sufficient pam_fprintd.so
      sudo -k && sudo true           # should ask for the finger
      ```
      If the line is missing, the local file diverged at some point and rpm-ostree is
      keeping your copy — add the line by hand, or `rm` it and reboot to take the
      deployment's version.

      Needs `fprintd-enroll` to have been run for the account (§6 above). If it has
      not, or fprintd is down, `sudo` falls through to the password — it cannot lock
      you out. Remote `sudo` over SSH will ask for a finger you cannot provide and
      fall back to the password after a timeout; that is accepted, not a bug.
- [ ] **Delete any `com.discordapp.Discord` flatpak override.** A machine that ran
      an older image has a stale one in `/var/lib/flatpak/overrides/`, and the
      tmpfiles `C` rules never remove files, only create them. It must go:
      ```
      sudo rm -f /var/lib/flatpak/overrides/com.discordapp.Discord
      ```
      With that file present Discord's renderer segfaults in a loop — the "Discord
      Updater" splash maps and the main window never does. This, not zypak, is the
      bug that got Discord installed as a native tarball for months. Any override
      triggers it, including `sockets=` alone with no environment block. Without
      one Discord runs fine on `--ozone-platform=wayland` by itself, so there is
      nothing to gain by re-adding it.
- [ ] **Remove the old native Discord** (only on a machine that ran the pre-
      2026-08-08 bootstrap — Discord is a flatpak again now):
      ```
      rm -rf ~/.local/share/Discord ~/.config/discord
      rm -f  ~/.local/bin/discord ~/.local/share/applications/discord.desktop
      rm -f  ~/.local/share/icons/hicolor/256x256/apps/discord.png
      update-desktop-database ~/.local/share/applications
      ```
      Quit the native client first. `~/.config/discord` holds its session token, so
      you will sign in once in the flatpak.
- [ ] `sudo tailscale up` — re-authenticate the node (identity isn't portable, §10).
- [ ] **Network posture** (neither of these is baked into the image — firewalld zone
      config and tailscaled state both live in machine-owned `/etc` and `/var`, so a
      clean install comes back with the permissive defaults):
      ```
      sudo tailscale set --shields-up                                  # no inbound from the tailnet
      sudo firewall-cmd --permanent --zone=public --remove-service=ssh # sshd is disabled; drop the hole
      sudo firewall-cmd --reload
      ```
      Shields-up blocks *inbound* connections only — outbound ssh/rsync from this
      laptop to other tailnet nodes is unaffected. Reverse either with
      `tailscale set --shields-up=false` / `--add-service=ssh` if you ever need to
      reach into this machine or actually enable `sshd`.
- [ ] **Flatpak sandbox tightening on an EXISTING machine.** The seeds under
      `usr/share/factory/…/overrides` are installed by tmpfiles `C` rules, which
      copy only if the file is absent — so a fresh install picks these up
      automatically, but a machine that already has the override file keeps its
      old copy. Re-apply by hand after tightening any of them:
      ```
      sudo flatpak override --system --nosocket=x11 --nodevice=all --device=dri \
        com.bitwarden.desktop
      sudo flatpak override --system --nofilesystem=home --filesystem=xdg-download \
        com.github.IsmaelMartinez.teams_for_linux
      sudo flatpak override --system --nodevice=all --device=dri --disallow=devel \
        org.mozilla.firefox
      sudo flatpak override --system --nofilesystem=/tmp \
        --nofilesystem=~/.local/share/applications \
        io.github.ungoogled_software.ungoogled_chromium
      ```
      > **Test any new override before trusting it.** Apply it as `--user` first,
      > launch the app, and confirm it actually runs — a `--user` override
      > reproduces a system one's effect exactly. An override on
      > `com.discordapp.Discord` silently crash-looped that app for months while
      > everyone blamed zypak. Overrides are not free.
      Verify with `flatpak info --show-permissions <app>` — the effective
      `[Context]` should show `!x11` / `!home` merged in.
- [ ] Restore by hand, encrypted (never via repo/image, §10): `~/.ssh`, `~/.gnupg`,
      `~/.config/rclone/rclone.conf`, the atuin key (`~/.local/share/atuin/key`), then
      `atuin login` to resume sync.
- [x] Recreate `/var/mnt/data`: LUKS2 (keyfile auto-unlock via `/etc/luks/data.key`)
      + ext4, `/etc/crypttab` + `/etc/fstab` (both `nofail`). Done 2026-07-31 with
      `sfdisk`/`cryptsetup` (the image has no `sgdisk`/`parted`). Confirm auto-unlock
      survives a reboot: `findmnt /var/mnt/data`.
- [ ] Evolution: use the **Microsoft 365 / Graph** account type, not EWS (§3).
- [x] **Big console font — now automatic.** `kb3lyb-console-font.service` runs
      `setfont latarcyrheb-sun32` after `systemd-vconsole-setup`, so the ~2x HiDPI font
      applies out of the box even though the installer's `/etc/vconsole.conf` (`eurlatgr`)
      masks the baked `FONT=` default. No manual step needed anymore. (Historically this
      required `cp /usr/etc/vconsole.conf /etc/` — the service replaced that.)
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
- [ ] **Wi-Fi capture groups.** Both `kismet` and `tshark` gate non-root packet
      capture on a group, and the image cannot enroll you — the account is created at
      install time, not at build time. Once, then log out and back in:
      ```
      sudo usermod -aG kismet,wireshark "$USER"
      ```
      `kismet` is needed because the build-time `kismet-suid-scope.sh` narrows the
      capture helpers from the rpm's world-executable `4755 root:root` to
      `4750 root:kismet`; without the group you get permission denied on the capture
      source rather than a useful error. `wireshark` is upstream's own gating on
      `dumpcap` (`0750 root:wireshark`) and needs no fixup from us.

      **This step only works because the GIDs are pinned.** Joining a group by
      name is pointless if the number stamped on the file means a different group
      here than it did in the build. Both of these were silently broken that way
      until 2026-08-22: `kismet_cap_linux_wifi` was group 958, which was `kismet`
      in the image and `rtlsdr` on the laptop, and `dumpcap` was 956 — `wireshark`
      in the image, `usbmon` on the laptop. Both had been correctly hardened and
      made unusable at the same moment, with a green build. See
      `/usr/lib/sysusers.d/00-kb3lyb-gids.conf`.

      A machine installed before the pin existed keeps its old numbering —
      systemd-sysusers never renumbers an existing group, and `/etc/group` survives
      a rebase — so `kb3lyb-gid-reconcile.service` corrects it on the first boot
      after the pinned image lands. Verify with `getent group kismet` (expect 350)
      and `journalctl -u kb3lyb-gid-reconcile`. Nothing to do by hand unless it
      reports a GID clash.
      Neither is required to *read* saved captures — `tshark -r file.pcapng` works
      as any user. Only live capture needs the groups.
      Note that monitor mode drops the wifi association: this laptop has one radio,
      so a kismet capture and a working connection are mutually exclusive. Use
      `wavemon` for signal/AP-placement work, kismet for what else is on the air.
- [ ] **Serial port group (`dialout`).** Same class of per-machine step as the
      capture groups above — the image can create the group but cannot enroll an
      account that does not exist yet at build time. Once, then log out and back in:
      ```
      sudo usermod -aG dialout "$USER"
      ```
      `/usr/lib/udev/rules.d/50-udev-default.rules:47` puts every `tty[A-Z]*[0-9]`
      device — `ttyACM*` (Flipper Zero, ESP32, Klipper host) and `ttyUSB*` (FTDI/CP210x
      cables, radio CAT control) — at `0660 root:dialout`. Without the group you get
      permission denied on open.
      This persists across image updates: `dialout` (GID 18) comes from `/usr/lib/group`
      in the image, but the *membership* is written to `/etc/group`, which is machine
      state on bootc, not part of the image. Redo it after a fresh reinstall only.
      **Still needed even for the Flipper**, which has its own baked udev rule
      (`files/system/etc/udev/rules.d/70-flipper-zero.rules`) granting the device node
      via `uaccess`: `picocom` writes a UUCP lockfile into `/run/lock/picocom`, which
      is `0775 root:dialout`, so it fails at startup rather than at open. The rule and
      the group cover two different things — read both before concluding either is
      redundant.

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
- **Rolling back to an image older than the 2026-08-27 key rotation.** Builds from
  before that date are signed with the superseded key, which no host trusts any
  more, so a rebase to one of those timestamped tags fails signature verification
  rather than booting something unverified. This is the intended behaviour, not a
  fault. To reach one deliberately, point `keyPath` in
  `/etc/containers/policy.json` at the old key — the image ships it at
  `/etc/pki/containers/kb3lyb-sway-old.pub` precisely so that this needs no
  network and no repo checkout — rebase, then put `keyPath` back:
  ```
  sudo sed -i 's|kb3lyb-sway.pub|kb3lyb-sway-old.pub|' /etc/containers/policy.json
  sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mark-iid/kb3lyb-sway:<old-tag>
  sudo sed -i 's|kb3lyb-sway-old.pub|kb3lyb-sway.pub|' /etc/containers/policy.json
  ```
  Restoring `keyPath` matters — left pointing at the old key, the host would stop
  accepting *current* builds and silently stall on an old image, which is the
  failure `kb3lyb-image-age` exists to catch. The superseded public key is also in
  the repo as `cosign-old.pub` and in Nextcloud as
  `kb3lyb-sway-cosign-SUPERSEDED-2026-08.pub`.
- **Picking up a rotated key on a host.** After a rotation the host still trusts
  the old public key and refuses every new build. Install the new key directly at
  the path the policy already names, then upgrade:
  ```
  sudo install -m 0644 -o root -g root cosign.pub /etc/pki/containers/kb3lyb-sway.pub
  rpm-ostree upgrade      # no sudo: authorises via polkit, so it can prompt on the desktop
  ```
  **The initial-install trick does not work here.** README "Installing" says to
  rebase via `ostree-unverified-registry:` first, and it is correct *for a first
  install* — but on a host that already has this image, it fails:
  ```
  error: Preparing import: Fetching manifest: failed to invoke method OpenImage:
  cryptographic signature verification failed: invalid signature when validating
  ASN.1 encoded signature
  ```
  `ostree-unverified-*` only disables *ostree's* own signature check. The fetch
  still goes through `/etc/containers/policy.json`, which names
  `ghcr.io/mark-iid/kb3lyb-sway` explicitly and demands `sigstoreSigned` against
  the old key. On a first install there is no such entry yet — that is the whole
  difference. Verified the hard way, 2026-08-27.
- **Why hand-editing `/etc` is safe *here* specifically.** `/etc` is a merged
  writable overlay, so a local edit is normally carried across deployments and
  would mask the *next* rotation. It does not, provided the bytes you write are
  exactly the key the new image ships at `/usr/etc/pki/containers/`: once that
  deployment becomes the parent, the local copy is identical to the default,
  ostree stops counting it as a modification, and the file tracks the image again.
  Confirm with `cmp` against the staged deployment before rebooting rather than
  trusting it — writing an *almost* right key is what makes this permanent:
  ```
  D=$(ls -d /ostree/deploy/*/deploy/*/ | head -1)   # pick the staged one
  cmp /etc/pki/containers/kb3lyb-sway.pub "$D/usr/etc/pki/containers/kb3lyb-sway.pub"
  ```
- **Is the image actually still moving?** `kb3lyb-image-age` prints the age of the
  booted deployment; `kb3lyb-image-age --check` is what the daily user timer runs
  and notifies past 14 days. A stale reading means one of: the nightly build is
  red, an update is staged but never applied (check `rpm-ostree status`), or the
  laptop simply has not been on. Override the threshold with
  `KB3LYB_IMAGE_MAX_AGE_DAYS=<n>`.

---

## 9. Follow-ups and subsystem notes

This section used to be one list titled "not yet baked", with completed work
appended to it in the past tense. That let two entries drift into asserting the
opposite of the code — see the Discord and greeter notes below, both corrected
2026-08-22. Open work and reference material are now separated, because they rot
differently: the first shrinks as things get done, the second only changes when
the subsystem does.

### Still open

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
- **niri has never been rendered in a VM.** The boot check proves the image reaches the
  greeter, not that the desktop starts — Homebrew's QEMU has no `virtio-vga-gl`, so
  boot-check falls back to 2D and niri exits for lack of a render node. Install Fedora's
  `qemu-system-x86-core` + `qemu-device-display-virtio-vga-gl` to close this. Until then
  no VM run is evidence of a working desktop (§3).
- **The GID migration is unverified on real hardware.** `kb3lyb-gid-reconcile.service`
  has only been exercised on a *fresh* install, where it has nothing to do because
  sysusers creates the groups at the pinned numbers already. Renumbering an existing
  `kismet` from 960 to 350 is a different path. After the first rebase onto a pinned
  image, check `getent group kismet` and `journalctl -u kb3lyb-gid-reconcile`.
- **Four base-image groups are still unpinned** — `sssd`, `polkitd`, `openvpn`,
  `brlapi` all ship `/usr` files owned by their own dynamically-allocated groups, which
  is the same latent bug §6 describes. Deliberately not fixed: pinning them means
  renumbering groups that polkit and sssd authenticate against, to repair something we
  did not introduce, on files we do not build. `image-assert.sh` warns about them each
  build so the decision stays visible rather than forgotten.
- **CI does not boot anything.** `image-assert.sh` gates every build on the image being
  what the recipe describes, which is a real gate and not a boot test. `vm/boot-check.sh`
  remains manual.

### Reference — subsystems worth knowing about

Not a backlog. These are done, and they are here because the reasoning is not
recoverable from the code alone.

- **Ghostty terminal (§2):** baked from the `scottames/ghostty` COPR (the source
  ghostty's own install docs endorse; the §3 `pgdev/ghostty` guess never existed).
  Installed as a plain package so its `zlib-ng` dep resolves from Fedora (the scoped
  `repo: copr:…` form broke the build). Primary terminal (`Super+Return`); `foot` stays
  a fallback.
- **Bazaar app store (§7):** `io.github.kolunmi.Bazaar` (Flathub, ID verified).
- **Host auto-update timers (§5):** `rpm-ostreed-automatic.timer` (staging),
  `flatpak-update.timer`, `flatpak-update-user.timer`, and the user `brew-upgrade.timer`.
  Both flatpak timers exec `/usr/bin/kb3lyb-flatpak-update` rather than `flatpak update`
  directly — the bare command reports success while updating nothing in two distinct
  ways (see that script's header). Staleness of the image itself is watched separately
  by `kb3lyb-image-age.timer` (§8).
- **Electron Wayland overrides (§4):** confirmed on the real install — Slack renders
  sharp and dark.
- **Discord is a system flatpak, and must have NO flatpak override.** It was briefly a
  native tarball in `$HOME` on the theory that the flatpak's zypak sandbox broke the
  Wayland splash→main-window handoff under niri. **That diagnosis was wrong.** The cause
  was a stale `/var/lib/flatpak/overrides/com.discordapp.Discord` left over from an
  earlier image revision; any override on this app — even sockets alone — puts the
  renderer in a segfault loop behind a stuck "Discord Updater" splash. Bisected on the
  live machine: no override works, sockets-only breaks, and re-applying the override to
  a known-good install reproduces the break on demand. The flatpak selects Wayland on
  its own, unaided. This matters beyond tidiness — the tarball had no sandbox at all,
  self-updated by exec'ing an unsigned download into `~/.config/discord`, and opened an
  RPC listener on `127.0.0.1:6463` reachable by any local process. Do not go back to it.
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
- **Norton-blue login + big console font:** the tuigreet greeter runs via
  `/usr/bin/kb3lyb-greeter`, which redefines console palette entry 0 to **`#000080`**
  (navy) so the *whole* login screen is one colour rather than just the prompt box, then
  execs tuigreet with the matching Norton palette. `/etc/vconsole.conf` sets
  `FONT=latarcyrheb-sun32` (a 16x32 glyph, ~double the stock size) so login/boot text is
  legible on the 200-DPI panel. The niri session's wallpaper is an image via `swaybg -i
  … -m fill`, with `-c 000080` as the colour behind any letterboxing (dotfiles
  `spawn-at-startup`). All of this is LOGIN-adjacent and the greeter change is
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
