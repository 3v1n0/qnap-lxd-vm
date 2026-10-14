#!/usr/bin/env bash
#
# Print the kernel release of the extracted QNAP kernel tree.
#
# This is the single place that knows how to derive the release string; every
# other script asks here instead of hardcoding it, so a future QNAP GPL drop
# (or a different kernel version) needs no code changes.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

tree=$(kernel_tree)

rel=""
if [ -f "$tree/include/config/kernel.release" ]; then
    rel=$(head -n1 "$tree/include/config/kernel.release")
elif [ -f "$tree/.config" ]; then
    localver=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "$tree/.config" | tail -1)
    if [ -f "$tree/Makefile" ]; then
        base=$(make -s -C "$tree" kernelversion 2>/dev/null | tail -1 || true)
        [ -n "$base" ] && rel="$base$localver"
    fi
elif [ -f "$tree/Makefile" ]; then
    base=$(sed -n 's/^VERSION *= *//p; s/^PATCHLEVEL *= *//p; s/^SUBLEVEL *= *//p; s/^EXTRAVERSION *= *//p' "$tree/Makefile" | head -4)
    rel=$(printf '%s' "$base" | paste -sd. -)
    [ -n "$rel" ] || rel=$(make -s -C "$tree" kernelrelease 2>/dev/null | tail -1 || true)
fi

[ -n "$rel" ] || die "cannot determine kernel release from $tree"
printf '%s\n' "$rel"
