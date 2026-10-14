#!/usr/bin/env bash
#
# Check an LXD-generated qemu.conf against the emulator this project builds.
#
# Two things have to hold for a VM to start, and both are cheap to check here
# rather than on the NAS:
#
#   1. the config LXD writes has to load - every device and firmware ROM the
#      emulator needs must exist;
#   2. the devices LXD adds *afterwards* over QMP (the NIC, USB, disks) have to
#      be accepted, including the parameter types it uses.
#
# So this rewrites the host-specific parts of the config (KVM, the OVMF paths,
# the NVRAM fd, the 9p path, the sockets), assembles the payload layout the
# wrapper expects, starts the emulator the way the wrapper does, and then speaks
# a little QMP to it the way LXD does.
#
# usage: tests/qemu-config-check.sh /var/log/lxd/<name>/qemu.conf
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/../scripts/lib.sh"

conf=${1:-}
[ -n "$conf" ] || die "usage: $0 <qemu.conf from /var/log/lxd/<name>/>"
[ -f "$conf" ] || die "no such file: $conf"

kernel="$REPO_DIR/build/bin/qemu-system-x86_64"
wrapper="$REPO_DIR/nas/shared/qemu-wrapper.sh"
firmware="$REPO_DIR/build/firmware"
datadir="$REPO_DIR/build/qemu-datadir"

[ -x "$kernel" ] || die "no emulator built yet (run scripts/25-make-tools.sh)"
[ -f "$firmware/OVMF_CODE.fd" ] || die "no firmware yet (run scripts/20-fetch-ovmf.sh)"
[ -d "$datadir" ] || die "no QEMU data directory in $datadir (run scripts/25-make-tools.sh)"

# The devices LXD's config and its QMP calls name, so a rebuild that quietly
# drops one is caught here rather than on the NAS. usb-host is what
# "lxc config device add ... usb" uses for a VM; vhost-vsock-pci needs the
# package's modules loaded, so its config section is dropped below but the
# device still has to exist in the build.
devices=$("$kernel" -device help 2>/dev/null)
missing=""
for device in vhost-vsock-pci virtio-net-pci virtio-scsi-pci virtio-9p-pci \
              virtio-vga virtio-serial-pci virtio-balloon-pci virtio-rng-pci \
              virtio-keyboard-pci virtio-tablet-pci qemu-xhci usb-host usb-storage; do
    printf '%s\n' "$devices" | grep -q "\"$device\"" || missing="$missing $device"
done
[ -z "$missing" ] || die "the emulator has no support for:$missing"
log "the emulator has every device LXD uses"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The payload as the wrapper expects to find it: bin/ next to libexec/ next to
# share/qemu/.
payload="$work/payload"
mkdir -p "$payload/bin" "$payload/libexec" "$payload/share/qemu" "$work/run"
cp "$wrapper" "$payload/bin/qemu-system-x86_64"
cp "$kernel" "$payload/libexec/qemu-system-x86_64"
chmod 755 "$payload/bin/qemu-system-x86_64" "$payload/libexec/qemu-system-x86_64"
cp -r "$datadir"/* "$payload/share/qemu/"

# Run it the way the NAS does: the helper links the wrapper into
# /usr/local/bin, so it is normally invoked through a symlink.
mkdir -p "$work/bin"
ln -sf "$payload/bin/qemu-system-x86_64" "$work/bin/qemu-system-x86_64"

mkdir -p "$work/run/config.mount"
cp "$firmware/OVMF_VARS.fd" "$work/run/nvram.fd"

# Host-specific bits only: the VM's own devices are left exactly as LXD wrote
# them, spice sections included (the wrapper is expected to filter those). The
# one exception is the vsock device: it needs the host's /dev/vhost-vsock, which
# only exists where this package's modules are loaded, so the device is dropped
# rather than letting a missing host node look like an emulator problem.
sed -e 's/accel = "kvm"/accel = "tcg"/' \
    -e "s#/usr/share/OVMF/OVMF_CODE.fd#$firmware/OVMF_CODE.fd#" \
    -e "s#file = \"/dev/fd/3\"#file = \"$work/run/nvram.fd\"#" \
    -e "s#path = \"/var/lib/lxd/devices/haos/config.mount\"#path = \"$work/run/config.mount\"#" \
    -e "s#path = \"/var/log/lxd/haos/#path = \"$work/run/#" \
    "$conf" | awk '
        /^\[device "qemu_vsock"\]/ { skip = 1; next }
        skip && /^\[/ { skip = 0 }
        !skip { print }
    ' > "$work/run/qemu.conf"

# A raw disk for the fd-set check below, the way LXD's VM root volume is a raw
# file (image conversion writes root.img as raw).
dd if=/dev/zero of="$work/run/root.img" bs=1M count=1 status=none

# The flags LXD itself passes, including the ones the wrapper is expected to
# translate or drop (-sandbox needs our seccomp build, -spice is filtered, and
# the config's spice sections along with it). -cpu host would need KVM, which a
# build container may not have, so the Hyper-V flag is exercised on top of max.
log "starting the emulator with $conf"
"$work/bin/qemu-system-x86_64" \
    -S \
    -name haos \
    -uuid 76a7135c-350d-4e2f-ab4f-ec7271adb277 \
    -cpu max,hv_passthrough \
    -nographic \
    -serial chardev:console \
    -nodefaults \
    -no-user-config \
    -sandbox on,obsolete=deny,elevateprivileges=allow,spawn=allow,resourcecontrol=deny \
    -spice "unix=on,disable-ticketing=on,addr=$work/run/qemu.spice" \
    -readconfig "$work/run/qemu.conf" \
    -netdev socket,id=checknet0,listen=127.0.0.1:0 \
    -pidfile "$work/run/qemu.pid" \
    -D "$work/run/qemu.log" \
    > "$work/run/out.log" 2>&1 &
emulator=$!

cleanup_emulator() {
    kill "$emulator" 2>/dev/null || true
    wait "$emulator" 2>/dev/null || true
}
trap 'cleanup_emulator; rm -rf "$work"' EXIT

# Wait for the monitor socket, or notice that it died instead.
for _ in $(seq 1 100); do
    [ -S "$work/run/qemu.monitor" ] && break
    if ! kill -0 "$emulator" 2>/dev/null; then
        warn "the emulator exited instead of starting"
        sed -n '1,40p' "$work/run/out.log" >&2
        exit 1
    fi
    sleep 0.2
done
[ -S "$work/run/qemu.monitor" ] || die "the emulator never opened its monitor socket"

log "every device and ROM in that config loaded"

# Now the part a loaded config does not cover: LXD adds the NIC over QMP after
# the emulator is running, and it types its integers as strings - which QEMU 9.2
# and later reject with "Invalid parameter type for 'bootindex', expected:
# integer". The device goes on one of the config's own pcie root ports, the way
# LXD attaches it, so pick one that LXD left free.
slot=$(awk '
    /^\[device "/ {
        name = $0; sub(/^\[device "/, "", name); sub(/"\]$/, "", name)
        current = name; is_port = 0
    }
    /^driver = "pcie-root-port"$/ { is_port = 1; ports[current] = 1 }
    /^bus = "/ { b = $0; sub(/^bus = "/, "", b); sub(/"$/, "", b); used[b] = 1 }
    END { for (p in ports) if (!(p in used)) { print p; exit } }
' "$work/run/qemu.conf")

if [ -z "$slot" ]; then
    warn "no free pcie root port in the config; skipping the QMP device check"
else
    log "adding LXD's root disk and NIC over QMP"
    python3 - "$work/run/qemu.monitor" "$slot" "$work/run/root.img" <<'PY'
import json, socket, sys, time

import array
import os

path = sys.argv[1]
bus = sys.argv[2]
disk = sys.argv[3]
sock = socket.socket(socket.AF_UNIX)
sock.settimeout(10)
deadline = time.time() + 10
while True:
    try:
        sock.connect(path)
        break
    except OSError:
        if time.time() > deadline:
            print("could not connect to the monitor at %s" % path)
            sys.exit(1)
        time.sleep(0.2)

stream = sock.makefile("rwb", buffering=0)

def read_message():
    while True:
        line = stream.readline()
        if not line:
            raise SystemExit("the monitor closed the connection")
        message = json.loads(line)
        if "event" in message:
            continue
        return message

def command(execute, arguments=None):
    request = {"execute": execute}
    if arguments is not None:
        request["arguments"] = arguments
    stream.write((json.dumps(request) + "\n").encode())
    return read_message()

read_message()  # the greeting
command("qmp_capabilities")

# LXD opens a VM's root disk itself, hands the descriptor to QEMU through an fd
# set, and points a block device at /dev/fdset/<id>. Note the open flags: no
# O_DIRECT - while the block device below asks QEMU for exactly that.
disk_fd = os.open(disk, os.O_RDWR)
message = json.dumps({"execute": "add-fd", "arguments": {"fdset-id": 0, "opaque": "qnap-vsock-check"}}) + "\n"
sock.sendmsg([message.encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [disk_fd]))])
result = read_message()
if "error" in result:
    print("add-fd rejected: %s" % result["error"].get("desc", result["error"]))
    sys.exit(1)

# LXD's blockDev map, verbatim (driver_qemu.go:3254): cache.direct is what makes
# QEMU want O_DIRECT from the fd set.
result = command("blockdev-add", {
    "aio": "native",
    "cache": {"direct": True, "no-flush": False},
    "discard": "unmap",
    "driver": "file",
    "node-name": "qemu_root",
    "read-only": False,
    "filename": "/dev/fdset/0",
})

if "error" in result:
    print("blockdev-add rejected: %s" % result["error"].get("desc", result["error"]))
    sys.exit(1)

print("blockdev-add accepted")

# LXD 5.0.2's NIC, verbatim: bootindex, vectors and friends are strings there.
result = command("device_add", {
    "driver": "virtio-net-pci",
    "netdev": "checknet0",
    "id": "qemu_eth0",
    "mac": "00:16:3e:00:00:01",
    "bus": bus,
    "addr": "00.0",
    "mq": "on",
    "vectors": "4",
    "bootindex": "0",
})

if "error" in result:
    print("device_add rejected: %s" % result["error"].get("desc", result["error"]))
    sys.exit(1)

print("device_add accepted")
PY
fi

log "done"
