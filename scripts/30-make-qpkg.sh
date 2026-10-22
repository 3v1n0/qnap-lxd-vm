#!/usr/bin/env bash
#
# Assemble and build the installable QPKG.
#
# The package is just the static source in qpkg/ plus the modules and the
# firmware built by the earlier steps, packaged with QNAP's own qbuild inside
# the build container.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

KERNEL_RELEASE=${KERNEL_RELEASE:-}

modules_root="$REPO_DIR/modules"
[ -d "$modules_root" ] || die "no modules built yet (run scripts/10-make-modules.sh)"

if [ -z "$KERNEL_RELEASE" ]; then
    releases=$(ls "$modules_root")
    count=$(printf '%s\n' "$releases" | grep -c .)
    [ "$count" = 1 ] || die "several module releases built, pick one with KERNEL_RELEASE=...: $releases"
    KERNEL_RELEASE=$releases
fi

mods="$modules_root/$KERNEL_RELEASE"
[ -d "$mods" ] || die "no modules for release $KERNEL_RELEASE in $modules_root"

firmware="$REPO_DIR/build/firmware"
[ -f "$firmware/OVMF_CODE.fd" ] || die "no firmware in $firmware (run scripts/20-fetch-ovmf.sh)"

tools_dir="$REPO_DIR/build/bin"
for tool in qemu-img prlimit nice qemu-system-x86_64 virtfs-proxy-helper; do
    [ -x "$tools_dir/$tool" ] ||
        die "$tool is missing from $tools_dir (run scripts/25-make-tools.sh)"
done

wrapper="$REPO_DIR/nas/shared/qemu-wrapper.sh"
[ -x "$wrapper" ] || die "missing $wrapper"

datadir="$REPO_DIR/build/qemu-datadir"
[ -d "$datadir" ] || die "no QEMU data directory in $datadir (run scripts/25-make-tools.sh)"

out="$REPO_DIR/out"
qpkg_root="$out/qpkg-src/QNAP_LXD_VM"

log "assembling QPKG source in $qpkg_root"
rm -rf "$out/qpkg-src"
mkdir -p "$qpkg_root/shared"

# qbuild only takes qpkg.cfg, package_routines and the contents of shared/
# (which are flattened into the installed package root), so everything we ship
# has to live under shared/ in the source tree.
cp -a "$REPO_DIR/qpkg/." "$qpkg_root/"
cp "$REPO_DIR/nas/shared/qnap-lxd-vm.sh" "$qpkg_root/shared/"

mkdir -p "$qpkg_root/shared/modules/$KERNEL_RELEASE"
cp "$mods"/*.ko "$qpkg_root/shared/modules/$KERNEL_RELEASE/"

mkdir -p "$qpkg_root/shared/firmware"
cp -aL "$firmware"/*.fd "$qpkg_root/shared/firmware/"

# bin/ is what the helper links into LXD's PATH: the tools, and the wrapper as
# qemu-system-x86_64. The real emulator stays in libexec/, out of PATH, so the
# wrapper is what LXD finds.
mkdir -p "$qpkg_root/shared/bin" "$qpkg_root/shared/libexec" \
         "$qpkg_root/shared/share/qemu"
for tool in qemu-img prlimit nice virtfs-proxy-helper; do
    cp "$tools_dir/$tool" "$qpkg_root/shared/bin/"
done
cp "$wrapper" "$qpkg_root/shared/bin/qemu-system-x86_64"
cp "$tools_dir/qemu-system-x86_64" "$qpkg_root/shared/libexec/"
cp -r "$datadir"/* "$qpkg_root/shared/share/qemu/"

chmod +x "$qpkg_root/shared/qnap-lxd-vm.sh" \
         "$qpkg_root/shared/qnap-lxd-vm-service.sh"
chmod 755 "$qpkg_root/shared/bin/"* "$qpkg_root/shared/libexec/"*

if ! sudo podman image exists "$BUILD_IMAGE" 2>/dev/null; then
    die "container image $BUILD_IMAGE is missing (run scripts/10-make-modules.sh first)"
fi

log "running qbuild"
sudo podman run --rm \
    --network host \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TMPDIR=/tmp \
    -v "$out":/out \
    -w /out/qpkg-src/QNAP_LXD_VM \
    "$BUILD_IMAGE" \
    qbuild

# head would SIGPIPE find and, under pipefail, fail the pipeline.
qpkg=$(find "$qpkg_root/build" -name '*.qpkg' -type f 2>/dev/null)
qpkg=$(printf '%s\n' "$qpkg" | sed -n '1p')
[ -n "$qpkg" ] || die "qbuild produced no .qpkg"

final="$out/$(basename "$qpkg")"
cp -f "$qpkg" "$final"
sudo chown "$(id -u):$(id -g)" "$final" 2>/dev/null || true

# QNAP's own .qpkg files are installed by qpkg_cli/App Center, which run them as
# the self-extracting shell installers they are; ship them executable like QNAP
# does rather than as 0644 data files.
chmod 755 "$final"

log "built $final ($(stat -c %s "$final") bytes)"

# Plain tarball for the path without App Center: unpack it on the NAS and run
# install.sh from inside it.
stage="$out/tarball/qnap-lxd-vm"
rm -rf "$out/tarball"
mkdir -p "$stage/shared" "$stage/autorun" \
         "$stage/modules/$KERNEL_RELEASE" "$stage/firmware" \
         "$stage/bin" "$stage/libexec" "$stage/share/qemu"

cp "$REPO_DIR/nas/install.sh" "$REPO_DIR/nas/uninstall.sh" "$stage/"
cp "$REPO_DIR/nas/shared/qnap-lxd-vm.sh" "$stage/shared/"
cp "$REPO_DIR/nas/autorun/autorun.sh" "$stage/autorun/"
cp "$mods"/*.ko "$stage/modules/$KERNEL_RELEASE/"
cp -aL "$firmware"/*.fd "$stage/firmware/"

for tool in qemu-img prlimit nice virtfs-proxy-helper; do
    cp "$tools_dir/$tool" "$stage/bin/"
done
cp "$wrapper" "$stage/bin/qemu-system-x86_64"
cp "$tools_dir/qemu-system-x86_64" "$stage/libexec/"
cp -r "$datadir"/* "$stage/share/qemu/"
chmod 755 "$stage/bin/"* "$stage/libexec/"*

chmod +x "$stage/install.sh" "$stage/uninstall.sh" "$stage/shared/qnap-lxd-vm.sh" "$stage/autorun/autorun.sh"

tarball="$out/qnap-lxd-vm-$KERNEL_RELEASE.tar.gz"
tar -czf "$tarball" -C "$out/tarball" qnap-lxd-vm
log "built $tarball ($(stat -c %s "$tarball") bytes)"
log "install with:"
log "  scp $final admin@nas:/share/Public/"
log "  ssh admin@nas 'sudo sh /share/Public/$(basename "$final")'"
log "  (or App Center > Install Manually; qpkg_cli --enable starts it afterwards)"
