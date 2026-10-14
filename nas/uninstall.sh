#!/bin/sh
#
# Undo nas/install.sh: unload the modules, drop the QEMU shim.
#
# Firmware in /usr/share/OVMF and the modules themselves are left alone; the
# helper prints where they are. Remove them by hand if you really want to.
set -eu

PREFIX=$(cd "$(dirname "$0")" && pwd)
HELPER="$PREFIX/shared/qnap-vsock.sh"

[ "$(id -u)" = 0 ] || { echo "run me as root" >&2; exit 1; }

"$HELPER" uninstall
echo
echo "Note: Container Station's LXD still believes VMs are unsupported until it"
echo "restarts; 'unload' only removes the modules."
