#!/usr/bin/env bash
#
# Shared helpers for the build scripts.

set -euo pipefail

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# Nothing in this repository hardcodes the kernel release: the build reads it
# back from the QNAP kernel tree (scripts/kernel-release.sh) and the NAS side
# derives it from uname -r, then cross-checks the two.
QTS_GPL_DEFAULT=${QTS_GPL_DEFAULT:-5.2.3.20250218}
KERNEL_MAJOR_DEFAULT=${KERNEL_MAJOR_DEFAULT:-5.10}

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf '!!! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

src_dir() { printf '%s' "$REPO_DIR/build/src"; }
kernel_tree() { printf '%s/GPL_QTS/src/linux-%s' "$(src_dir)" "${KERNEL_MAJOR:-$KERNEL_MAJOR_DEFAULT}"; }
kernel_cfg_dir() { printf '%s/GPL_QTS/kernel_cfg' "$(src_dir)"; }
modules_dir() { printf '%s/modules' "$REPO_DIR"; }

# gpl_parts RELEASE -> list of download URLs, in order.
# RELEASE looks like 5.2.3.20250218 and is published under "QTS 5.2.3/".
gpl_parts() {
    local rel=$1 qts base
    qts=$(printf '%s' "$rel" | cut -d. -f1-3)
    base="https://sourceforge.net/projects/qosgpl/files/QNAP%20NAS%20GPL%20Source/QTS%20${qts}"
    printf '%s/QTS_Kernel_%s.0.tar.gz/download\n' "$base" "$rel"
    printf '%s/QTS_Kernel_%s.1.tar.gz/download\n' "$base" "$rel"
}

# pick_kernel_config MODEL -> path to a usable .config

# vermagic KO -> the vermagic recorded inside a built module.
vermagic_of() {
    local ko=$1
    modinfo -F vermagic "$ko" 2>/dev/null || true
}

# kernel_arch: translate uname -m into the name kbuild wants for ARCH=.
# Note the kernel calls 64-bit ARM "arm64" while uname reports "aarch64".
kernel_arch() {
    case "$(uname -m)" in
        x86_64) printf 'x86_64' ;;
        aarch64) printf 'arm64' ;;
        armv7l | armv8l | armv6l) printf 'arm' ;;
        i686 | i586 | i386) printf 'x86' ;;
        *) uname -m ;;
    esac
}

# host tool: run a command inside the build container image.
BUILD_IMAGE=${BUILD_IMAGE:-localhost/qnap-vsock-builder:20.04}
