#!/usr/bin/env bash
#
# Build the vsock stack for QNAP's kernel, inside the build container.
#
# Only three modules are built, out of tree, against QNAP's own kernel tree:
#
#   vsock.ko                             AF_VSOCK core      (/dev/vsock)
#   vmw_vsock_virtio_transport_common.ko shared transport
#   vhost_vsock.ko                       host side          (/dev/vhost-vsock)
#
# The kernel itself is never built. vhost.ko/vhost_iotlb.ko already exist on
# the NAS, so their symbols are only needed at insmod time.
#
# Environment (all optional, set by scripts/10-make-modules.sh):
#   KERNEL_MAJOR    kernel series in the QNAP tree (default 5.10)
#   TARGET_ARCH     kbuild ARCH= value (default: this machine's)
#   MODEL           QNAP model whose kernel_cfg .config to use
#   KERNEL_RELEASE  expected release string, asserted against the built modules
#   JOBS            parallel build jobs
set -euo pipefail

REPO_DIR=${REPO_DIR:-/work}
KERNEL_MAJOR=${KERNEL_MAJOR:-5.10}
TARGET_ARCH=${TARGET_ARCH:-$(uname -m)}
JOBS=${JOBS:-$(nproc)}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SRC="$REPO_DIR/build/src"
TREE="$SRC/GPL_QTS/src/linux-$KERNEL_MAJOR"
CFG_DIR="$SRC/GPL_QTS/kernel_cfg"
OUT_BASE="$REPO_DIR/modules"

[ -d "$TREE" ] || die "kernel tree not found: $TREE (run scripts/00-fetch-gpl.sh first)"

# ---------------------------------------------------------------- config ----

prepare_config() {
    local cfg="" config_changed=0
    if [ -n "${MODEL:-}" ]; then
        # QNAP names these linux-<series>-<arch>.config; glob and prefer the
        # one for the target architecture instead of assuming a name.
        local candidate
        for candidate in "$CFG_DIR/$MODEL"/linux-"$KERNEL_MAJOR"-*.config; do
            [ -f "$candidate" ] || continue
            case "$candidate" in
                *-"$TARGET_ARCH".config) cfg=$candidate; break ;;
            esac
            [ -n "$cfg" ] || cfg=$candidate
        done
        [ -n "$cfg" ] || die "no kernel config for model $MODEL in $CFG_DIR"
        log "using model config: $cfg"
    fi

    if [ -n "$cfg" ]; then
        if [ -f "$TREE/.config" ] && diff -q "$cfg" "$TREE/.config" >/dev/null 2>&1; then
            log "tree already configured with this config"
        else
            log "installing config into the tree"
            cp "$cfg" "$TREE/.config"
            config_changed=1
        fi
    elif [ -f "$TREE/.config" ]; then
        log "using the config shipped in the tree"
    else
        die "no kernel config found (pass MODEL=... or fetch a tree that ships .config)"
    fi

    # A fully built tree (as published by QNAP) already has everything the
    # module build needs; only prepare it when something is actually missing.
    local need_prepare=0
    for f in include/generated/autoconf.h include/config/auto.conf Module.symvers \
             scripts/mod/modpost scripts/basic/fixdep; do
        [ -e "$TREE/$f" ] || { log "missing $f -> preparing"; need_prepare=1; }
    done

    if [ "$config_changed" = 1 ]; then
        log "olddefconfig"
        make -C "$TREE" ARCH="$TARGET_ARCH" olddefconfig
        need_prepare=1
    fi

    if [ "$need_prepare" = 1 ]; then
        log "modules_prepare"
        make -C "$TREE" ARCH="$TARGET_ARCH" modules_prepare
    fi
}

# ----------------------------------------------------------- module build ---

build_modules() {
    local symvers="$REPO_DIR/build/symvers"
    mkdir -p "$symvers"

    # Pass 1: AF_VSOCK core. Also produces the symbol table the two other
    # modules link against.
    log "building vsock.ko"
    make -C "$TREE" ARCH="$TARGET_ARCH" M="$TREE/net/vmw_vsock" \
        CONFIG_VSOCKETS=m \
        CONFIG_VSOCKETS_DIAG=n \
        CONFIG_VSOCKETS_LOOPBACK=n \
        CONFIG_VIRTIO_VSOCKETS=n \
        CONFIG_VIRTIO_VSOCKETS_COMMON=n \
        CONFIG_HYPERV_VSOCKETS=n \
        -j"$JOBS" modules
    cp "$TREE/net/vmw_vsock/Module.symvers" "$symvers/vsock.symvers"

    # Pass 2: shared virtio-vsock transport. Kbuild rewrites the directory's
    # Module.symvers on every pass, so keep a copy of each pass.
    log "building vmw_vsock_virtio_transport_common.ko"
    make -C "$TREE" ARCH="$TARGET_ARCH" M="$TREE/net/vmw_vsock" \
        CONFIG_VSOCKETS=n \
        CONFIG_VSOCKETS_DIAG=n \
        CONFIG_VSOCKETS_LOOPBACK=n \
        CONFIG_VIRTIO_VSOCKETS=n \
        CONFIG_VIRTIO_VSOCKETS_COMMON=m \
        CONFIG_HYPERV_VSOCKETS=n \
        KBUILD_EXTRA_SYMBOLS="$symvers/vsock.symvers" \
        -j"$JOBS" modules
    cp "$TREE/net/vmw_vsock/Module.symvers" "$symvers/common.symvers"

    # Pass 3: vhost transport used by QEMU on the host.
    log "building vhost_vsock.ko"
    make -C "$TREE" ARCH="$TARGET_ARCH" M="$TREE/drivers/vhost" \
        CONFIG_VHOST_VSOCK=m \
        CONFIG_VHOST_NET=n \
        CONFIG_VHOST_SCSI=n \
        KBUILD_EXTRA_SYMBOLS="$symvers/vsock.symvers $symvers/common.symvers" \
        -j"$JOBS" modules
}

collect() {
    local dest="$OUT_BASE/${KERNEL_RELEASE:?KERNEL_RELEASE is required}"
    mkdir -p "$dest"

    local ko
    for ko in "$TREE/net/vmw_vsock/vsock.ko" \
              "$TREE/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko" \
              "$TREE/drivers/vhost/vhost_vsock.ko"; do
        [ -f "$ko" ] || die "expected module not built: $ko"
        install -m 644 "$ko" "$dest/"
    done

    log "modules in $dest:"
    for ko in "$dest"/*.ko; do
        printf '    %s\n' "$(basename "$ko")"
        modinfo -F vermagic "$ko" | sed 's/[[:space:]]*$//;s/^/        vermagic: /'
    done

    # The vermagic must match the target kernel exactly; nothing else identifies
    # the ABI on QNAP kernels (CONFIG_MODVERSIONS is off). modinfo pads the
    # value with a trailing space, hence the trimming.
    local expected="$KERNEL_RELEASE SMP mod_unload"
    for ko in "$dest"/*.ko; do
        got=$(modinfo -F vermagic "$ko" | sed 's/[[:space:]]*$//')
        [ "$got" = "$expected" ] ||
            die "$(basename "$ko"): vermagic '$got' != expected '$expected'"
    done
    log "vermagic matches '$expected' for all modules"

    {
        printf '{\n'
        printf '  "kernel_release": "%s",\n' "$KERNEL_RELEASE"
        printf '  "kernel_major": "%s",\n' "$KERNEL_MAJOR"
        printf '  "vermagic": "%s"\n' "$expected"
        printf '}\n'
    } > "$dest/facts.json"
    ( cd "$dest" && sha256sum ./*.ko | sed 's/^\([0-9a-f]*\)  \.\//\1  /' > SHA256SUMS )
}

prepare_config
build_modules
collect
log "done"
