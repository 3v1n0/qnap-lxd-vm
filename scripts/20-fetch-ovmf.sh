#!/usr/bin/env bash
#
# Fetch the UEFI firmware LXD needs to boot VMs.
#
# LXD hardcodes /usr/share/OVMF (overridable via LXD_OVMF_PATH) and runs
# qemu with -bios <path>/OVMF_CODE.fd, then seeds the per-VM NVRAM from
# OVMF_VARS.fd. Secure boot adds the .ms variants.
#
# Nothing is fetched from a hardcoded URL: the firmware is the ovmf package of
# a pinned Ubuntu release, installed by apt inside its own container image. The
# image's release is the pin (OVMF_UBUNTU_RELEASE, default 20.04, whose edk2
# snapshot is contemporary with the QEMU Container Station ships), so upgrading
# the firmware is changing one variable, and once the image exists nothing
# needs the network at all.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

release=${OVMF_UBUNTU_RELEASE:-$OVMF_UBUNTU_RELEASE_DEFAULT}
image=${OVMF_IMAGE:-localhost/qnap-lxd-vm-ovmf:${release}}

work="$REPO_DIR/build/ovmf"
dest="$REPO_DIR/build/firmware"

mkdir -p "$work" "$dest"

if ! sudo podman image exists "$image" 2>/dev/null; then
    log "building container image $image (Ubuntu $release)"
    sudo podman build --network host \
        --build-arg UBUNTU="$release" \
        --build-arg MIRROR="${UBUNTU_MIRROR:-}" \
        -f "$REPO_DIR/containers/ovmf.Containerfile" \
        -t "$image" "$REPO_DIR/containers"
fi

log "extracting"
rm -rf "$work/extract"
mkdir -p "$work/extract"
sudo podman run --rm --user "$(id -u):$(id -g)" \
    -v "$work/extract":/out "$image" \
    sh -c 'cp -rL /usr/share/OVMF/. /out/'

# Resolve the four files LXD may ask for. Symlinks are followed on purpose:
# the /usr/share/OVMF layout uses them (OVMF_CODE.ms.fd -> OVMF_CODE.secboot.fd).
copy_firmware() {
    local target=$1 src
    shift
    for src in "$@"; do
        if [ -e "$src" ]; then
            cp -L "$src" "$dest/$target"
            log "  $target <- ${src#"$work/extract"}"
            return 0
        fi
    done
    warn "  $target not found in package"
    return 1
}

base="$work/extract"
copy_firmware OVMF_CODE.fd "$base/OVMF_CODE.fd"
copy_firmware OVMF_VARS.fd "$base/OVMF_VARS.fd"
copy_firmware OVMF_CODE.ms.fd "$base/OVMF_CODE.ms.fd" "$base/OVMF_CODE.secboot.fd"
copy_firmware OVMF_VARS.ms.fd "$base/OVMF_VARS.ms.fd"

log "verifying firmware"
# OVMF_CODE.fd is ~2 MB and OVMF_VARS.fd 128 KB in the 2 MB flash layout; the
# 4 MB variants are bigger. Only catch obviously broken files here.
for f in "$dest"/*.fd; do
    base=$(basename "$f")
    size=$(stat -c %s "$f")
    case "$base" in
        OVMF_CODE*) min=1000000 ;;
        *) min=65536 ;;
    esac
    [ "$size" -gt "$min" ] || die "$base looks truncated ($size bytes)"
    printf '    %-18s %s bytes\n' "$base" "$size"
done

[ -s "$dest/OVMF_CODE.fd" ] || die "OVMF_CODE.fd is required"
[ -s "$dest/OVMF_VARS.fd" ] || die "OVMF_VARS.fd is required"

log "done ($dest)"
