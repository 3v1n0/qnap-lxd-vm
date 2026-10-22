# Compatibility notes

Container Station ships **LXD 5.0.2** (2022) and a **kata-static QEMU 5.0.0**, on
a **5.10.60-qnap** kernel, on a NAS whose QPKG start order comes from QTS 5.2.
Almost everything in this repository exists because those four things disagree
with each other.

This is the list, in the order LXD hits them, with the exact message you would
have seen and what handles it.

| Symptom | Cause | Handled by |
| --- | --- | --- |
| `Vsock support is missing (no /dev/vsock)` | QNAP's kernel has no vsock at all | the three modules we build from QNAP's GPL source |
| the same message, after loading them | LXD caches that check at daemon start | `preflight`, and one `qpkg_cli --stop/--start container-station` |
| `QEMU failed to run feature checks` | no UEFI firmware on the NAS | OVMF shipped and linked into `/usr/share/OVMF` |
| `Failed to find executable "qemu-img"` | nothing provides it | a static `qemu-img` from this package |
| `Failed to find executable "prlimit"` | LXD wraps `qemu-img` in it | a static `prlimit` of our own |
| `Failed to find executable "nice"` | image conversion runs at low priority | a static `nice` of our own |
| `Failed to setup virtfs-proxy-helper for device "x"` | LXD's 9p fallback for a VM share needs a QEMU tool | a static `virtfs-proxy-helper` from this package |
| `There is no option group 'sandbox'` | LXD requires seccomp, kata's QEMU has none | our own QEMU, built with `--enable-seccomp` |
| `eVMCS version range [1..1] is not supported by kernel (supported: [0..0])` | LXD's `hv_passthrough` implies eVMCS v1 | the wrapper drops that flag |
| `failed to find romfile vgabios-virtio.bin` | QEMU looks for ROMs in a datadir that does not exist on QTS | the ROMs ship in the package; the wrapper passes `-L` |
| `Failed to find file descriptor with matching flags=0x4002` | QEMU ≥ 9.1 compares the O_DIRECT bit of a handed-over fd; LXD hands one over without it | QEMU pinned to 9.0.3 |
| `Invalid parameter type for 'bootindex', expected: integer` | LXD types QMP integers as strings; QEMU ≥ 9.2 refuses | QEMU pinned to 9.0.3 |

## vsock is missing from the kernel

QNAP's 5.10.60 kernel has `CONFIG_VSOCKETS` off: no vsock symbols in
`/proc/kallsyms`, no `vsock` in `/proc/misc`, no `vsock.ko` under
`/lib/modules/$(uname -r)`. `vhost.ko`, `vhost_iotlb.ko` and `vhost_net.ko` are
present, so only the vsock stack is missing.

We build `vsock.ko`, `vmw_vsock_virtio_transport_common.ko` and `vhost_vsock.ko`
from QNAP's own kernel source and `insmod` them from the package directory —
nothing is written to `/lib/modules`, and there is no `depmod` or `modprobe`.

## LXD caches the answer at daemon start

`lxd/daemon.go` builds `state.InstanceTypes` once, from each driver's
`Info()`, and `lxd/instance/instance_utils.go` returns that stored error
forever. `Info()` checks `/dev/kvm`, then `/dev/vsock` (**before** trying
`modprobe vhost_vsock`), then QEMU and its feature checks.

So a daemon that started before the modules/OVMF/qemu-img existed keeps
reporting the old answer, and loading them afterwards changes nothing until it
restarts. This repository never starts or restarts LXD; `preflight` says whether
the running daemon predates the modules, and the fix is:

```sh
qpkg_cli --stop container-station && qpkg_cli --start container-station
```

## Tools LXD execs but nothing provides

| Tool | Why LXD needs it | Reference |
| --- | --- | --- |
| `qemu-img` | every image operation | `lxd/storage/utils.go` |
| `prlimit` | wraps `qemu-img` to bound its CPU and memory | `lxd/storage/utils.go:472` |
| `nice` | image conversion at low priority | `lxd/storage/utils.go:526` |
| `virtfs-proxy-helper` | a VM's 9p share of a host path | `lxd/device/device_utils_disk.go:301` |

All three are built statically (Alpine, musl) so they are single files with no
libraries to find on the NAS. `prlimit` and `nice` are small implementations of
our own (`containers/prlimit/`, `containers/nice/`): util-linux' `prlimit` is
not an `--enable-` option (it only builds when its dependencies happen to be
enabled), and QTS has no `nice` in the daemon's `PATH`.

## QEMU: three incompatibilities with LXD 5.0.2

Container Station's QEMU cannot run an LXD VM, and upstream QEMU moved past what
LXD 5.0.2 expects. Both are handled by building our own QEMU and putting a small
wrapper in front of it (`nas/shared/qemu-wrapper.sh`).

**`-sandbox` needs seccomp.** LXD passes
`-sandbox on,obsolete=deny,elevateprivileges=allow,spawn=allow,resourcecontrol=deny`
unconditionally (`lxd/instance/drivers/driver_qemu.go:1272`); the kata-static
build answers *"There is no option group 'sandbox'"*. Our QEMU is built with
`--enable-seccomp`, so the sandbox is real.

**`hv_passthrough` asks for an eVMCS version this kernel lacks.** On kernels
5.10 or newer LXD adds `hv_passthrough` to `-cpu` (`driver_qemu.go:1241`), and
QEMU expands it to every Hyper-V enlightenment it knows, `hv-evmcs` included,
which means asking KVM for enlightened VMCS version 1. QNAP's KVM implements
version 0 only:

```
qemu-system-x86_64: eVMCS version range [1..1] is not supported by kernel (supported: [0..0])
```

The wrapper drops the flag — it is a Windows guest optimisation, so nothing a
Linux guest needs is lost — and keeps it if a file named
`enable-hv-passthrough` sits next to the wrapper in the payload. (LXD's own way
out, `migration.stateful=true`, also disables `usb` devices on the VM.)

**The option ROMs live in a data directory that does not exist on QTS.** QEMU
loads `vgabios-virtio.bin` for `virtio-vga` and `pxe-virtio.rom` for
`virtio-net-pci` from the data directory compiled into the binary, and it
searches it as `<datadir>/<name>` — the ROMs are installed *flat*, with
`keymaps/` and `dtb/` beside them, which is why pointing `-L` at a directory
containing `pc-bios/` is not enough. The package ships an installed-style data
directory as `share/qemu/` and the wrapper passes `-L`.

The ROMs are the prebuilt ones from QEMU's source tree (the release tarball
carries seabios/vgabios/ipxe's outputs), so no `roms/` submodule build is
needed.

## QEMU ≥ 9.1 is stricter about handed-over file descriptors

LXD does not let QEMU open a VM's disks by path. It opens the file itself, hands
the descriptor to QEMU through an fd set, and points the block device at
`/dev/fdset/<id>` (`driver_qemu.go:3414`). QEMU then looks through that set for a
descriptor whose flags match what the block driver needs — `monitor/fds.c`:

```c
int mask = O_ACCMODE;
mask |= O_DIRECT;                          /* added in QEMU 9.1 */
...
if ((flags & mask) == (mon_fd_flags & mask)) { /* match */ }
```

LXD opens the disk **without** O_DIRECT, but asks for it anyway — its block device
sets `cache.direct` (`driver_qemu.go:3254`), and `aio=native`, which is the
default unless the backing filesystem is ZFS or Btrfs (`:3204`):

```go
blockDev := map[string]any{
    "aio":   aioMode,                          // "native"
    "cache": map[string]any{"direct": true, "no-flush": false},
    "driver": "file", "node-name": ..., "filename": "/dev/fdset/0",
}
```

Up to QEMU 9.0 the mask covered only the access mode, so the mismatch did not
matter. From 9.1 it does:

```
Failed setting up device "root": Failed adding block device:
    Failed to find file descriptor with matching flags=0x4002
```

`0x4002` is `O_RDWR | O_DIRECT`. Neither side can be changed here (LXD 5.0.2 is
Container Station's, and the fd layout is LXD's design), so the QEMU pin below
covers it.

## QEMU ≥ 9.2 refuses LXD 5.0.2's QMP parameter types

Devices LXD adds *after* the emulator starts — the NIC, USB devices, disks — go
over QMP, and LXD 5.0.2 types its integers as strings:

```go
qemuDev["bootindex"] = strconv.Itoa(bootIndex)   // driver_qemu.go:3467
qemuDev["vectors"]   = strconv.Itoa(vectors)     // driver_qemu.go:3487
```

QEMU 9.2 started rejecting that (`lxc/incus#1522`: *"QEMU now refuses `string`
used in place of `integer`s and `uint64`s… also affects parameters such as
`vectors`"*), so a VM start fails with:

```
Failed setting up device "eth0": Failed adding NIC device:
    Invalid parameter type for 'bootindex', expected: integer
```

LXD 5.0.2 cannot be changed here, so `QEMU_VERSION` in `scripts/25-make-tools.sh`
pins **9.0.3**: the newest release that avoids *both* this and the fd-set
`O_DIRECT` mask above (9.1 changed the mask, 9.2 rejected the strings). Bumping
the pin means re-running `tests/qemu-config-check.sh` against a real config,
which issues LXD's own `blockdev-add` and `device_add` calls.

Three build options are not optional either: every disk LXD adds is configured
with `aio=native` (`driver_qemu.go:3151`), which only exists in a build with
linux-aio, USB passthrough uses QEMU's `usb-host`, and a VM's 9p share needs
`virtfs-proxy-helper` (LXD prefers virtiofs, but `virtiofsd` is a separate Rust
project). Configure drops all three without a word if their libraries are
missing, which is why `containers/qemu.Containerfile` installs
`libaio-dev`/`libusb-dev`/`libcap-ng-dev` and asks for them explicitly, and why
`tests/qemu-config-check.sh` asserts the devices exist and that a disk with
`aio=native` is accepted.

A consequence of pinning a 9.0 release: unlike 11.x, it requires libfdt for
`x86_64-softmmu` (its `microvm` machine), so the build fetches the pinned `dtc`
subproject with `git` and links it statically.

## Where the logs are

`lxc info --show-log` shows the instance's `qemu.log`, which LXD points QEMU at
with `-D` but never gives `-d` items - so QEMU creates it **empty** and the
command prints nothing. Turning some logging on is a marker file away:

```sh
sudo touch "$(dirname "$(readlink -f /usr/local/bin/qemu-system-x86_64)")/../enable-qemu-log"
```

Failures in the *emulator* (a bad `-cpu`, a missing ROM) are also printed by
QEMU on stderr, which LXD captures into the `lxc start` error itself. Failures in
LXD's own monitor conversation - the `bootindex` and fd-set errors above - never
reach QEMU's log at all; `lxc monitor --pretty` shows the daemon's side live.

## SPICE is dropped, and what that costs

LXD 5.0.2 always passes `-spice unix=on,…` and writes `spicevmc`/`spiceport`
chardevs and three `usb-redir` devices into the config it hands QEMU over
`-readconfig`. SPICE needs spice-server, for which no static build exists for
this platform.

The wrapper drops the argument and filters those sections out of the config.
What is lost is only what a SPICE *client* provides: `lxc console --type=vga`,
the clipboard/folder channels, and redirecting a USB device from your desktop
into the VM. Everything LXD itself does is unaffected — the guest agent runs
over virtio-vsock (`lxc exec`, `lxc file`), `lxc console` uses the serial
console, and `lxc config device add … usb` uses QMP `usb-host` with the host
device passed as a file descriptor (`lxd/instance/drivers/driver_qemu.go:3832`),
not SPICE.

Losing the VGA console also means the serial console is the only view of a
guest, and whether a guest prints there is up to the guest. Home Assistant OS
is a good example: its kernel command line lives in `cmdline.txt` on the EFI
System Partition, and the `ova` images ship `console=ttyS0 console=tty0` while
the `generic-x86-64` images ship only `console=tty0`. The latter stay silent
after GRUB *even when they boot perfectly* — GRUB always talks to the serial
port, so `Booting \`Slot A …'` followed by nothing proves nothing about the
kernel. Two ways to see more:

* Press a key during GRUB's one-second countdown, then `e`, and append
  `console=ttyS0,115200` to the `linux` line before pressing Ctrl-X. That
  lasts for one boot and needs nothing but `lxc console`.
* Or use the image variant that already enables it (`haos_ova-*.qcow2`).
* Or make it permanent from inside the running guest: `/mnt/boot` is the EFI
  System Partition, so `mount -o remount,rw /mnt/boot` and adding
  `console=ttyS0` to `/mnt/boot/cmdline.txt` makes every later boot print
  there.

An HAOS image also counts every boot attempt in GRUB's environment
(`buildroot-external/board/pc/grub.cfg` in `home-assistant/operating-system`):
`TRY` climbs on each start and, at 3, slot A is skipped in favour of the rescue
entry, so repeated starts of a slot that never marks itself good end up at
"Slot A (rescue shell)" rather than at the same message.

The README's "Console access to VMs" section covers the same ground for guests
in general, including what other images need.

## QTS 5.2 decides QPKG start order itself

QTS derives each package's start number, and the `/etc/rcS.d/QS<n><name>` links,
from the order of the sections in `/etc/config/qpkg.conf`; the `RC_Number` field
is vestigial (the reference NAS has packages asking for 199/200/999 starting as
`QS108`/`QS111`/`QS117`). Since 5.2 the starts are asynchronous, which is why
the community's SortMyQPKGs sorter is documented as *"no-longer effective on QTS
5.2.0 or-later"*.

This package therefore does not reorder anything and does not restart LXD. After
installing, and on any boot where Container Station's daemon got there first,
`preflight` reports it and one restart of Container Station settles it.

## Checking any of this without a NAS

```sh
# what the NAS would see: every check LXD makes, every tool it may run, and
# whether the running daemon predates the modules
sudo ./shared/qnap-lxd-vm.sh preflight

# the config LXD writes, plus the device_add calls it makes afterwards,
# against the emulator this project builds - for any config from
# /var/log/lxd/<name>/qemu.conf
tests/qemu-config-check.sh /var/log/lxd/haos/qemu.conf

# the packaged payloads and the tools
tests/test-packaging.sh
```

## Version pins and why

| Pin | Value | Why |
| --- | --- | --- |
| `QEMU_VERSION` | 9.0.3 | newest that accepts LXD 5.0.2's string-typed QMP integers (9.2 rejects them) and its non-O_DIRECT descriptors in fd sets (9.1 compares that bit) |
| module toolchain | Ubuntu 20.04 / gcc 9 | the era of the 5.10 kernel; newer gcc does not build its headers cleanly (it is *not* an ABI requirement — QNAP kernels have `CONFIG_MODVERSIONS` off, so only the vermagic matters) |
| `KERNEL_RELEASE` | read from the tree | never hardcoded; asserted against the built modules and cross-checked on the NAS |
