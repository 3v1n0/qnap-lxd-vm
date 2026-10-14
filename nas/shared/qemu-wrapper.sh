#!/bin/sh
#
# qemu-system-x86_64 for LXD on QTS.
#
# LXD 5.0.2 hardcodes arguments that the QEMU we can ship does not accept:
#
#   -spice unix=on,disable-ticketing=on,addr=...
#
# plus, in the config it passes with -readconfig, a spicevmc chardev, a
# spiceport chardev and the virtserialport devices that use them. SPICE needs
# spice-server, for which no static build exists for this platform, and it is
# only LXD's console plumbing: the guest agent talks over virtio-vsock, which
# this package provides. So the spice argument is dropped and the spice sections
# of the config file are filtered out, while every other argument is passed
# through unchanged - byte for byte, including arguments containing spaces (LXD's
# -smbios line does).
#
# QEMU also needs its firmware ROMs: virtio-vga wants vgabios-virtio.bin and
# virtio-net-pci wants pxe-virtio.rom, and it looks for them in the data
# directory compiled into the binary - a path that does not exist on QTS. This
# package ships the same layout an installed QEMU has (the ROMs directly in the
# data directory, keymaps/ and dtb/ beside them; QEMU searches <datadir>/<name>
# for BIOS files) and points QEMU at it with -L.
#
# The real emulator lives in ../libexec/ so that only this wrapper is on PATH.
set -eu

# This is normally reached through the symlink the helper puts in
# /usr/local/bin, so resolve our own path first: dirname "$0" would be
# /usr/local/bin and the emulator would not be found.
self=$(readlink -f "$0" 2>/dev/null)
[ -n "$self" ] || self=$0
self_dir=$(CDPATH= cd -- "$(dirname "$self")" && pwd)
real="$self_dir/../libexec/qemu-system-x86_64"

if [ ! -x "$real" ]; then
    echo "qemu-system-x86_64: cannot find the emulator at $real" >&2
    exit 1
fi

# Same layout, minus the sections that need spice.
strip_spice_config() {
    source=$1
    target="$source.no-spice"

    if ! awk '
        /^\[/ {
            if (have && keep) printf "%s", block
            block = $0 "\n"
            have = 1
            keep = ($0 ~ /spice/) ? 0 : 1
            next
        }
        {
            if (!have) next
            block = block $0 "\n"
            if ($0 ~ /spicevmc|spiceport/) keep = 0
        }
        END { if (have && keep) printf "%s", block }
    ' "$source" > "$target"; then
        rm -f "$target"
        echo "qemu-system-x86_64: could not filter $source" >&2
        exit 1
    fi

    printf '%s' "$target"
}

dropped_spice=0
dropped_hv=0
total=$#
seen=0

# Each original argument is consumed exactly once and re-appended at the end, so
# the list has to be drained by count: appending while looping on "$#" would
# rotate forever. Options that take a value consume two.
while [ "$seen" -lt "$total" ]; do
    arg=$1
    shift
    seen=$((seen + 1))

    case "$arg" in
        -spice)
            if [ "$seen" -lt "$total" ]; then
                shift
                seen=$((seen + 1))
            fi
            dropped_spice=1
            continue
            ;;
        -spice=*)
            dropped_spice=1
            continue
            ;;
        -readconfig)
            if [ "$seen" -ge "$total" ]; then
                echo "qemu-system-x86_64: -readconfig without a file" >&2
                exit 1
            fi
            config=$1
            shift
            seen=$((seen + 1))
            set -- "$@" -readconfig "$(strip_spice_config "$config")"
            continue
            ;;
        # LXD adds hv_passthrough to -cpu on any kernel 5.10 or newer, and QEMU
        # expands that to every Hyper-V enlightenment it knows, hv-evmcs
        # included. QEMU implements hv-evmcs by asking KVM for enlightened VMCS
        # version 1, which this kernel does not implement (it offers version 0),
        # so the VM fails to start with:
        #
        #   eVMCS version range [1..1] is not supported by kernel (supported: [0..0])
        #
        # The flag is a Windows guest optimisation, and nothing about a Linux
        # guest needs it, so drop it - keeping it behind an opt-in marker for
        # kernels that do implement v1. Other extensions LXD adds (topoext) are
        # left alone.
        -cpu)
            if [ "$seen" -ge "$total" ]; then
                echo "qemu-system-x86_64: -cpu without a value" >&2
                exit 1
            fi
            cpu=$1
            shift
            seen=$((seen + 1))

            case ",$cpu," in
                *,hv_passthrough,*|*,hv-passthrough,*)
                    if [ -e "$self_dir/../enable-hv-passthrough" ]; then
                        cpu=$(printf '%s' "$cpu" | sed 's/hv_passthrough/hv-passthrough/')
                    else
                        cpu=$(printf '%s' "$cpu" | sed -e 's/^hv_passthrough,//' -e 's/^hv-passthrough,//' \
                                                    -e 's/,hv_passthrough//' -e 's/,hv-passthrough//')
                        [ -n "$cpu" ] || cpu=host
                        dropped_hv=1
                    fi
                    ;;
            esac

            set -- "$@" -cpu "$cpu"
            continue
            ;;
    esac

    set -- "$@" "$arg"
done

# LXD passes -D for QEMU's log but never -d, so that file is created empty and
# lxc info --show-log shows nothing. An opt-in marker turns some logging on.
if [ -e "$self_dir/../enable-qemu-log" ]; then
    set -- "$@" -d guest_errors,unimp
fi

# ROMs and keymaps, in the layout QEMU expects (<datadir>/pc-bios/...).
if [ -d "$self_dir/../share/qemu" ]; then
    datadir=$(CDPATH= cd -- "$self_dir/../share/qemu" && pwd)
    set -- "$@" -L "$datadir"
fi

if [ "$dropped_spice" = 1 ]; then
    echo "qemu-system-x86_64: dropped the SPICE options LXD passed; this build has no spice support" >&2
fi

if [ "$dropped_hv" = 1 ]; then
    echo "qemu-system-x86_64: dropped hv_passthrough; this kernel's KVM does not support the eVMCS version QEMU would ask for" >&2
fi

exec "$real" "$@"
