# TODO — recreate /var/mnt/data (do this at the PC, needs sudo)

Working note. Reformats the **1TB expansion card** as LUKS (auto-unlock) + ext4 and
mounts it at `/var/mnt/data`. Requires `sudo` + interactive LUKS passphrase, so it
must be run at the machine. Delete this file once done.

## Context (verified 2026-07-31)
- Target: **`/dev/sda`** = `931.5G "1TB Card"` (serial `…628B1E49`). Nothing mounted
  from it; its current 600M/2G/70G xfs partitions are stale leftovers, not data.
- The OS is entirely on **`nvme0n1`** (WD_BLACK 500GB: `/boot`, `/boot/efi`, LUKS→btrfs
  root at `/var/home`). **Do not touch nvme0n1.**
- Decisions: **LUKS2, auto-unlock via keyfile on the encrypted root** + **ext4**.
- The original data was lost in the installer wipe — this is a fresh, empty drive.

## Before running
Re-confirm the device still enumerates as `sda` and is the 1TB Card (USB expansion
cards can shift names). Step 0 below prints it — eyeball it before proceeding.

## The procedure
```bash
# ---- /var/mnt/data: LUKS auto-unlock + ext4 on the 1TB card ----
DISK=/dev/sda; PART=${DISK}1

# 0. SAFETY: must show "1TB Card" / 931.5G — if it shows the WD_BLACK/nvme, STOP.
lsblk -o NAME,SIZE,MODEL,SERIAL "$DISK"

# 1. fresh GPT + one full-disk LUKS partition.
#    NOTE: this image ships util-linux (sfdisk/partx) but NOT gdisk/parted, so
#    sgdisk/partprobe are unavailable — use sfdisk. wipefs still clears old sigs.
sudo wipefs -a "$DISK"
sudo sfdisk "$DISK" <<'EOF'
label: gpt
name="data", type=CA7D7CCB-63ED-4C53-861C-1742536059CC
EOF
sudo partx -u "$DISK"      # re-read the partition table (replaces partprobe)
lsblk "$DISK"              # confirm sda1 exists at ~931G

# 2. LUKS2 format — set a passphrase you RECORD (this is your recovery key)
sudo cryptsetup luksFormat --type luks2 "$PART"

# 3. keyfile on the encrypted root → auto-unlock at boot, no prompt
sudo install -d -m 700 /etc/luks
sudo dd if=/dev/urandom of=/etc/luks/data.key bs=512 count=8 status=none
sudo chmod 400 /etc/luks/data.key
sudo cryptsetup luksAddKey "$PART" /etc/luks/data.key      # enter the step-2 passphrase

# 4. open + make ext4
sudo cryptsetup open "$PART" data --key-file /etc/luks/data.key
sudo mkfs.ext4 -L data /dev/mapper/data

# 5. crypttab (keyfile, nofail) + mountpoint + fstab
LUKS_UUID=$(sudo blkid -s UUID -o value "$PART")
echo "data UUID=$LUKS_UUID /etc/luks/data.key luks,nofail" | sudo tee -a /etc/crypttab
sudo install -d /var/mnt/data
echo "/dev/mapper/data /var/mnt/data ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2" | sudo tee -a /etc/fstab

# 6. activate now + take ownership
sudo systemctl daemon-reload
sudo mount /var/mnt/data
sudo chown mark:mark /var/mnt/data
findmnt /var/mnt/data && echo "OK: /var/mnt/data is mounted"
```

## Notes / gotchas
- **Record the step-2 passphrase** — it's the recovery key if `/etc/luks/data.key` is
  ever lost (e.g., an OS reinstall). The keyfile does day-to-day auto-unlock.
- `nofail` everywhere → a missing/removed card never blocks boot.
- `/etc/crypttab`, `/etc/fstab`, `/etc/luks/data.key` live in `/etc` (persistent,
  machine-specific). Do **not** put them in the image/repo — they hold the UUID and
  reference the keyfile.
- **Reboot after** to confirm auto-mount: `findmnt /var/mnt/data`.
- If SELinux blocks the mount or keyfile on first boot, run
  `sudo restorecon -Rv /etc/luks /var/mnt/data` and retry.
- No initramfs regen needed — this is a secondary device unlocked from the real root
  at boot (only the *root* LUKS lives in the initramfs).

## After it's working
- Tick the `/var/mnt/data` item in `SETUP.md §6`.
- Reclaim the local build image (~8 GB): `podman rmi localhost/kb3lyb-sway:44 && podman image prune -f`
- Delete this TODO file.
