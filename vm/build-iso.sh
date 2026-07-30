#!/usr/bin/env bash
# Build an Anaconda INSTALLER ISO from the image (DESIGN §9.8 / §10). Rootful:
# bootc-image-builder refuses rootless (loop devices / SELinux labeling).
#
#   bash vm/export-image.sh          # refresh the archive from the current image
#   sudo bash vm/build-iso.sh        # then build the ISO
#
# IMPORTANT (DESIGN §10): this is an Anaconda INSTALLER, not a live desktop. Boot
# it to *install* onto a target disk; first boot of the installed system is the
# final niri desktop. Partitioning/LUKS/btrfs and your user account are chosen
# interactively during the install — that's why no test-user config is baked in
# here (unlike the throwaway qcow2). Confirm the target disk by serial/size before
# proceeding (DESIGN §10: Anaconda target selection is the dangerous step).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="vm/kb3lyb-sway.oci"
IMAGE="localhost/kb3lyb-sway:44"
BIIB="quay.io/centos-bootc/bootc-image-builder:latest"

[ -f "$ARCHIVE" ] || { echo "!! $ARCHIVE missing — run: bash vm/export-image.sh"; exit 1; }

echo ">>> loading $IMAGE into root podman storage"
podman load -i "$ARCHIVE"
podman image exists "$IMAGE" || { echo "!! $IMAGE not loaded"; podman images; exit 1; }

echo ">>> building anaconda-iso"
mkdir -p vm/output
# --rootfs is still required at manifest time (sway-atomic base declares no
# DefaultRootFs). It sets the default for automatic partitioning only; pick
# btrfs-on-LUKS interactively in Anaconda's custom partitioning (DESIGN §10).
podman run --rm --privileged --security-opt label=disable \
  -v "$PWD/vm/output":/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$BIIB" \
  build --type anaconda-iso --rootfs xfs "$IMAGE"

echo ">>> done. Artifact:"
find vm/output -name '*.iso' -exec ls -lh {} \;
if [ -n "${SUDO_UID:-}" ]; then
  chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" vm/output
  echo ">>> chowned vm/output back to uid ${SUDO_UID}"
fi
