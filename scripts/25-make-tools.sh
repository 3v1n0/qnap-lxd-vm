#!/usr/bin/env bash
#
# Build the static tools LXD needs on the NAS:
#
#   qemu-img  every image operation (info, convert, create, amend, commit)
#   prlimit   LXD wraps qemu-img in it to bound its CPU and memory use
#   nice      LXD runs image conversion through it at low priority
#
# Both are built statically (Alpine, musl) so they are single files with no
# libraries to ship and nothing to match on the NAS.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

QEMU_VERSION=${QEMU_VERSION:-11.1.2}
QEMU_IMG_IMAGE=${QEMU_IMG_IMAGE:-localhost/qnap-vsock-qemu-img:${QEMU_VERSION}}
PRLIMIT_IMAGE=${PRLIMIT_IMAGE:-localhost/qnap-vsock-prlimit:1}
NICE_IMAGE=${NICE_IMAGE:-localhost/qnap-vsock-nice:1}

dest="$REPO_DIR/build/bin"
mkdir -p "$dest"

# Copy a built file out of an image, owned by us.
extract() {
    local image=$1 src=$2 name
    name=$(basename "$src")
    rm -f "$dest/$name"
    sudo podman run --rm --user "$(id -u):$(id -g)" -v "$dest":/out "$image" \
        cp "$src" "/out/$name"
    chmod 755 "$dest/$name"
}

if [ -x "$dest/qemu-img" ] && [ "${FORCE:-0}" != 1 ]; then
    log "qemu-img already built: $dest/qemu-img ($(stat -c %s "$dest/qemu-img") bytes)"
else
    log "building qemu-img $QEMU_VERSION (static, tools only)"
    sudo podman build --network host -t "$QEMU_IMG_IMAGE" \
        --build-arg QEMU_VERSION="$QEMU_VERSION" \
        -f "$REPO_DIR/containers/qemu-img.Containerfile" "$REPO_DIR/containers"
    extract "$QEMU_IMG_IMAGE" /qemu-img
    log "built $dest/qemu-img ($(stat -c %s "$dest/qemu-img") bytes)"
fi

if [ -x "$dest/prlimit" ] && [ "${FORCE:-0}" != 1 ]; then
    log "prlimit already built: $dest/prlimit ($(stat -c %s "$dest/prlimit") bytes)"
else
    log "building prlimit (static, our own small implementation)"
    sudo podman build --network host -t "$PRLIMIT_IMAGE" \
        -f "$REPO_DIR/containers/prlimit.Containerfile" "$REPO_DIR/containers"
    extract "$PRLIMIT_IMAGE" /prlimit
    log "built $dest/prlimit ($(stat -c %s "$dest/prlimit") bytes)"
fi

if [ -x "$dest/nice" ] && [ "${FORCE:-0}" != 1 ]; then
    log "nice already built: $dest/nice ($(stat -c %s "$dest/nice") bytes)"
else
    log "building nice (static, our own small implementation)"
    sudo podman build --network host -t "$NICE_IMAGE" \
        -f "$REPO_DIR/containers/nice.Containerfile" "$REPO_DIR/containers"
    extract "$NICE_IMAGE" /nice
    log "built $dest/nice ($(stat -c %s "$dest/nice") bytes)"
fi

for tool in "$dest"/*; do
    [ -x "$tool" ] || continue
    log "$(basename "$tool"): $("$tool" --version 2>&1 | sed -n 1p)"
done
