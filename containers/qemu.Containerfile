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
        glib-dev \
        glib-static \
        libseccomp-dev \
        libseccomp-static \
        linux-headers \
        meson \
        ninja \
        pcre2-static \
        pixman-dev \
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

RUN cd "qemu-${QEMU_VERSION}" \
    && ./configure \
        --static \
        --target-list=x86_64-softmmu \
        --enable-tools \
        --enable-seccomp \
        --disable-docs \
        --disable-guest-agent \
    && ninja -C build qemu-img qemu-system-x86_64 \
    && cp build/qemu-img /qemu-img \
    && cp build/qemu-system-x86_64 /qemu-system-x86_64 \
    && for binary in /qemu-img /qemu-system-x86_64; do \
           strip -s "$binary"; \
           file "$binary"; \
       done \
    && /qemu-img --version \
    && /qemu-system-x86_64 --version
