#!/usr/bin/env bash
#
# Fetch and unpack QNAP's GPL kernel source.
#
# QNAP publishes the full kernel build tree (sources, .config, Module.symvers)
# split over several tar.gz parts. This downloads the parts, concatenates them
# and extracts only the kernel tree and the per-model configurations, instead
# of the whole ~3 GB archive (which also carries an unrelated linux-4.14 tree).
#
# The kernel release is NOT hardcoded anywhere in this repository: it is read
# back from the extracted tree by scripts/kernel-release.sh.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

QTS_GPL=${QTS_GPL:-$QTS_GPL_DEFAULT}
KERNEL_MAJOR=${KERNEL_MAJOR:-$KERNEL_MAJOR_DEFAULT}

src=$(src_dir)
gpl="$src/gpl"
mkdir -p "$gpl"

log "QTS GPL release: $QTS_GPL"

n=0
for url in $(gpl_parts "$QTS_GPL"); do
    file="$gpl/QTS_Kernel_${QTS_GPL}.${n}.tar.gz"
    n=$((n + 1))
    if [ -s "$file" ] && [ "$(stat -c %s "$file")" -gt 100000000 ]; then
        log "already downloaded: $(basename "$file")"
        continue
    fi
    log "downloading $(basename "$file")"
    curl -fL --retry 3 --retry-delay 5 -C - -o "$file" "$url"
done

[ "$n" -gt 0 ] || die "no download URLs for QTS GPL release $QTS_GPL"

combined="$gpl/QTS_Kernel_${QTS_GPL}_combined.tar.gz"
if [ ! -s "$combined" ]; then
    log "concatenating $n parts"
    : > "$combined"
    for i in $(seq 0 $((n - 1))); do
        cat "$gpl/QTS_Kernel_${QTS_GPL}.${i}.tar.gz" >> "$combined"
    done
fi

log "verifying archive content"
# grep -c reads the whole stream on purpose: with pipefail, letting grep -q
# exit early would make tar die of SIGPIPE and fail the pipeline.
tar -tzf "$combined" 2>/dev/null |
    grep -c "^GPL_QTS/src/linux-${KERNEL_MAJOR}/" >/dev/null ||
    die "archive does not contain GPL_QTS/src/linux-${KERNEL_MAJOR}/"

marker="$src/.extracted-$QTS_GPL"
if [ -f "$marker" ]; then
    log "already extracted"
else
    log "extracting GPL_QTS/src/linux-${KERNEL_MAJOR} + GPL_QTS/kernel_cfg"
    tar -xzf "$combined" -C "$src" \
        --wildcards \
        --exclude="GPL_QTS/src/linux-4.14*" \
        "GPL_QTS/src/linux-${KERNEL_MAJOR}*" \
        "GPL_QTS/kernel_cfg*"
    touch "$marker"
fi

log "available model configurations:"
ls "$(kernel_cfg_dir)" 2>/dev/null | sed 's/^/    /' | sed -n '1,20p' || warn "no kernel_cfg directory"

log "kernel release in tree: $("$(dirname "$(readlink -f "$0")")/kernel-release.sh")"
log "done"
