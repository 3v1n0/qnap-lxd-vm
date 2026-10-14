# The UEFI firmware LXD boots VMs with, installed by apt inside this image.
#
# The Ubuntu release of the image is what pins the edk2 snapshot, so no
# firmware URL is hard-coded anywhere: backing OVMF_UBUNTU_RELEASE with, say,
# 22.04 upgrades the firmware to that release's ovmf package. 20.04 is the
# default because its edk2 (0~20191122) is contemporary with the QEMU that
# Container Station ships, and the firmware and the emulator are known to work
# together.
ARG UBUNTU=20.04
FROM ubuntu:${UBUNTU}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ovmf
