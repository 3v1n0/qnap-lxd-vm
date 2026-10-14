#!/bin/bash
#
# Load the vsock stack on a QNAP NAS and make LXD able to run VMs.
#
# Shared by the QPKG service program and by the plain install.sh, so there is
# only one implementation of the load/verify logic.
#
# Usage: qnap-vsock.sh <action>
#
#   install       shim + firmware + load, and say so if the running LXD is stale
#   uninstall     unload the modules and drop the shim
#   load | unload the modules only
#   status        what is loaded / present
#   preflight     everything LXD checks, plus whether the running daemon holds
#                 on to a stale "vsock missing" answer
#   check-file    is a given .ko usable on the running kernel?
#   process-start seconds after boot when a pid started (debugging)
#
# Layout it expects (both the QPKG and the tarball use it):
#
#   <prefix>/shared/qnap-vsock.sh
#   <prefix>/modules/<kernel release>/*.ko
#   <prefix>/firmware/OVMF_*.fd
#
# Nothing here hardcodes a kernel release: it always comes from uname -r and
# the modules are checked against the vermagic of a module QNAP itself built
# for that same kernel.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# The payload can sit anywhere: the QPKG root, an unpacked tarball, with or
# without the shared/ level flattened by qbuild. Find the directory that
# actually holds the modules and firmware.
resolve_prefix() {
    local cand
    for cand in ${QNAP_VSOCK_PREFIX:-} "$SCRIPT_DIR/.." "$SCRIPT_DIR" "$SCRIPT_DIR/../.."; do
        [ -n "$cand" ] || continue
        [ -d "$cand/modules" ] && { (cd "$cand" && pwd); return 0; }
    done
    printf '%s' "$SCRIPT_DIR/.."
}

PREFIX=$(resolve_prefix)

MODULES_DIR=${QNAP_VSOCK_MODULES:-$PREFIX/modules/$(uname -r)}
FIRMWARE_DIR=${QNAP_VSOCK_FIRMWARE:-$PREFIX/firmware}
STATE_DIR=${QNAP_VSOCK_STATE:-/var/lib/qnap-vsock}
LOG_FILE=${QNAP_VSOCK_LOG:-$STATE_DIR/qnap-vsock.log}

# LXD looks these up itself; do not invent paths for it.
OVMF_DIR=${LXD_OVMF_PATH:-/usr/share/OVMF}
BIN_DIR=${QNAP_VSOCK_BIN_DIR:-/usr/local/bin}

# LXD looks qemu up as qemu-system-<arch>, which is what uname -m reports on
# both x86_64 and arm64 QNAP models.
QEMU_BIN="qemu-system-$(uname -m)"

# Load order matters at insmod time because modprobe/depmod are not involved.
MODULE_ORDER="vsock vmw_vsock_virtio_transport_common vhost_vsock"

mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR=/tmp

# Site-specific overrides (see the QNAP_VSOCK_* variables above).
CONFIG_FILE=${QNAP_VSOCK_CONFIG:-$STATE_DIR/config}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

log() { printf '[qnap-vsock] %s\n' "$*"; printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null; }
warn() { printf '[qnap-vsock] WARNING: %s\n' "$*" >&2; printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null; }
die() { warn "$*"; exit 1; }

kver() { uname -r; }

vermagic_of() {
    if [ -n "${MODINFO:-}" ]; then
        "$MODINFO" -F vermagic "$1" 2>/dev/null
    elif command -v modinfo >/dev/null 2>&1; then
        modinfo -F vermagic "$1" 2>/dev/null
    else
        strings "$1" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n1
    fi
}

# The reference is a module QNAP built for this very kernel, so the expected
# flags (SMP, preemption model, retpoline, ...) come from the target itself.
reference_vermagic() {
    local f
    for f in /lib/modules/"$(kver)"/*.ko; do
        [ -f "$f" ] || continue
        f=$(vermagic_of "$f")
        [ -n "$f" ] && { printf '%s' "$f"; return 0; }
    done
    # Some trees keep the modules in subdirectories.
    f=$(find /lib/modules/"$(kver)" -name '*.ko' 2>/dev/null | head -n1)
    if [ -n "$f" ]; then
        f=$(vermagic_of "$f")
        [ -n "$f" ] && { printf '%s' "$f"; return 0; }
    fi
    return 1
}

check_vermagic() {
    local ko=$1 got ref
    got=$(vermagic_of "$ko")
    [ -n "$got" ] || die "$(basename "$ko"): cannot read vermagic"
    if ref=$(reference_vermagic); then
        [ "$got" = "$ref" ] ||
            die "$(basename "$ko"): vermagic '$got' does not match the kernel's '$ref'"
    else
        case "$got" in
            "$(kver) "*) : ;;
            *) die "$(basename "$ko"): vermagic '$got' is not for $(kver)" ;;
        esac
        case "$got" in
            *modversions*) die "$(basename "$ko"): built with CONFIG_MODVERSIONS, will not load" ;;
        esac
    fi
}

is_loaded() { [ -d "/sys/module/$1" ]; }

module_path() { printf '%s/%s.ko' "$MODULES_DIR" "$1"; }

load_module() {
    local name=$1 ko
    ko=$(module_path "$name")
    if [ ! -f "$ko" ]; then
        warn "there is no module for this kernel: $ko"
        warn "build one with: ./build.sh modules --kernel-release $(kver)"
        return 1
    fi
    if is_loaded "$name"; then
        log "$name is already loaded"
        return 0
    fi
    check_vermagic "$ko"
    insmod "$ko" || die "failed to load $ko"
    log "loaded $name"
}

# devtmpfs normally creates these, but QNAP's /dev handling is not always
# standard, so fall back to creating the node ourselves from the misc minor.
ensure_dev_node() {
    local name=$1 dev=/dev/$1 minor
    [ -e "$dev" ] && return 0
    minor=$(cat "/sys/class/misc/$name/dev" 2>/dev/null)
    [ -n "$minor" ] || return 1
    mknod "$dev" c "${minor%%:*}" "${minor##*:}" 2>/dev/null || return 1
    chmod 660 "$dev" 2>/dev/null
    log "created $dev (${minor})"
}

ensure_dev_nodes() {
    local i=0
    while [ $i -lt 10 ]; do
        ensure_dev_node vsock
        ensure_dev_node vhost-vsock
        [ -e /dev/vsock ] && [ -e /dev/vhost-vsock ] && return 0
        i=$((i + 1))
        sleep 1
    done
    warn "/dev/vsock and/or /dev/vhost-vsock are still missing"
    return 1
}

do_load() {
    local name pids
    for name in $MODULE_ORDER; do
        load_module "$name" || return 1
    done
    ensure_dev_nodes || true

    # Remember which LXD daemon was already running: if it is still the same one
    # later, its cached "no vsock" answer is stale and it needs a restart.
    pids=$(lxd_daemon_pids)
    printf '%s\n' "$pids" > "$STATE_DIR/lxd-pids-at-load" 2>/dev/null

    log "vsock stack loaded for kernel $(kver)"
}

do_unload() {
    local name
    for name in vhost_vsock vmw_vsock_virtio_transport_common vsock; do
        if is_loaded "$name"; then
            rmmod "$name" && log "unloaded $name" || warn "could not unload $name"
        fi
    done
}

container_station_dir() {
    local dir
    dir=$(getcfg container-station Install_Path -f /etc/config/qpkg.conf 2>/dev/null)
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        printf '%s' "$dir"
        return 0
    fi
    for dir in /share/*/.qpkg/container-station; do
        [ -d "$dir" ] && { printf '%s' "$dir"; return 0; }
    done
    return 1
}

# Both of these stay in the package directory and are linked into /usr/local/bin,
# the only directory on the LXD daemon's PATH that is neither Container Station's
# own nor a system directory.
do_shim() {
    do_qemu_shim || true
    do_tools_shim || true
}

# LXD finds QEMU through PATH, and only Container Station ships one: the
# kata-static build under its own prefix. Symlink it into a directory the daemon
# already searches, without touching Container Station's files.
do_qemu_shim() {
    local cs qemu existing

    # If the payload ships its own emulator, that one wins: it is built with
    # seccomp, which LXD requires (-sandbox), and the wrapper alongside it
    # handles the arguments LXD passes that this QEMU cannot take. do_tools_shim
    # links it.
    if [ -x "$PREFIX/bin/$QEMU_BIN" ]; then
        log "$QEMU_BIN comes from this package: $PREFIX/bin/$QEMU_BIN"
        return 0
    fi

    existing=$(command -v "$QEMU_BIN" 2>/dev/null)
    if [ -n "$existing" ] && [ "$existing" != "$BIN_DIR/$QEMU_BIN" ]; then
        log "$QEMU_BIN already on PATH: $existing"
        return 0
    fi

    cs=$(container_station_dir) || { warn "Container Station not found, skipping qemu shim"; return 1; }

    qemu="$cs/opt/kata/bin/$QEMU_BIN"
    if [ ! -x "$qemu" ]; then
        qemu=$(find "$cs" -name "$QEMU_BIN" -type f 2>/dev/null | head -n1)
    fi
    [ -n "$qemu" ] && [ -x "$qemu" ] || { warn "no $QEMU_BIN under $cs"; return 1; }

    if [ -L "$BIN_DIR/$QEMU_BIN" ] && [ "$(readlink "$BIN_DIR/$QEMU_BIN")" = "$qemu" ]; then
        log "qemu shim already in place"
        return 0
    fi

    ln -sf "$qemu" "$BIN_DIR/$QEMU_BIN" || { warn "could not create $BIN_DIR/$QEMU_BIN"; return 1; }
    log "qemu shim: $BIN_DIR/$QEMU_BIN -> $qemu"
}

# Everything the package ships in bin/ (qemu-img, prlimit, ...) is linked into
# LXD's PATH, unless the NAS already provides one of its own. LXD runs them from
# PATH: qemu-img for every image operation, and prlimit to bound its CPU and
# memory use.
do_tools_shim() {
    local tool name existing linked=0

    for tool in "$PREFIX"/bin/*; do
        [ -f "$tool" ] || continue
        name=$(basename "$tool")

        existing=$(command -v "$name" 2>/dev/null)
        if [ -n "$existing" ] && [ "$existing" != "$BIN_DIR/$name" ]; then
            log "$name already on PATH: $existing"
            continue
        fi

        chmod 755 "$tool" 2>/dev/null
        if [ -L "$BIN_DIR/$name" ] && [ "$(readlink "$BIN_DIR/$name")" = "$tool" ]; then
            linked=$((linked + 1))
            continue
        fi

        if ln -sf "$tool" "$BIN_DIR/$name"; then
            log "$name shim: $BIN_DIR/$name -> $tool"
            linked=$((linked + 1))
        else
            warn "could not create $BIN_DIR/$name"
        fi
    done

    if [ "$linked" = 0 ]; then
        warn "no tools in $PREFIX/bin to link"
        return 1
    fi
}

do_firmware() {
    local src target
    [ -d "$FIRMWARE_DIR" ] || { warn "no firmware directory: $FIRMWARE_DIR"; return 1; }
    mkdir -p "$OVMF_DIR" || { warn "cannot create $OVMF_DIR"; return 1; }

    # Link rather than copy: the data stays with the package, and /usr/share
    # (on the flash DOM) only receives links. LXD copes with that: setupNvram()
    # calls EvalSymlinks on OVMF_VARS.fd before seeding a VM's NVRAM.
    for src in "$FIRMWARE_DIR"/*.fd; do
        [ -f "$src" ] || continue
        target="$OVMF_DIR/$(basename "$src")"
        if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
            continue
        fi
        ln -sfn "$src" "$target" || { warn "could not link $target"; continue; }
        log "linked $(basename "$src") -> $src"
    done

    if [ ! -e "$OVMF_DIR/OVMF_CODE.fd" ]; then
        warn "OVMF_CODE.fd is missing from $OVMF_DIR"
        return 1
    fi
}

# LXD forks short-lived helpers that are also called "lxd" (forknet, forkfile,
# callhook, ...), so only consider the actual daemon.
lxd_daemon_pids() {
    local p cmd out=
    for p in $(pidof lxd 2>/dev/null); do
        cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        case "$cmd" in
            *fork*|*callhook*) continue ;;
        esac
        out="$out $p"
    done
    printf '%s' "${out# }"
}

# LXD asks whether vsock is supported once, when its daemon starts, and keeps
# the answer. A daemon that started before the modules were loaded therefore
# reports "Vsock support is missing (no /dev/vsock)" until it is restarted, and
# restarting it is the operator's call - this only says so.
advise_lxd_restart() {
    lxd_predates_modules || return 0
    warn "the running LXD daemon started before the modules were loaded, so it still reports"
    warn "\"Vsock support is missing (no /dev/vsock)\" even though the device is there"
    warn "restart Container Station to fix it (or reboot):"
    warn "  qpkg_cli --stop container-station && qpkg_cli --start container-station"
}

# Process start as "seconds since boot" (field 22 of /proc/<pid>/stat, in clock
# ticks). This is the raw kernel fact; /proc/<pid>'s mtime is NOT usable for it,
# because procfs creates that inode on first lookup, so a process running for
# hours can report an mtime of "just now".
read_start_ticks() {
    # comm may contain spaces but not ')', so drop "pid (comm) " and count from
    # the state field: starttime is then field 20.
    sed 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20
}

process_start_after_boot() {
    local ticks hz
    ticks=$(read_start_ticks "$1")
    [ -n "$ticks" ] || return 1
    hz=${QNAP_VSOCK_CLK_TCK:-$(getconf CLK_TCK 2>/dev/null || echo 100)}
    awk -v ticks="$ticks" -v hz="$hz" 'BEGIN { printf "%d", ticks / hz }'
}

# Whether the running daemon is one we found already running when the modules
# were loaded. Comparing pids avoids any clock arithmetic: /proc/uptime and the
# starttime ticks are not in the same domain inside a container with a time
# namespace, so "daemon started before we loaded" cannot be computed reliably
# from them.
lxd_predates_modules() {
    local p pids recorded
    pids=$(lxd_daemon_pids)
    [ -n "$pids" ] || return 1
    if [ ! -f "$STATE_DIR/lxd-pids-at-load" ]; then
        # Something loaded the modules without going through us (insmod by
        # hand, for instance), so we cannot know: assume the worst.
        return 0
    fi
    recorded=$(cat "$STATE_DIR/lxd-pids-at-load")
    [ -n "$recorded" ] || return 1
    for p in $pids; do
        case " $recorded " in
            *" $p "*) return 0 ;;
        esac
    done
    return 1
}

# Everything LXD may exec for a VM, and what it is for. Anything MISSING is worth
# fixing before trying again; the optional entries only matter for the feature
# named. LXD resolves all of them through PATH when it needs them, so a tool that
# appears later needs no restart.
check_lxd_tools() {
    local entry name note seen state

    for entry in \
        "$QEMU_BIN|the VM itself (needs seccomp)|required (this package)" \
        "qemu-img|image info, convert, create, amend|required (this package)" \
        "prlimit|bounds qemu-img's CPU and memory|required (this package)" \
        "nice|image conversion at low priority|required (this package)" \
        "modprobe|loading kernel modules|required" \
        "ip|interfaces and routes|required" \
        "apparmor_parser|LXD's qemu-img profile|required when AppArmor is enabled" \
        "nft|nftables firewall|one of nft, iptables, ebtables" \
        "iptables|xtables firewall|one of nft, iptables, ebtables" \
        "ebtables|bridged filtering|one of nft, iptables, ebtables" \
        "dnsmasq|LXD-managed networks|only if LXD manages the bridge" \
        "virtiofsd|config drive over virtio-fs|optional: LXD falls back to 9p" \
        "swtpm|tpm devices|optional" \
        "mkisofs|cloud-init config drive|optional" \
        "xz|.xz images|optional" \
        "zstd|.zst images|optional" \
        "gzip|.gz images|optional" \
        "bzip2|.bz2 images|optional" \
        "lzma|.lzma images|optional" \
    ; do
        name=${entry%%|*}
        note=${entry#*|}
        note=${note#*|}

        seen=$(command -v "$name" 2>/dev/null)
        if [ -n "$seen" ]; then
            state=present
        else
            state=MISSING
        fi

        printf '  %-22s %-8s %s\n' "$name" "$state" "$note"
    done
}

# One shot summary of everything LXD looks at, plus whether the running daemon
# is simply holding on to a stale answer.
do_preflight() {
    local pids p ns init_ns sees name recorded since qemu_path

    printf 'kernel release: %s\n' "$(kver)"
    printf 'modules directory: %s%s\n' "$MODULES_DIR" "$([ -d "$MODULES_DIR" ] || echo ' (MISSING)')"

    printf 'what LXD checks, in order:\n'
    printf '  %-24s %s\n' /dev/kvm "$([ -e /dev/kvm ] && echo present || echo MISSING)"
    printf '  %-24s %s\n' /dev/vsock "$([ -e /dev/vsock ] && echo present || echo MISSING)"
    for name in $MODULE_ORDER; do
        printf '  %-24s %s\n' "$name module" "$(is_loaded "$name" && echo loaded || echo 'not loaded')"
    done
    qemu_path=$(command -v "$QEMU_BIN" 2>/dev/null)
    if [ -L "$qemu_path" ]; then
        qemu_path="$qemu_path -> $(readlink "$qemu_path")"
    fi
    printf '  %-24s %s\n' "$QEMU_BIN" "${qemu_path:-MISSING}"

    for tool in "$PREFIX"/bin/*; do
        [ -f "$tool" ] || continue
        [ "$(basename "$tool")" = "$QEMU_BIN" ] && continue
        printf '  %-24s %s\n' "$(basename "$tool")" \
            "$(command -v "$(basename "$tool")" 2>/dev/null || echo MISSING)"
    done
    printf '  %-24s %s\n' OVMF_CODE.fd "$([ -f "$OVMF_DIR/OVMF_CODE.fd" ] && echo present || echo MISSING)"
    printf '  %-24s %s\n' OVMF_VARS.fd "$([ -f "$OVMF_DIR/OVMF_VARS.fd" ] && echo present || echo MISSING)"

    printf 'tools LXD may run:\n'
    check_lxd_tools

    init_ns=$(readlink /proc/1/ns/mnt 2>/dev/null)
    pids=$(lxd_daemon_pids)
    if [ -z "$pids" ]; then
        printf 'running LXD: none\n'
        printf 'verdict: nothing to refresh, the next daemon start will see the modules\n'
        return 0
    fi

    recorded=$(cat "$STATE_DIR/lxd-pids-at-load" 2>/dev/null)
    printf 'running LXD:\n'
    for p in $pids; do
        ns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null)
        if [ "$ns" = "$init_ns" ]; then
            ns="shared with init"
        else
            ns="PRIVATE ($ns)"
        fi
        sees=$([ -e "/proc/$p/root/dev/vsock" ] && echo yes || echo no)
        since=$(process_start_after_boot "$p")
        printf '  pid %s: started %ss after boot, mount namespace %s, sees /dev/vsock: %s\n' \
            "$p" "${since:-?}" "$ns" "$sees"
        if [ -n "$recorded" ]; then
            case " $recorded " in
                *" $p "*) printf '         this daemon was already running when the modules were loaded\n' ;;
            esac
        fi
    done

    if [ ! -f "$STATE_DIR/lxd-pids-at-load" ]; then
        printf 'verdict: the modules were not loaded by this helper, so whether this\n'
        printf '         daemon is stale is unknown. If it was running before, it still\n'
        printf '         reports "Vsock support is missing (no /dev/vsock)"; restart\n'
        printf '         Container Station (or reboot):\n'
    elif lxd_predates_modules; then
        printf 'verdict: the running LXD predates the modules, so it still reports\n'
        printf '         "Vsock support is missing (no /dev/vsock)" even though the\n'
        printf '         device is there. Restart Container Station (or reboot):\n'
        printf '           qpkg_cli --stop container-station && qpkg_cli --start container-station\n'
    else
        printf 'verdict: LXD started after the modules, its cached answer is current\n'
    fi
}

do_status() {
    local name ko
    printf 'kernel release: %s\n' "$(kver)"
    printf 'modules directory: %s%s\n' "$MODULES_DIR" "$([ -d "$MODULES_DIR" ] || echo ' (MISSING)')"
    for name in $MODULE_ORDER; do
        ko=$(module_path "$name")
        printf '  %-36s %s\n' "$name" \
            "$(is_loaded "$name" && echo loaded || echo "not loaded")$([ -f "$ko" ] || echo ' [file missing]')"
    done
    printf '  %-36s %s\n' /dev/vsock "$([ -e /dev/vsock ] && echo present || echo MISSING)"
    printf '  %-36s %s\n' /dev/vhost-vsock "$([ -e /dev/vhost-vsock ] && echo present || echo MISSING)"
    printf '  %-36s %s\n' "$QEMU_BIN" "$(command -v "$QEMU_BIN" 2>/dev/null || echo MISSING)"
    for tool in "$PREFIX"/bin/*; do
        [ -f "$tool" ] || continue
        printf '  %-36s %s\n' "$(basename "$tool")" \
            "$(command -v "$(basename "$tool")" 2>/dev/null || echo MISSING)"
    done
    printf '  %-36s %s\n' OVMF_CODE.fd "$([ -f "$OVMF_DIR/OVMF_CODE.fd" ] && echo present || echo MISSING)"
    printf '  %-36s %s\n' OVMF_VARS.fd "$([ -f "$OVMF_DIR/OVMF_VARS.fd" ] && echo present || echo MISSING)"
    if [ -n "${MODINFO:-}" ]; then :; fi
    case "$(pidof lxd 2>/dev/null)" in
        "") printf '  %-36s %s\n' lxd "not running" ;;
        *)  printf '  %-36s %s\n' lxd "running (pid $(pidof lxd))" ;;
    esac
}

do_install() {
    do_shim || true
    do_firmware || true
    do_load || return 1
    advise_lxd_restart
}

do_uninstall() {
    local src target
    do_unload

    rm -f "$BIN_DIR/$QEMU_BIN" 2>/dev/null
    local tool name
    for tool in "$PREFIX"/bin/*; do
        [ -f "$tool" ] || continue
        name=$(basename "$tool")
        if [ -L "$BIN_DIR/$name" ] && [ "$(readlink "$BIN_DIR/$name")" = "$tool" ]; then
            rm -f "$BIN_DIR/$name"
        fi
    done

    # Only remove firmware links that point at this payload.
    for src in "$FIRMWARE_DIR"/*.fd; do
        [ -f "$src" ] || continue
        target="$OVMF_DIR/$(basename "$src")"
        if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
            rm -f "$target" && log "removed $target"
        fi
    done

    rm -f "$STATE_DIR/lxd-pids-at-load" 2>/dev/null
    log "uninstalled"
}

case "${1:-status}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    load) do_load ;;
    unload) do_unload ;;
    status) do_status ;;
    preflight) do_preflight ;;
    shim) do_shim ;;
    firmware) do_firmware ;;
    check-file)
        # Debugging aid: is this module usable on the running kernel?
        [ -n "${2:-}" ] || die "check-file needs a module path"
        check_vermagic "$2"
        log "$(basename "$2") is usable on kernel $(kver)"
        ;;
    process-start)
        # Debugging aid: seconds after boot when the pid started.
        [ -n "${2:-}" ] || die "process-start needs a pid"
        process_start_after_boot "$2"
        printf '\n'
        ;;
    *) die "unknown action: $1 (install|uninstall|load|unload|status|preflight|shim|firmware|check-file|process-start)" ;;
esac
