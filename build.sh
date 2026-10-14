#!/usr/bin/env bash
#
# Build everything needed to get LXD VMs working on a QNAP NAS.
#
#   ./build.sh              fetch, build the modules, fetch OVMF, build the QPKG
#   ./build.sh gpl          fetch/unpack QNAP's GPL kernel source
#   ./build.sh modules      build the vsock modules
#   ./build.sh ovmf         fetch the UEFI firmware
#   ./build.sh tools        build the static tools LXD needs (qemu-img, prlimit)
#   ./build.sh qpkg         build the installable QPKG
#   ./build.sh clean        remove build artifacts
#
# Environment:
#   MODEL            QNAP model whose kernel config to use (default: TS-X53II)
#   KERNEL_RELEASE   assert this release instead of the tree's own
#   QTS_GPL          QNAP GPL release to fetch (default 5.2.3.20250218)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/scripts/lib.sh"

cmd=${1:-all}

case "$cmd" in
    all)
        "$REPO_DIR/scripts/00-fetch-gpl.sh"
        "$REPO_DIR/scripts/10-make-modules.sh"
        "$REPO_DIR/scripts/20-fetch-ovmf.sh"
        "$REPO_DIR/scripts/25-make-tools.sh"
        "$REPO_DIR/scripts/30-make-qpkg.sh"
        ;;
    gpl) "$REPO_DIR/scripts/00-fetch-gpl.sh" ;;
    modules) "$REPO_DIR/scripts/10-make-modules.sh" "${@:2}" ;;
    ovmf) "$REPO_DIR/scripts/20-fetch-ovmf.sh" ;;
    tools) "$REPO_DIR/scripts/25-make-tools.sh" ;;
    qpkg) "$REPO_DIR/scripts/30-make-qpkg.sh" ;;
    clean) rm -rf "$REPO_DIR/build"; log "removed build/" ;;
    *) die "unknown command: $cmd (see the header of build.sh)" ;;
esac
