#!/bin/bash
#
# The versions this repository is pinned to.
#
# This file is the single source for the inputs that determine the build
# outputs: the build scripts use these values as their defaults (environment
# overrides still win), and the CI cache keys are formed from it alone - so a
# change here upgrades the build, while refactorings elsewhere (flags, wording,
# helpers) do not invalidate anything cached.
#
# Nothing here is the kernel *release* string: that is always derived from the
# QNAP tree (scripts/kernel-release.sh) and cross-checked against the NAS.

: "${QTS_GPL:=5.2.3.20250218}"          # QNAP GPL source release to fetch
: "${KERNEL_MAJOR:=5.10}"               # kernel series the QNAP tree carries
: "${MODEL:=TS-X53II}"                  # model whose kernel_cfg configures the tree
: "${QEMU_VERSION:=9.0.3}"              # newest that accepts LXD 5.0.2's QMP dialect
: "${OVMF_UBUNTU_RELEASE:=20.04}"       # Ubuntu release pinning the edk2 firmware
: "${BUILDER_UBUNTU:=20.04}"            # Ubuntu release of the gcc-9 toolchain image
