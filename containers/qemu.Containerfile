# Build the static QEMU binaries the NAS needs.
#
#   qemu-img                every LXD image operation
#   qemu-system-x86_64      the VMs themselves
#
# LXD 5.0.2 passes "-sandbox on,..." unconditionally, so the emulator has to be
# built with seccomp; Container Station's kata-static build is not, and a QEMU
# without it refuses to start any VM. It also passes "-spice ...", which needs a
# whole static spice-server stack that does not exist for this platform - the
# wrapper shipped alongside drops those arguments, since LXD only uses SPICE for
# its console (the guest agent runs over virtio-vsock).
#
# The ROMs QEMU loads at runtime (vgabios-virtio.bin for virtio-vga,
# pxe-virtio.rom for virtio-net-pci, ...) are kept in an installed-style data
# directory: QEMU searches <datadir>/<name> for BIOS files, so they sit flat,
# with keymaps/ and dtb/ beside them. On QTS it would otherwise look in a data
# directory that does not exist.
#
# ncurses-static and util-linux-static are link-time dependencies of a system
# build: QEMU's text-mode display wants libncursesw.a, and glib's GIO (pulled in
# by the system targets) wants libmount.a and libblkid.a.
#
# libfdt: QEMU 9.0 requires it for x86_64-softmmu (its microvm machine), unlike
# 11.x where it can be disabled, so it is built from the dtc subproject that
# meson fetches with git - the release tarball does not bundle it.
#
# libaio and libusb are what LXD's own QMP calls need: every VM disk is added
# with aio=native (driver_qemu.go:3151), which only exists in a build with
# linux-aio, and "lxc config device add ... usb" goes through QEMU's usb-host.
# Configure would silently drop both, so they are requested explicitly.
#
# virtfs-proxy-helper is what LXD starts for a VM's 9p shares (a disk device
# pointing at a host path). LXD prefers virtiofs and falls back to 9p, but
# virtiofsd is a separate Rust project we do not ship, so the fallback is the
# path that gets used; without this helper, starting such a device fails with
# "Required binary \"virtfs-proxy-helper\" couldn't be found". It needs libcap-ng
# and is deprecated upstream, but QEMU 9.0 still has it.
#
# Alpine + musl + --static: single files with no libraries to match on the NAS.
ARG ALPINE=3.22
FROM alpine:${ALPINE}

RUN apk add --no-cache \
        bash \
        bzip2-static \
        build-base \
        curl \
        file \
        gettext-static \
        git \
        glib-dev \
        glib-static \
        libaio-dev \
        libcap-ng-dev \
        libcap-ng-static \
        libseccomp-dev \
        libseccomp-static \
        libusb-dev \
        linux-headers \
        meson \
        ncurses-static \
        ninja \
        pcre2-static \
        pixman-dev \
        pixman-static \
        python3 \
        tar \
        util-linux-static \
        xz \
        zlib-dev \
        zlib-static

ARG QEMU_VERSION=11.1.2
WORKDIR /src

RUN curl -fL -o qemu.tar.xz "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
    && tar xf qemu.tar.xz \
    && rm -f qemu.tar.xz

RUN cd "qemu-${QEMU_VERSION}" \
    && ./configure \
        --static \
        --target-list=x86_64-softmmu \
        --enable-tools \
        --enable-seccomp \
        --enable-linux-aio \
        --enable-libusb \
        --enable-virtfs-proxy-helper \
        --disable-docs \
        --disable-guest-agent \
    && ninja -C build qemu-img qemu-system-x86_64 fsdev/virtfs-proxy-helper \
    && cp build/qemu-img /qemu-img \
    && cp build/qemu-system-x86_64 /qemu-system-x86_64 \
    && cp build/fsdev/virtfs-proxy-helper /virtfs-proxy-helper \
    && mkdir -p /qemu-datadir \
    && cp -r build/pc-bios/. /qemu-datadir/ \
    && cp -r pc-bios/. /qemu-datadir/ \
    && for binary in /qemu-img /qemu-system-x86_64 /virtfs-proxy-helper; do \
           strip -s "$binary"; \
           file "$binary"; \
       done \
    && /qemu-img --version \
    && /qemu-system-x86_64 --version \
    && { /virtfs-proxy-helper 2>&1 | head -2; true; }
