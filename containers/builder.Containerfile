# Build container for the QNAP kernel modules and the QPKG.
#
# Ubuntu 20.04 / gcc 9 is deliberate: it is the toolchain era of QNAP's 5.10
# kernel and avoids the breakage that new gcc versions cause on 5.10 headers.
# It has nothing to do with the module ABI (QNAP kernels have
# CONFIG_MODVERSIONS off, so only the vermagic string matters).
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bc \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        curl \
        dos2unix \
        file \
        flex \
        git \
        jq \
        kmod \
        libelf-dev \
        libncurses-dev \
        libssl-dev \
        python3 \
        rsync \
        sudo \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# QNAP Development Kit (qbuild) for packaging the QPKG the official way.
RUN git clone --depth 1 https://github.com/qnap-dev/QDK.git /opt/QDK \
    && make -C /opt/QDK/src \
    && cp /opt/QDK/src/bin/qpkg_encrypt /bin/ \
    && cp -rf /opt/QDK/shared /usr/share/QDK \
    && mkdir -p /etc/config \
    && sed -e '2d' /usr/share/QDK/qdk.conf > /etc/config/qdk.conf \
    && sed -i '2iQDK_PATH_P=/usr/share' /etc/config/qdk.conf \
    && rm -rf /opt/QDK/.git

ENV PATH="/usr/share/QDK/bin:${PATH}"

WORKDIR /work
