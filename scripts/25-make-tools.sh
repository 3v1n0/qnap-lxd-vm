#!/usr/bin/env bash
#
# Build the static tools LXD needs on the NAS:
#
#   qemu-img            every image operation (info, convert, create, amend)
#   qemu-system-x86_64  the VMs themselves (LXD needs -sandbox, so seccomp)
#   qemu-datadir/       the option ROMs and keymaps it loads at runtime
#   prlimit   LXD wraps qemu-img in it to bound its CPU and memory use
#   nice      LXD runs image conversion through it at low priority
#   virtfs-proxy-helper
#             what LXD starts for a VM's 9p shares: it prefers virtiofs, and
#             virtiofsd is a separate Rust project we do not ship, so this
#             fallback is what a disk device pointing at a host path needs
#
# Both are built statically (Alpine, musl) so they are single files with no
# libraries to ship and nothing to match on the NAS.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

# Not "latest" on purpose. LXD 5.0.2 predates two QEMU changes that both break a
# VM start, and 9.0.x is the newest release that avoids both:
#
#   * QEMU 9.1 added O_DIRECT to the mask used when matching a file descriptor it
#     was handed through an fd set. LXD opens VM disks without O_DIRECT but asks
#     QEMU for it (cache.direct), so 9.1 and later refuse with "Failed to find
#     file descriptor with matching flags=0x4002".
#   * QEMU 9.2 started rejecting string-typed integers in QMP parameters, and
#     LXD types bootindex/vectors that way ("Invalid parameter type for
#     'bootindex', expected: integer").
#
# tests/qemu-config-check.sh exercises both paths against a real LXD config, so
# bumping this means proving the newer release still works.
QEMU_VERSION=${QEMU_VERSION:-$QEMU_VERSION_DEFAULT}
QEMU_IMAGE=${QEMU_IMAGE:-localhost/qnap-lxd-vm-qemu:${QEMU_VERSION}}
PRLIMIT_IMAGE=${PRLIMIT_IMAGE:-localhost/qnap-lxd-vm-prlimit:1}
NICE_IMAGE=${NICE_IMAGE:-localhost/qnap-lxd-vm-nice:1}

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

if [ -x "$dest/qemu-img" ] && [ -x "$dest/qemu-system-x86_64" ] &&
   [ -x "$dest/virtfs-proxy-helper" ] && [ "${FORCE:-0}" != 1 ]; then
    log "qemu already built: $dest/qemu-img, $dest/qemu-system-x86_64, $dest/virtfs-proxy-helper"
else
    log "building qemu $QEMU_VERSION (static, x86_64-softmmu, seccomp)"
    sudo podman build --network host -t "$QEMU_IMAGE" \
        --build-arg QEMU_VERSION="$QEMU_VERSION" \
        -f "$REPO_DIR/containers/qemu.Containerfile" "$REPO_DIR/containers"
    extract "$QEMU_IMAGE" /qemu-img
    extract "$QEMU_IMAGE" /qemu-system-x86_64
    extract "$QEMU_IMAGE" /virtfs-proxy-helper

    log "extracting the QEMU data directory (option ROMs and keymaps)"
    container=$(sudo podman create "$QEMU_IMAGE")
    rm -rf "$REPO_DIR/build/qemu-datadir"
    mkdir -p "$REPO_DIR/build/qemu-datadir"
    sudo podman cp "$container:/qemu-datadir/." "$REPO_DIR/build/qemu-datadir/"
    sudo podman rm "$container" >/dev/null
    sudo chown -R "$(id -u):$(id -g)" "$REPO_DIR/build/qemu-datadir"

    log "built $dest/qemu-img ($(stat -c %s "$dest/qemu-img") bytes)"
    log "built $dest/qemu-system-x86_64 ($(stat -c %s "$dest/qemu-system-x86_64") bytes)"
    log "QEMU datadir: $(ls "$REPO_DIR/build/qemu-datadir" | wc -l) entries, $(du -sh "$REPO_DIR/build/qemu-datadir" | cut -f1)"
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
