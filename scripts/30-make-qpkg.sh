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
for tool in qemu-img prlimit nice; do
    [ -x "$tools_dir/$tool" ] ||
        die "$tool is missing from $tools_dir (run scripts/25-make-tools.sh)"
done

out="$REPO_DIR/out"
qpkg_root="$out/qpkg-src/QNAP_Vsock"

log "assembling QPKG source in $qpkg_root"
rm -rf "$out/qpkg-src"
mkdir -p "$qpkg_root/shared"

# qbuild only takes qpkg.cfg, package_routines and the contents of shared/
# (which are flattened into the installed package root), so everything we ship
# has to live under shared/ in the source tree.
cp -a "$REPO_DIR/qpkg/." "$qpkg_root/"
cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$qpkg_root/shared/"

mkdir -p "$qpkg_root/shared/modules/$KERNEL_RELEASE"
cp "$mods"/*.ko "$qpkg_root/shared/modules/$KERNEL_RELEASE/"

mkdir -p "$qpkg_root/shared/firmware"
cp -aL "$firmware"/*.fd "$qpkg_root/shared/firmware/"

mkdir -p "$qpkg_root/shared/bin"
cp "$tools_dir"/* "$qpkg_root/shared/bin/"

chmod +x "$qpkg_root/shared/qnap-vsock.sh" \
         "$qpkg_root/shared/qnap-vsock-service.sh"
chmod 755 "$qpkg_root/shared/bin/"*

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
    -w /out/qpkg-src/QNAP_Vsock \
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
stage="$out/tarball/qnap-vsock"
rm -rf "$out/tarball"
mkdir -p "$stage/shared" "$stage/autorun" \
         "$stage/modules/$KERNEL_RELEASE" "$stage/firmware" "$stage/bin"

cp "$REPO_DIR/nas/install.sh" "$REPO_DIR/nas/uninstall.sh" "$stage/"
cp "$REPO_DIR/nas/shared/qnap-vsock.sh" "$stage/shared/"
cp "$REPO_DIR/nas/autorun/autorun.sh" "$stage/autorun/"
cp "$mods"/*.ko "$stage/modules/$KERNEL_RELEASE/"
cp -aL "$firmware"/*.fd "$stage/firmware/"

cp "$tools_dir"/* "$stage/bin/"
chmod 755 "$stage/bin/"*

chmod +x "$stage/install.sh" "$stage/uninstall.sh" "$stage/shared/qnap-vsock.sh" "$stage/autorun/autorun.sh"

tarball="$out/qnap-vsock-$KERNEL_RELEASE.tar.gz"
tar -czf "$tarball" -C "$out/tarball" qnap-vsock
log "built $tarball ($(stat -c %s "$tarball") bytes)"
log "install with:"
log "  scp $final admin@nas:/share/Public/"
log "  ssh admin@nas 'sudo sh /share/Public/$(basename "$final")'"
log "  (or App Center > Install Manually; qpkg_cli --enable starts it afterwards)"
