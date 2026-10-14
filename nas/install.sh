#!/bin/sh
#
# Install the vsock stack on a QNAP NAS without App Center.
#
# Run this from the directory you unpacked the tarball into, as root:
#
#   tar xzf qnap-vsock-<release>.tar.gz
#   cd qnap-vsock
#   ./install.sh
#
# It loads the modules, installs the QEMU shim and the UEFI firmware, and
# restarts Container Station's LXD daemon only if nothing is running. See
# README.md for how to make it survive a reboot.
set -eu

PREFIX=$(cd "$(dirname "$0")" && pwd)
HELPER="$PREFIX/shared/qnap-vsock.sh"
KVER=$(uname -r)

[ "$(id -u)" = 0 ] || { echo "run me as root" >&2; exit 1; }
[ -x "$HELPER" ] || { echo "missing $HELPER" >&2; exit 1; }

if [ ! -d "$PREFIX/modules/$KVER" ]; then
    echo "No modules built for this kernel ($KVER)." >&2
    echo "Available:" >&2
    ls "$PREFIX/modules" 2>/dev/null >&2 || echo "  (none)" >&2
    echo "Rebuild with ./build.sh modules --kernel-release $KVER" >&2
    exit 1
fi

# Remember where the payload lives so a boot hook can find it.
STATE_DIR=${QNAP_VSOCK_STATE:-/var/lib/qnap-vsock}
mkdir -p "$STATE_DIR"
echo "$PREFIX" > "$STATE_DIR/prefix"

echo "Installing vsock support for kernel $KVER from $PREFIX"
"$HELPER" install

echo
"$HELPER" status
echo
echo "Next: 'lxc info' should no longer report missing vsock support."
echo "To keep this across reboots install the QPKG (nas/qpkg) or wire up"
echo "nas/autorun/autorun.sh; see README.md."
