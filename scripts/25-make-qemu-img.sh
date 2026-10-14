#!/usr/bin/env bash
#
# Build the static qemu-img that LXD needs on the NAS.
#
# LXD uses it for every image operation, including unpacking a qcow2 image into
# a VM's disk, and neither QTS nor Container Station ship one.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

QEMU_VERSION=${QEMU_VERSION:-11.1.2}
QEMU_IMG_IMAGE=${QEMU_IMG_IMAGE:-localhost/qnap-vsock-qemu-img:${QEMU_VERSION}}

dest="$REPO_DIR/build/bin"
mkdir -p "$dest"

if [ -x "$dest/qemu-img" ] && [ "${FORCE:-0}" != 1 ]; then
    log "qemu-img already built: $dest/qemu-img ($(stat -c %s "$dest/qemu-img") bytes)"
    exit 0
fi

log "building qemu-img $QEMU_VERSION (static, tools only)"
sudo podman build -q --network host -t "$QEMU_IMG_IMAGE" \
    --build-arg QEMU_VERSION="$QEMU_VERSION" \
    -f "$REPO_DIR/containers/qemu-img.Containerfile" "$REPO_DIR/containers"

log "extracting the binary"
rm -f "$dest/qemu-img"
sudo podman run --rm --user "$(id -u):$(id -g)" \
    -v "$dest":/out "$QEMU_IMG_IMAGE" cp /qemu-img /out/qemu-img
chmod 755 "$dest/qemu-img"

log "built $dest/qemu-img ($(stat -c %s "$dest/qemu-img") bytes)"
"$dest/qemu-img" --version || die "the built qemu-img does not run here"
