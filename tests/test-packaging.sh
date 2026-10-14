#!/usr/bin/env bash
#
# Tests that can run here, without a QNAP NAS: script syntax, the built
# modules and their vermagic, the payload layouts of both packages, and the
# guard that stops modules built for another kernel from being loaded.
#
# Usage: tests/test-packaging.sh
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

check() { # check <description> <command...>
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else no "$desc"; fi
}

# ---------------------------------------------------------------- syntax ----

check_syntax() {
    local f
    for f in "$REPO_DIR"/build.sh "$REPO_DIR"/scripts/*.sh \
             "$REPO_DIR"/scripts/in-container/*.sh; do
        [ -f "$f" ] || continue
        check "syntax: ${f#"$REPO_DIR"/}" bash -n "$f"
    done
    # The NAS side must stay POSIX sh: QNAP's /bin/sh is not bash.
    for f in "$REPO_DIR"/nas/install.sh "$REPO_DIR"/nas/uninstall.sh \
             "$REPO_DIR"/nas/autorun/autorun.sh "$REPO_DIR"/nas/shared/qnap-vsock.sh \
             "$REPO_DIR"/qpkg/package_routines "$REPO_DIR"/qpkg/shared/qnap-vsock-service.sh; do
        [ -f "$f" ] || continue
        check "syntax: ${f#"$REPO_DIR"/} (sh)" sh -n "$f"
    done
}

# --------------------------------------------------------------- modules ----

modules_dir() {
    local d
    for d in "$REPO_DIR"/modules/*/; do
        [ -d "$d" ] && { printf '%s' "${d%/}"; return 0; }
    done
    return 1
}

check_modules() {
    local dir release expected ko got
    dir=$(modules_dir) || { no "modules built"; return; }
    release=$(basename "$dir")
    expected=$(printf '%s' "$release")
    expected="$expected SMP mod_unload"

    for ko in "$dir"/vsock.ko "$dir"/vmw_vsock_virtio_transport_common.ko \
              "$dir"/vhost_vsock.ko; do
        check "module exists: $(basename "$ko")" test -s "$ko"
    done

    if ! command -v modinfo >/dev/null 2>&1; then
        printf 'skip vermagic checks (no modinfo)\n'
        return
    fi

    for ko in "$dir"/*.ko; do
        got=$(modinfo -F vermagic "$ko" | sed 's/[[:space:]]*$//')
        if [ "$got" = "$expected" ]; then
            ok "vermagic: $(basename "$ko") = $got"
        else
            no "vermagic: $(basename "$ko") = '$got' (want '$expected')"
        fi
    done
}

# --------------------------------------------------------------- payloads ---

# The QPKG is a shell stub followed by a control tar and data.tar.gz; check the
# data archive really has the files at the paths the installer uses.
check_qpkg() {
    local qpkg
    qpkg=$(ls "$REPO_DIR"/out/*.qpkg 2>/dev/null)
    qpkg=${qpkg%%$'\n'*}
    [ -n "$qpkg" ] || { no "QPKG built"; return; }
    ok "QPKG built: $(basename "$qpkg")"

    # It is a self-extracting shell installer, and QNAP ships those executable.
    [ -x "$qpkg" ] && ok "QPKG is executable" || no "QPKG is executable"
    case "$(head -c 2 "$qpkg")" in
        '#!') ok "QPKG is a self-extracting script" ;;
        *) no "QPKG is a self-extracting script" ;;
    esac

    python3 - "$qpkg" <<'PY'
import gzip, io, re, sys, tarfile
path = sys.argv[1]
data = open(path, 'rb').read()
m = re.search(rb'script_len=(\d+)', data)
script_len = int(m.group(1))
start = script_len + 20480
m = re.search(rb'count=(\d+) of=', data)
size = int(m.group(1)) * 1024
m = re.search(rb'f\.seek\((\d+)\)', data)
if m:
    size = min(size, int(m.group(1)))
tar = tarfile.open(fileobj=io.BytesIO(gzip.decompress(data[start:start+size])), mode='r:')
names = set(n.lstrip('./') for n in tar.getnames())
required = {'qnap-vsock-service.sh', 'qnap-vsock.sh', 'modules', 'firmware',
            'bin/qemu-img', 'bin/prlimit', 'bin/qemu-system-x86_64',
            'bin/virtfs-proxy-helper',
            'libexec/qemu-system-x86_64', 'share/qemu'}
missing = required - names
if missing:
    print(f"FAIL qpkg data archive missing {sorted(missing)}")
    sys.exit(1)
for n in names:
    if n.endswith('.ko'):
        print(f"ok   qpkg contains {n}")
    if n.endswith('OVMF_CODE.fd'):
        print(f"ok   qpkg contains {n}")
sys.exit(0)
PY
    if [ $? = 0 ]; then ok "QPKG payload layout"; else no "QPKG payload layout"; fi
}

check_tarball() {
    local tb
    tb=$(ls "$REPO_DIR"/out/qnap-vsock-*.tar.gz 2>/dev/null)
    tb=${tb%%$'\n'*}
    [ -n "$tb" ] || { no "tarball built"; return; }
    ok "tarball built: $(basename "$tb")"

    local list
    list=$(tar -tzf "$tb")
    case "$list" in
        *"qnap-vsock/install.sh"*) ok "tarball has install.sh" ;;
        *) no "tarball has install.sh" ;;
    esac
    case "$list" in
        *"qnap-vsock/shared/qnap-vsock.sh"*) ok "tarball has the helper" ;;
        *) no "tarball has the helper" ;;
    esac
    case "$list" in
        *"qnap-vsock/modules/"*) ok "tarball has modules" ;;
        *) no "tarball has modules" ;;
    esac
    case "$list" in
        *"qnap-vsock/bin/qemu-img"*) ok "tarball has qemu-img" ;;
        *) no "tarball has qemu-img" ;;
    esac
    case "$list" in
        *"qnap-vsock/bin/prlimit"*) ok "tarball has prlimit" ;;
        *) no "tarball has prlimit" ;;
    esac
    case "$list" in
        *"qnap-vsock/libexec/qemu-system-x86_64"*) ok "tarball has the emulator" ;;
        *) no "tarball has the emulator" ;;
    esac
    case "$list" in
        *"qnap-vsock/bin/virtfs-proxy-helper"*) ok "tarball has virtfs-proxy-helper" ;;
        *) no "tarball has virtfs-proxy-helper" ;;
    esac
    case "$list" in
        *"qnap-vsock/share/qemu/vgabios"*) ok "tarball has the option ROMs" ;;
        *) no "tarball has the option ROMs" ;;
    esac
    case "$list" in
        *"qnap-vsock/firmware/OVMF_CODE.fd"*) ok "tarball has firmware" ;;
        *) no "tarball has firmware" ;;
    esac
}

# ---------------------------------------------------------------- helper ----

# The helper has to find the payload whether or not qbuild flattened shared/.
check_helper_prefix() {
    local layout dir script out
    for layout in tarball flattened; do
        dir="$TMP/$layout"
        mkdir -p "$dir/shared"
        cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$dir/shared/qnap-vsock.sh"
        mkdir -p "$dir/modules/$(uname -r)"
        : > "$dir/modules/$(uname -r)/vsock.ko"
        if [ "$layout" = flattened ]; then
            # simulate the installed QPKG: helper at the root
            mv "$dir/shared/qnap-vsock.sh" "$dir/qnap-vsock.sh"
            rmdir "$dir/shared"
            script="$dir/qnap-vsock.sh"
        else
            script="$dir/shared/qnap-vsock.sh"
        fi
        # Capture first: piping into grep -q would kill the helper with SIGPIPE
        # and, with pipefail, fail the pipeline even on a match.
        out=$(sh "$script" status 2>/dev/null)
        case "$out" in
            *"modules directory: $dir/modules"*) ok "helper finds payload ($layout layout)" ;;
            *) no "helper finds payload ($layout layout)" ;;
        esac
    done
}

# A module built for another kernel must be refused before insmod.
check_helper_rejects_foreign_module() {
    local dir ko out
    dir="$TMP/foreign"
    mkdir -p "$dir/shared"
    cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$dir/shared/qnap-vsock.sh"

    ko=$(modules_dir)/vsock.ko
    if [ ! -f "$ko" ]; then
        printf 'skip foreign module check (no modules built)\n'
        return
    fi

    out=$(QNAP_VSOCK_STATE="$TMP/state" \
          sh "$dir/shared/qnap-vsock.sh" check-file "$ko" 2>&1)
    if [ $? != 0 ] && printf '%s' "$out" | grep -qiE 'vermagic|not for'; then
        ok "helper refuses a module built for another kernel"
    else
        no "helper refuses a module built for another kernel"
    fi
}

# The preflight summary has to run anywhere and name what LXD checks.
check_helper_preflight() {
    local dir out rc
    dir="$TMP/preflight"
    mkdir -p "$dir/shared" "$dir/modules/$(uname -r)"
    cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$dir/shared/qnap-vsock.sh"

    out=$(QNAP_VSOCK_STATE="$TMP/state" sh "$dir/shared/qnap-vsock.sh" preflight 2>&1)
    rc=$?
    [ "$rc" = 0 ] && ok "preflight exits 0" || no "preflight exits 0"
    case "$out" in
        *"/dev/vsock"*) ok "preflight reports the /dev/vsock check" ;;
        *) no "preflight reports the /dev/vsock check" ;;
    esac
    case "$out" in
        *"OVMF_CODE.fd"*) ok "preflight reports the firmware check" ;;
        *) no "preflight reports the firmware check" ;;
    esac
    case "$out" in
        *"verdict:"*) ok "preflight prints a verdict" ;;
        *) no "preflight prints a verdict" ;;
    esac
}

# A daemon that is older than the modules must be recognised as stale. This
# cannot use clock arithmetic (procfs mtimes lie, and /proc/uptime is not in the
# same domain as the starttime ticks in a container), so it is pid based; here
# we only check the underlying start-time helper orders two known processes.
check_process_start_order() {
    local one two
    one=$(QNAP_VSOCK_STATE="$TMP/state" sh "$REPO_DIR/nas/shared/qnap-vsock.sh" process-start 1 2>/dev/null)
    two=$(QNAP_VSOCK_STATE="$TMP/state" sh "$REPO_DIR/nas/shared/qnap-vsock.sh" process-start $$ 2>/dev/null)
    if [ -n "$one" ] && [ -n "$two" ] && [ "$one" -lt "$two" ]; then
        ok "process-start orders pid 1 before this shell"
    else
        no "process-start orders pid 1 before this shell (got '$one' and '$two')"
    fi
}

# The built qemu-img must be static (it runs on QTS, not here) and must handle
# what LXD actually calls: create with a data file, info as JSON, convert.
check_qemu_img_binary() {
    local img="$REPO_DIR/build/bin/qemu-img" work out

    if [ ! -x "$img" ]; then
        printf 'skip qemu-img binary checks (not built)\n'
        return
    fi

    if file "$img" | grep -q 'static'; then
        ok "qemu-img is statically linked"
    else
        no "qemu-img is statically linked ($(file -b "$img"))"
    fi

    work="$TMP/qcow2"
    mkdir -p "$work"

    if "$img" create -f qcow2 -o preallocation=metadata "$work/t.img" 64M >/dev/null 2>&1; then
        ok "qemu-img create -f qcow2"
    else
        no "qemu-img create -f qcow2"
    fi

    out=$("$img" info "$work/t.img" --output json 2>/dev/null)
    case "$out" in
        *'"format": "qcow2"'*) ok "qemu-img info --output json" ;;
        *) no "qemu-img info --output json" ;;
    esac

    if "$img" convert -f qcow2 -O raw -t writeback "$work/t.img" "$work/t.raw" >/dev/null 2>&1; then
        ok "qemu-img convert to raw"
    else
        no "qemu-img convert to raw"
    fi

    if "$img" create -f qcow2 -o "data_file=$work/t.img" "$work/overlay.img" 64M >/dev/null 2>&1; then
        ok "qemu-img create with a data file"
    else
        no "qemu-img create with a data file"
    fi
}

# The install routines must not fail an install because they cannot locate the
# helper: during an install, Install_Path is not in qpkg.conf yet, so the paths
# derived from it are empty, and the routines run from the directory the files
# were extracted to. Failing there made App Center report "qnap-vsock helper is
# missing from the package" and abort the install.
check_qpkg_install_routines() {
    local routines="$REPO_DIR/qpkg/package_routines" work
    work="$TMP/qpkg-routines"
    rm -rf "$work"
    mkdir -p "$work"

    if [ ! -f "$routines" ]; then
        no "qpkg install routines present"
        return
    fi
    ok "qpkg install routines present"

    # As during an install: the helper sits next to the extracted files.
    : > "$work/qnap-vsock.sh"
    chmod 755 "$work/qnap-vsock.sh"
    if (cd "$work" && QPKG_ROOT=/nonexistent sh -c '
            . "$1"
            [ "$(vsock_helper)" = "./qnap-vsock.sh" ] || exit 2
            pkg_install
        ' sh "$routines") >/dev/null 2>&1; then
        ok "install routine finds the helper beside the extracted files"
    else
        no "install routine finds the helper beside the extracted files"
    fi

    # And it must stay successful when nothing can be found at all.
    rm -f "$work/qnap-vsock.sh"
    if (cd "$work" && QPKG_ROOT=/nonexistent sh -c '. "$1"; pkg_install' sh "$routines") >/dev/null 2>&1; then
        ok "install routine succeeds even without a helper"
    else
        no "install routine succeeds even without a helper"
    fi
}

# LXD starts this one for a VM's 9p shares (a disk device pointing at a host
# path), and looks it up by name on PATH, so it has to be static too.
check_virtfs_proxy_helper() {
    local helper="$REPO_DIR/build/bin/virtfs-proxy-helper" out

    if [ ! -x "$helper" ]; then
        printf 'skip virtfs-proxy-helper checks (not built)\n'
        return
    fi

    if file "$helper" | grep -q 'static'; then
        ok "virtfs-proxy-helper is statically linked"
    else
        no "virtfs-proxy-helper is statically linked ($(file -b "$helper"))"
    fi

    # With no arguments it prints its usage and exits non-zero, which is all we
    # can check without a guest: LXD passes -s/-p/-u/-g itself.
    out=$("$helper" 2>&1 || true)
    case "$out" in
        *sage*) ok "virtfs-proxy-helper runs and reports its usage" ;;
        *) no "virtfs-proxy-helper runs and reports its usage" ;;
    esac
}

# LXD wraps qemu-img in prlimit, so both have to work together exactly as
# lxd/storage/utils.go calls them.
check_prlimit_binary() {
    local prlimit="$REPO_DIR/build/bin/prlimit" qemu="$REPO_DIR/build/bin/qemu-img"
    local work out

    if [ ! -x "$prlimit" ]; then
        printf 'skip prlimit checks (not built)\n'
        return
    fi

    if file "$prlimit" | grep -q 'static'; then
        ok "prlimit is statically linked"
    else
        no "prlimit is statically linked ($(file -b "$prlimit"))"
    fi

    work="$TMP/prlimit"
    mkdir -p "$work"
    "$qemu" create -f qcow2 "$work/t.img" 8M >/dev/null 2>&1

    out=$("$prlimit" --cpu=2 --as=1000000000 "$qemu" info -f qcow2 --output=json "$work/t.img" 2>/dev/null)
    case "$out" in
        *'"format": "qcow2"'*) ok "prlimit runs qemu-img the way LXD does" ;;
        *) no "prlimit runs qemu-img the way LXD does" ;;
    esac

    # and the limits have to reach the child, not just be accepted
    out=$("$prlimit" --nofile=64 sh -c 'ulimit -n' 2>/dev/null)
    if [ "$out" = "64" ]; then
        ok "prlimit applies the limits it is given"
    else
        no "prlimit applies the limits it is given (got '$out')"
    fi
}

# The wrapper LXD finds as qemu-system-x86_64 has to drop exactly the arguments
# a spice-less QEMU cannot take, filter the spice sections out of -readconfig,
# and leave every other argument untouched (LXD's -smbios value contains spaces).
check_qemu_wrapper() {
    local dir stub conf argv

    dir="$TMP/wrap/prefix"
    stub="$dir/libexec"
    conf="$TMP/wrap/qemu.conf"
    argv="$TMP/wrap/argv"
    mkdir -p "$dir/bin" "$stub" "$dir/share/qemu"
    : > "$dir/share/qemu/vgabios-virtio.bin"

    cp "$REPO_DIR/nas/shared/qemu-wrapper.sh" "$dir/bin/qemu-system-x86_64"
    chmod 755 "$dir/bin/qemu-system-x86_64"

    cat > "$stub/qemu-system-x86_64" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "${QEMU_ARGV_LOG:?}"
STUB
    chmod 755 "$stub/qemu-system-x86_64"

    cat > "$conf" <<'CONF'
[device "dev-qemu_serial"]
  driver = "virtio-serial-pci"

[chardev "qemu_spice-chardev"]
  backend = "spicevmc"
  name = "vdagent"

[device "qemu_spice"]
  driver = "virtserialport"
  chardev = "qemu_spice-chardev"

[device "qemu_scsi"]
  driver = "virtio-scsi-pci"
CONF

    QEMU_ARGV_LOG="$argv" "$dir/bin/qemu-system-x86_64" \
        -S -name haos \
        -smbios "type=2,manufacturer=Canonical Ltd.,product=LXD: qemu-system-x86_64" \
        -cpu host,hv_passthrough \
        -spice "unix=on,disable-ticketing=on,addr=/tmp/x.spice" \
        -readconfig "$conf" \
        -machine q35 2>/dev/null

    if [ ! -f "$argv" ]; then
        no "the qemu wrapper runs the emulator"
        return
    fi
    ok "the qemu wrapper runs the emulator"

    if grep -q '^-spice$\|^unix=on' "$argv"; then
        no "the qemu wrapper drops the spice argument"
    else
        ok "the qemu wrapper drops the spice argument"
    fi

    if grep -Fxq "type=2,manufacturer=Canonical Ltd.,product=LXD: qemu-system-x86_64" "$argv"; then
        ok "the qemu wrapper keeps arguments with spaces intact"
    else
        no "the qemu wrapper keeps arguments with spaces intact"
    fi

    # LXD's hv_passthrough cannot work on this kernel (KVM offers only eVMCS v0),
    # so it is dropped - but nothing else LXD asks for is.
    if grep -Fxq "host" "$argv" && ! grep -q 'hv.passthrough' "$argv"; then
        ok "the qemu wrapper drops hv_passthrough"
    else
        no "the qemu wrapper drops hv_passthrough"
    fi

    if [ -f "$conf.no-spice" ] &&
       ! grep -q 'qemu_spice\|spicevmc\|spiceport' "$conf.no-spice" &&
       grep -q 'qemu_scsi' "$conf.no-spice"; then
        ok "the qemu wrapper filters spice out of -readconfig"
    else
        no "the qemu wrapper filters spice out of -readconfig"
    fi

    if grep -Fxq "$conf.no-spice" "$argv"; then
        ok "the qemu wrapper points -readconfig at the filtered file"
    else
        no "the qemu wrapper points -readconfig at the filtered file"
    fi

    # the ROMs have to be reachable: -L <datadir>
    if grep -Fxq -- "-L" "$argv" && grep -Fxq "$dir/share/qemu" "$argv"; then
        ok "the qemu wrapper points QEMU at the shipped ROMs"
    else
        no "the qemu wrapper points QEMU at the shipped ROMs"
    fi

    # The helper links it into /usr/local/bin, so the wrapper always runs through
    # a symlink: it has to resolve its own path to find libexec/ and share/qemu.
    rm -f "$argv"
    ln -sf "$dir/bin/qemu-system-x86_64" "$TMP/wrap/qemu-system-x86_64"
    QEMU_ARGV_LOG="$argv" "$TMP/wrap/qemu-system-x86_64" -S -name haos 2>/dev/null
    if [ -f "$argv" ] && grep -Fxq "$dir/share/qemu" "$argv"; then
        ok "the qemu wrapper works when invoked through a symlink"
    else
        no "the qemu wrapper works when invoked through a symlink"
    fi
    # other CPU extensions have to survive
    rm -f "$argv"
    QEMU_ARGV_LOG="$argv" "$dir/bin/qemu-system-x86_64" \
        -cpu host,topoext,hv_passthrough -S -name haos 2>/dev/null
    if grep -Fxq "host,topoext" "$argv"; then
        ok "the qemu wrapper keeps the other CPU extensions"
    else
        no "the qemu wrapper keeps the other CPU extensions (got '$(sed -n 2p "$argv")')"
    fi

    # and the opt-in marker can keep it
    rm -f "$argv"
    : > "$dir/enable-hv-passthrough"
    QEMU_ARGV_LOG="$argv" "$dir/bin/qemu-system-x86_64" \
        -cpu host,hv_passthrough -S -name haos 2>/dev/null
    rm -f "$dir/enable-hv-passthrough"
    if grep -Fxq "host,hv-passthrough" "$argv"; then
        ok "the opt-in marker keeps hv_passthrough (renamed)"
    else
        no "the opt-in marker keeps hv_passthrough (renamed)"
    fi

    # LXD never enables QEMU's log items, so -D leaves an empty file; an opt-in
    # marker asks for some.
    rm -f "$argv"
    : > "$dir/enable-qemu-log"
    QEMU_ARGV_LOG="$argv" "$dir/bin/qemu-system-x86_64" -S -name haos 2>/dev/null
    rm -f "$dir/enable-qemu-log"
    if grep -Fxq -- "-d" "$argv" && grep -Fxq "guest_errors,unimp" "$argv"; then
        ok "the opt-in marker turns on QEMU logging"
    else
        no "the opt-in marker turns on QEMU logging"
    fi
}

# nice: LXD runs image conversion as "nice -n19 qemu-img convert ...".
check_nice_binary() {
    local nice="$REPO_DIR/build/bin/nice" out

    if [ ! -x "$nice" ]; then
        printf 'skip nice checks (not built)\n'
        return
    fi

    if file "$nice" | grep -q 'static'; then
        ok "nice is statically linked"
    else
        no "nice is statically linked ($(file -b "$nice"))"
    fi

    out=$("$nice" -n19 sh -c 'awk "{print \$19}" /proc/self/stat' 2>/dev/null)
    if [ "$out" = "19" ]; then
        ok "nice -n19 (the form LXD uses) sets the niceness"
    else
        no "nice -n19 (the form LXD uses) sets the niceness (got '$out')"
    fi

    out=$("$nice" -n19 "$REPO_DIR/build/bin/qemu-img" --version 2>/dev/null | sed -n 1p)
    case "$out" in
        qemu-img*) ok "nice runs the command it is given" ;;
        *) no "nice runs the command it is given (got '$out')" ;;
    esac
}

# Whatever the payload ships in bin/ has to end up on LXD's PATH.
check_tools_shim() {
    local dir bindir tool
    if command -v qemu-img >/dev/null 2>&1; then
        printf 'skip tools shim (%s is already on this PATH)\n' "$(command -v qemu-img)"
        return
    fi

    dir="$TMP/tools/prefix"; bindir="$TMP/tools/bin"
    mkdir -p "$dir/shared" "$dir/modules/$(uname -r)" "$dir/bin" "$bindir"
    cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$dir/shared/qnap-vsock.sh"
    printf '#!/bin/sh\necho test-tool\n' > "$dir/bin/qemu-img"
    printf '#!/bin/sh\necho test-tool\n' > "$dir/bin/qnap-vsock-fake-tool"
    chmod 755 "$dir/bin/qemu-img" "$dir/bin/qnap-vsock-fake-tool"

    QNAP_VSOCK_STATE="$TMP/tools/state" QNAP_VSOCK_BIN_DIR="$bindir" \
        sh "$dir/shared/qnap-vsock.sh" shim >/dev/null 2>&1

    for tool in qemu-img qnap-vsock-fake-tool; do
        if [ -L "$bindir/$tool" ] && [ "$(readlink "$bindir/$tool")" = "$dir/bin/$tool" ]; then
            ok "$tool is linked into LXD's PATH"
        else
            no "$tool is linked into LXD's PATH"
        fi
    done

    if [ "$("$bindir/qemu-img" 2>/dev/null)" = "test-tool" ]; then
        ok "the linked tools run"
    else
        no "the linked tools run"
    fi

    QNAP_VSOCK_STATE="$TMP/tools/state" QNAP_VSOCK_BIN_DIR="$bindir" \
        sh "$dir/shared/qnap-vsock.sh" uninstall >/dev/null 2>&1
    if [ ! -e "$bindir/qemu-img" ] && [ ! -e "$bindir/qnap-vsock-fake-tool" ]; then
        ok "uninstall removes the tool links"
    else
        no "uninstall removes the tool links"
    fi
}

# The firmware must live in the package and be linked into LXD's path, not
# copied onto the flash DOM, and uninstall must take the links away again.
check_firmware_links() {
    local dir vdir bindir
    dir="$TMP/fw/prefix"; vdir="$TMP/fw/ovmf"; bindir="$TMP/fw/bin"
    mkdir -p "$dir/shared" "$dir/firmware" "$dir/modules/$(uname -r)" "$vdir" "$bindir"
    cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$dir/shared/qnap-vsock.sh"
    : > "$dir/firmware/OVMF_CODE.fd"
    : > "$dir/firmware/OVMF_VARS.fd"

    if ! QNAP_VSOCK_STATE="$TMP/fw/state" LXD_OVMF_PATH="$vdir" \
         QNAP_VSOCK_BIN_DIR="$bindir" \
         sh "$dir/shared/qnap-vsock.sh" firmware >/dev/null 2>&1; then
        no "firmware action runs"
        return
    fi
    ok "firmware action runs"

    if [ -L "$vdir/OVMF_CODE.fd" ] &&
       [ "$(readlink "$vdir/OVMF_CODE.fd")" = "$dir/firmware/OVMF_CODE.fd" ]; then
        ok "firmware is linked, not copied"
    else
        no "firmware is linked, not copied"
    fi

    QNAP_VSOCK_STATE="$TMP/fw/state" LXD_OVMF_PATH="$vdir" \
        QNAP_VSOCK_BIN_DIR="$bindir" \
        sh "$dir/shared/qnap-vsock.sh" uninstall >/dev/null 2>&1
    if [ ! -e "$vdir/OVMF_CODE.fd" ] && [ ! -e "$vdir/OVMF_VARS.fd" ]; then
        ok "uninstall removes the firmware links"
    else
        no "uninstall removes the firmware links"
    fi
}

check_syntax
check_modules
check_qpkg
check_tarball
check_helper_prefix
check_helper_preflight
check_process_start_order
check_helper_rejects_foreign_module
check_qemu_img_binary
check_qpkg_install_routines
check_virtfs_proxy_helper
check_qemu_wrapper
check_prlimit_binary
check_nice_binary
check_tools_shim
check_firmware_links

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
