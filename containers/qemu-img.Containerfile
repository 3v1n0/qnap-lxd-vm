# Build a static qemu-img for the NAS.
#
# LXD runs qemu-img for all its image work ("info --output json", convert,
# create, amend, commit). Container Station ships a QEMU without it and QTS has
# none, so VMs cannot even read an image without it.
#
# Alpine + musl + --static: the result is one file with no libraries to ship or
# find on the NAS.
ARG ALPINE=3.22
FROM alpine:${ALPINE}

RUN apk add --no-cache \
        bash \
        build-base \
        bzip2-static \
        curl \
        file \
        gettext-static \
        glib-dev \
        glib-static \
        linux-headers \
        meson \
        ninja \
        pcre2-static \
        pixman-static \
        python3 \
        tar \
        xz \
        zlib-dev \
        zlib-static

ARG QEMU_VERSION=11.1.2
WORKDIR /src

RUN curl -fL -o qemu.tar.xz "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
    && tar xf qemu.tar.xz \
    && rm -f qemu.tar.xz

# Tools only: no system or user emulation, so no display, audio or firmware
# dependencies are needed. Everything else auto-detects. Ninja directly: the
# generated GNUmakefile wrapper has no per-binary target.
RUN cd "qemu-${QEMU_VERSION}" \
    && ./configure \
        --static \
        --disable-system \
        --disable-user \
        --disable-docs \
        --disable-guest-agent \
        --enable-tools \
    && ninja -C build qemu-img \
    && cp build/qemu-img /qemu-img \
    && strip -s /qemu-img \
    && file /qemu-img \
    && (ldd /qemu-img 2>&1 || true)
