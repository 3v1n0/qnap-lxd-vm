#!/usr/bin/env bash
#
# Build the vsock modules in the build container.
#
# Usage: scripts/10-make-modules.sh [--model MODEL] [--kernel-release REL]
#
# MODEL selects the QNAP kernel_cfg directory to configure the tree with.
# KERNEL_RELEASE defaults to the release of the QNAP tree itself; pass it
# explicitly to assert against a specific NAS (e.g. the output of uname -r).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

MODEL=${MODEL:-$MODEL_DEFAULT}
KERNEL_RELEASE=${KERNEL_RELEASE:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL=$2; shift 2 ;;
        --model=*) MODEL=${1#*=}; shift ;;
        --kernel-release) KERNEL_RELEASE=$2; shift 2 ;;
        --kernel-release=*) KERNEL_RELEASE=${1#*=}; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

KERNEL_MAJOR=${KERNEL_MAJOR:-$KERNEL_MAJOR_DEFAULT}
export KERNEL_MAJOR

# kbuild's name for the architecture, not necessarily uname -m.
TARGET_ARCH=${TARGET_ARCH:-$(kernel_arch)}

if ! sudo podman image exists "$BUILD_IMAGE" 2>/dev/null; then
    log "building container image $BUILD_IMAGE"
    # pasta (podman's default network) is broken in this environment; the
    # image build needs the network for apt and the QDK clone.
    sudo podman build --network host \
        --build-arg UBUNTU="$BUILDER_UBUNTU" \
        --build-arg MIRROR="${UBUNTU_MIRROR:-}" \
        -t "$BUILD_IMAGE" \
        -f "$REPO_DIR/containers/builder.Containerfile" "$REPO_DIR/containers"
fi

[ -n "$KERNEL_RELEASE" ] || KERNEL_RELEASE=$("$REPO_DIR/scripts/kernel-release.sh")
log "target kernel release: $KERNEL_RELEASE"

sudo podman run --rm \
    --network host \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TMPDIR=/tmp \
    -e KERNEL_MAJOR="$KERNEL_MAJOR" \
    -e TARGET_ARCH="$TARGET_ARCH" \
    -e MODEL="$MODEL" \
    -e KERNEL_RELEASE="$KERNEL_RELEASE" \
    -e JOBS="$(nproc)" \
    -v "$REPO_DIR":/work \
    -w /work \
    "$BUILD_IMAGE" \
    bash /work/scripts/in-container/build-modules.sh
