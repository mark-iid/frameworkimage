#!/usr/bin/env bash
# Headless boot check for the kb3lyb-sway qcow2 (DESIGN §9.4). Runs as the normal
# user — QEMU uses /dev/kvm (world-accessible), no root needed.
#
# Boots the disk with a virtio-vga console exposed over VNC, waits, then grabs a
# framebuffer screenshot via the QMP monitor. A screenshot showing the tuigreet
# greeter is proof the image booted through greetd to the login screen. The VM is
# left RUNNING on VNC so a human can connect, log in (test/test), and watch niri
# render.
#
#   bash vm/boot-check.sh            # boot, screenshot, keep running
#   bash vm/boot-check.sh --shutdown # after inspection, power it off
set -euo pipefail
cd "$(dirname "$0")/.."

QCOW=$(find vm/output -name '*.qcow2' | head -1)
QMP=vm/qmp.sock
PIDF=vm/qemu.pid
SHOT=vm/output/greeter.png
VNC_DISPLAY=1                     # VNC on 127.0.0.1:5901
SSH_PORT=2222

qmp() { # send one QMP command, print reply
  python3 - "$QMP" "$1" <<'PY'
import socket,sys,json
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f=s.makefile('rw')
f.readline()                                   # greeting
f.write(json.dumps({"execute":"qmp_capabilities"})+"\n"); f.flush(); f.readline()
f.write(sys.argv[2]+"\n"); f.flush(); print(f.readline().strip())
PY
}

if [ "${1:-}" = "--shutdown" ]; then
  qmp '{"execute":"system_powerdown"}' || true
  sleep 3; [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null || true
  echo "powered down"; exit 0
fi

[ -n "$QCOW" ] || { echo "!! no qcow2 in vm/output — run vm/build-qcow2.sh first"; exit 1; }
rm -f "$QMP"

echo ">>> Booting $QCOW (KVM, VNC 127.0.0.1:590${VNC_DISPLAY}, ssh localhost:${SSH_PORT})"
# virtio-vga-gl + egl-headless give the guest a virgl 3D render node, which
# niri's wlroots renderer requires. Plain -vga virtio (2D only) makes niri exit
# immediately with no renderer. Serial is a unix socket (ttyS0) so we can log in
# over it for diagnosis (serial-getty@ttyS0 runs in the guest).
rm -f vm/serial.sock
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
  -drive file="$QCOW",if=virtio,format=qcow2 \
  -device virtio-vga-gl -display egl-headless -vnc 127.0.0.1:${VNC_DISPLAY} \
  -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22 -device virtio-net,netdev=n0 \
  -device virtio-rng-pci \
  -qmp unix:"$QMP",server,nowait \
  -serial unix:vm/serial.sock,server,nowait \
  -pidfile "$PIDF" -daemonize

echo ">>> QEMU pid $(cat "$PIDF"). Waiting 75s for boot + niri session..."
sleep 75

echo ">>> Capturing framebuffer screenshot -> $SHOT"
qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$PWD/$SHOT\"}}"
sleep 2
ls -lh "$SHOT" 2>&1

echo ">>> Optional SSH probe (works only if sshd is enabled in the image):"
timeout 8 ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 test@localhost 'echo SSH_OK; systemctl is-active greetd NetworkManager; nmcli -t -g STATE g' 2>&1 \
  || echo "(ssh probe failed — sshd likely not enabled; use VNC to verify)"

echo ">>> VM left running. Connect a VNC viewer to 127.0.0.1:590${VNC_DISPLAY} to log in (test/test)."
echo ">>> Stop it with: bash vm/boot-check.sh --shutdown"
