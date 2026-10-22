# qnap-lxd-vm

Runs LXD virtual machines on a QNAP NAS: makes Container Station's LXD able to
create and start `--vm` instances, which it cannot do out of the box because
QNAP's kernel is built without the vsock stack, and Container Station ships
neither a usable QEMU, nor `qemu-img`, nor UEFI firmware.

Built and verified against a **TS-X53II running QTS 5.2.10 (kernel
5.10.60-qnap)**, but nothing here is specific to that model or firmware.

## Why a stock NAS cannot

`lxc init ... --vm` fails with:

```
Instance type "virtual-machine" is not supported on this server: Vsock support is missing (no /dev/vsock)
```

LXD checks VM support in this order (`lxd/instance/drivers/driver_qemu.go`,
`Info()`), and caches the result **once, at daemon start**:

1. `/dev/kvm` exists
2. `/dev/vsock` exists
3. `modprobe vhost_vsock`

On QNAP's kernel none of the vsock code exists: there are no vsock symbols in
`/proc/kallsyms`, no `vsock` entry in `/proc/misc`, and no `vsock.ko` in
`/lib/modules/$(uname -r)`. `vhost.ko`, `vhost_iotlb.ko` and `vhost_net.ko` are
present, so only the vsock stack is missing.

None of that is the whole story: LXD 5.0.2, Container Station's QEMU, the 5.10
kernel and QTS 5.2 each disagree with the next in ways that surface one failing
`lxc` command at a time. Every one of them — with the message it produces, the
cause and what handles it — is written up in
[docs/compatibility.md](docs/compatibility.md).

Three more things LXD needs are also missing on a stock Container Station:
`qemu-system-x86_64` is not on the LXD daemon's `PATH` (the only QEMU is a
kata-static build under Container Station's own prefix), there is no UEFI
firmware at `/usr/share/OVMF`, which LXD uses for every x86 VM, and there is no
`qemu-img`, which LXD runs for all of its image work:

```
Failed creating instance from image: Failed reading image info "...rootfs":
    Failed to find executable "qemu-img": exec: "qemu-img": executable file not found in $PATH
```

## What this provides

* `vsock.ko`, `vmw_vsock_virtio_transport_common.ko` and `vhost_vsock.ko`,
  built from QNAP's own GPL kernel source so the vermagic matches exactly.
* `/usr/local/bin/qemu-system-x86_64` -> this package's own static QEMU (via a
  wrapper, see below), and `qemu-img`, `prlimit`, `nice` and
  `virtfs-proxy-helper` next to it. Nothing on QTS or in Container Station
  provides any of them.
* The QEMU option ROMs (`vgabios-virtio.bin` for `virtio-vga`, `pxe-virtio.rom`
  for `virtio-net-pci`, and the rest of `pc-bios/`) in the package, pointed at
  with `-L`.
* `OVMF_CODE.fd`/`OVMF_VARS.fd` (plus the `.ms` secure boot variants) in
  `/usr/share/OVMF`.
* A QPKG (App Center) and a plain tarball for keeping all of that loaded
  across reboots.

Everything LXD reaches for when creating and starting a VM, and where it comes
from:

| Tool | Used for | Provided by |
| --- | --- | --- |
| `qemu-system-x86_64` | the VM itself | this package: a static QEMU built with seccomp, behind a wrapper |
| `qemu-img` | every image operation | this package (static) |
| `prlimit` | bounds `qemu-img`'s CPU and memory | this package (static) |
| `nice` | runs image conversion at low priority (`nice -n19 qemu-img convert`) | this package (static) |
| `OVMF_CODE.fd`, `OVMF_VARS.fd` | UEFI firmware | this package |
| `modprobe`, `ip` | kernel modules, interfaces and routes | QTS |
| `nft` / `iptables` / `ebtables` | firewall | QTS (one of the three) |
| `apparmor_parser` | LXD's `qemu-img` profile | QTS, needed only when AppArmor is enabled |
| `dnsmasq` | LXD-managed networks only | Container Station / QTS |
| `virtfs-proxy-helper` | a VM's 9p shares (a disk device pointing at a host path) | this package (static) |
| `virtiofsd` | the preferred way to share a host path with a VM | not shipped: LXD falls back to 9p, which needs `virtfs-proxy-helper` |
| `swtpm` | `tpm` devices, optional | only needed if you add one |
| `mkisofs` | cloud-init config drive, optional | only needed for a cloud-init disk device |

### Why there is a wrapper around QEMU

LXD 5.0.2 hardcodes two arguments that Container Station's kata-static QEMU
cannot take, and neither is optional in its code:

* `-sandbox on,…` (`driver_qemu.go`), which a QEMU without seccomp rejects
  outright — *"There is no option group 'sandbox'"*. So this package builds its
  own QEMU with `--enable-seccomp`: the sandbox is real, not filtered.
* `-spice unix=on,…` plus, in the config it passes with `-readconfig`, a
  `spicevmc` chardev, a `spiceport` chardev and the virtserialport devices using
  them. SPICE needs spice-server, for which no static build exists for this
  platform, and LXD only uses it for its SPICE console — the guest agent runs
  over virtio-vsock, which this package provides.

So `bin/qemu-system-x86_64` is a small wrapper that drops `-spice`, filters the
spice sections out of the `-readconfig` file (keeping everything else
byte-for-byte, including arguments with spaces), translates the
`hv_passthrough` flag that QEMU has since renamed to `hv-passthrough`, and execs
the real binary from `libexec/`. That binary is what `preflight` shows on
`PATH`, so it is always clear which QEMU LXD is using.

It also passes `-L` at the package's own `share/qemu`, because QEMU looks for
those option ROMs in the data directory compiled into it — a path that does not
exist on QTS. Without them a VM fails with e.g. *"failed to find romfile
vgabios-virtio.bin"* the moment LXD asks for its GPU device, and the NIC has a
ROM too, so dropping devices is not a way out.

It also drops `hv_passthrough`, which LXD adds to `-cpu` on any kernel 5.10 or
newer because QEMU expands it to every Hyper-V enlightenment it knows —
including `hv-evmcs`, which QEMU implements by asking KVM for enlightened VMCS
version 1. This kernel's KVM offers version 0 only, so the VM dies with:

```
qemu-system-x86_64: eVMCS version range [1..1] is not supported by kernel (supported: [0..0])
```

It is a Windows-guest optimisation, so nothing a Linux guest needs is lost, and
it is kept if a file named `enable-hv-passthrough` sits next to the wrapper in
the payload. (LXD's own way out is `lxc config set <vm> migration.stateful true`,
which makes it leave the flag out — but that also disables `usb` devices on the
VM and changes what migrations do.)

`QEMU_VERSION` in `build.sh tools` pins the emulator version (currently
9.0.3, against Container Station's 5.0.0) — deliberately not the newest, because
two later changes break LXD 5.0.2: 9.1 compares the `O_DIRECT` bit of the
descriptors LXD hands over (it opens VM disks without it, then asks QEMU for it),
and 9.2 rejects the string-typed QMP integers LXD sends for `bootindex` and
`vectors`. Bumping the pin means re-running `tests/qemu-config-check.sh` against
a real config, which makes both of those calls.

An LXD-generated config can be checked against the emulator before it ever
reaches the NAS:

```sh
tests/qemu-config-check.sh /var/log/lxd/<name>/qemu.conf
```

which rewrites the host-specific parts (KVM, the OVMF paths, the NVRAM fd, the
9p path, the sockets), assembles the payload layout, starts the emulator with
`-S` so every device and ROM has to initialise, and then speaks QMP to it the way
LXD does — adding the root disk through an fd set and the NIC with LXD's own
parameter types — so the emulator dialect is checked too, not just the config.
| `xz`, `zstd`, `gzip`, `bzip2`, `lzma` | compressed images | QTS, needed only for the matching image format |

`preflight` prints exactly this list with `present`/`MISSING`, so the answer to
"what else might be missing" is one command rather than one failed attempt per
tool. LXD resolves all of them through `PATH` when it needs them, so a tool that
appears later needs no restart.

## Building

Requirements: `podman` (rootful), `curl`, `tar`, ~5 GB of disk. The build
fetches ~820 MB of QNAP GPL source, builds only three kernel modules in an
Ubuntu 20.04 container, and builds a static `qemu-img` in an Alpine one.

```sh
./build.sh                      # everything
MODEL=TS-X53II ./build.sh all   # pick the model whose kernel config to use

./build.sh gpl                  # just the QNAP kernel source
./build.sh modules              # just the vsock modules
./build.sh ovmf                 # just the UEFI firmware
./build.sh tools                # just the static tools (qemu-img, prlimit)
./build.sh qpkg                 # just the packages
```

Artifacts land in `out/`:

```
out/QNAP_LXD_VM_1.0.0.qpkg
out/qnap-lxd-vm-5.10.60-qnap.tar.gz
```

Run the local checks (script syntax, module vermagic, both payload layouts, the
cross-kernel guard, the shims) with:

```sh
tests/test-packaging.sh
```

Notes on the build:

* The kernel release is never hardcoded. It is read from the extracted QNAP
  tree (`scripts/kernel-release.sh`), asserted against every module built, and
  cross-checked against the NAS at install time.
* QNAP kernels are built with `CONFIG_MODVERSIONS` off, so symbol versions do
  not matter and only the vermagic string has to match. That is verified
  against `modinfo -F vermagic`, which also means the compiler version is
  irrelevant to ABI compatibility — Ubuntu 20.04/gcc 9 is used only because
  newer gcc versions do not build 5.10 kernel headers cleanly.
* Only the 5.10 tree and the per-model configs are unpacked from the GPL
  archive; the unrelated 4.14 tree is skipped.
* The static tools are built in Alpine with musl and `--static`/`-static`, so
  each is a single file (plus QEMU's `pc-bios/` directory of option ROMs) with
  no libraries to ship and nothing to match on the NAS. `qemu-img` and
  `qemu-system-x86_64` come from upstream QEMU (`x86_64-softmmu`, the tools,
  seccomp, linux-aio, libusb — the last two are what LXD's own QMP calls need,
  and configure would silently drop them); that step needs the network, because
  9.0 requires libfdt for `x86_64-softmmu` and meson fetches the pinned `dtc`
  subproject with `git` to build it. `prlimit` and `nice` are small implementations of our own
  (`containers/prlimit/prlimit.c`, `containers/nice/nice.c`): util-linux'
  `prlimit` is not an `--enable-` option (it only builds when its dependencies
  happen to be enabled), QTS has no `nice` in the daemon's `PATH`, and neither
  autotools nor coreutils would buy anything for a `setrlimit` or `setpriority`
  wrapper.
* The newest GPL drop on SourceForge is `5.2.3.20250218` while the NAS runs
  5.2.10. That is fine: the release string is still `5.10.60-qnap`.

## Installing

### QPKG (recommended)

If the previous `QNAP_Vsock` package is installed, remove it first (`sudo
/sbin/qpkg_cli -R QNAP_Vsock`) — this package has a different name, so QTS
installs both rather than replacing it.

Copy it to a share and run the installer. A `.qpkg` is a self-extracting
installer — `qbuild` puts a small shell header in front of the package, and that
header works out which volume to install into, extracts the payload and runs
QNAP's own `qinstall.sh` — so running it as root installs it, and that is also
how you get its output on the console:

```sh
scp out/QNAP_LXD_VM_1.0.0.qpkg admin@nas:/share/Public/
ssh admin@nas
sudo sh /share/Public/QNAP_LXD_VM_1.0.0.qpkg
```

Install it from a share rather than `/tmp`: the installer creates the package
directory next to the volume it selects.

In App Center you can instead use *Install Manually* and pick the file
([QNAP's procedure](https://www.qnap.com/en/how-to/faq/article/how-to-install-qnap-applications-qpkg-files-manually)).

`qpkg_cli` is how you control and inspect it afterwards: `--enable`, `--disable`,
`--stop`, `--start`, `-s` (status) and `-R QNAP_LXD_VM` (remove). If it ends up
disabled after installing it this way, `sudo /sbin/qpkg_cli --enable
QNAP_LXD_VM` starts it.

The package loads the modules and links the QEMU, qemu-img,
virtfs-proxy-helper and firmware files into place, and does the same on every
boot. It starts *after* Container Station, whose LXD
has by then already cached "no vsock", so **restart Container Station once** (or
reboot) and the VMs become available:

```sh
sudo /sbin/qpkg_cli --stop container-station && sudo /sbin/qpkg_cli --start container-station
```

See [LXD caches vsock support at daemon start](#lxd-caches-vsock-support-at-daemon-start)
for why, and for how to make the package start earlier if you would rather not.

### Plain tarball

```sh
scp out/qnap-lxd-vm-5.10.60-qnap.tar.gz admin@nas:/share/Public/
ssh admin@nas
cd /share/Public && tar xzf qnap-lxd-vm-5.10.60-qnap.tar.gz
cd qnap-lxd-vm && sudo ./install.sh
```

`install.sh` does not persist by itself. For that, wire `autorun/autorun.sh`
into a boot mechanism you control, or just use the QPKG. Note that QNAP's
`autorun.sh` normally lives on the flash DOM partition: this repository
deliberately does not touch it, because writing the wrong partition bricks the
NAS. `nas/autorun/autorun.sh` is the *body* to run, not a DOM installer.

`sudo ./uninstall.sh` unloads the modules and removes the two shims. The
firmware is left in `/usr/share/OVMF` on purpose; remove it by hand if you want.

## Verifying

```sh
lxc info                 # VM support should no longer be reported as missing
lxc init ubuntu:24.04 testvm --vm -c security.secureboot=false
lxc start testvm
lxc exec testvm -- uname -a      # proves the lxd-agent works over vsock
lxc delete -f testvm
```

Then the Home Assistant OS image. Use `-c security.secureboot=false` (as in the
original command) — that is also why only `OVMF_CODE.fd`/`OVMF_VARS.fd` are
required, though the `.ms` variants are shipped for when secure boot is wanted.

Two things mislead when looking at the resulting VM:

* Its console is the serial console, and a guest only prints there if its own
  boot configuration asks for it — silence after GRUB proves nothing. See
  "Console access to VMs" below.
* Its address is on the LXD bridge, not the NAS's own address, unless the NIC is
  bridged or macvlan. `lxc list` and the bridge's leases say where to point a
  browser; LXD's own bridge does not forward ports to the host by default. Until
  HAOS has been onboarded, its `:8123` hands off to a landing page on port 80
  (the redirect drops the port), so a single-port forward or SSH tunnel is not
  enough — after onboarding, `:8123` is the UI on its own.

Verified end to end with HAOS 18.3 (`haos_ova-18.3.qcow2`, the same release as
the `generic-x86-64` images): the shipped emulator and firmware boot it to a
login prompt on the serial console, on a q35 machine with a virtio-scsi disk.
The first boot then takes a while — the supervisor pulls its containers.

Diagnostics and logs:

```sh
# everything LXD checks, plus whether the running daemon holds a stale answer
sudo /share/*/.qpkg/QNAP_LXD_VM/qnap-lxd-vm.sh preflight
sudo /share/*/.qpkg/QNAP_LXD_VM/qnap-lxd-vm.sh status    # or nas/shared/qnap-lxd-vm.sh
cat /var/lib/qnap-lxd-vm/qnap-lxd-vm.log
/sbin/getcfg QNAP_LXD_VM Install_Path -f /etc/config/qpkg.conf
```

## Console access to VMs

LXD gives every VM a serial console and attaches it to `lxc console` (and to
`lxc start --console`). On this platform it is the *only* console you can look
at, because the graphical one needs SPICE (`docs/compatibility.md`). Whether a
guest prints anything there is up to the guest: the port is dead until the
guest's own boot configuration asks for it. To make a VM usable with `lxc
console`, give it `console=ttyS0` on the kernel command line, plus a getty on
that port if you want a login prompt rather than kernel output.

* **HAOS**: the command line lives in `cmdline.txt` on the EFI System Partition.
  The `ova` images ship `console=ttyS0 console=tty0`; the `generic-x86-64` images
  ship only `console=tty0` and stay silent after GRUB *even when they boot
  perfectly*. Either use the `ova` image, or edit `cmdline.txt` from inside HAOS
  (`/mnt/boot` is that partition: `mount -o remount,rw /mnt/boot`), or add the
  option for a single boot from GRUB's menu (`e`, append
  ` console=ttyS0,115200`, `Ctrl-X`).
* **Ubuntu and other Linux images**: append `console=ttyS0,115200` to
  `GRUB_CMDLINE_LINUX` in `/etc/default/grub` and run `update-grub` — the images
  LXD publishes already do this. For a login prompt, enable the getty on the
  port: `systemctl enable --now serial-getty@ttyS0`.
* **Windows** has no serial console by default, so there is nothing to configure
  — and nothing to see here either, since the graphical console needs SPICE.

```sh
lxc console haos             # Ctrl-a q detaches
lxc start haos --console     # attach while starting
```


## Shutting a VM down

LXD learns that a VM has stopped when QEMU exits, and QEMU exits when the guest
**powers off**. A guest that *halts* instead leaves QEMU running with its vCPU
parked: LXD keeps reporting the instance as running, `lxc start` refuses with
"The instance is already running", and `lxc console` shows a console with
nothing behind it.

* From the guest, use `poweroff`, not `halt` — in HAOS, `poweroff` in the root
  shell of the console powers the VM off properly.
* From LXD, `lxc stop` sends the ACPI power button (`system_powerdown`, see
  `qmp/commands.go` `Powerdown`) and waits for the guest to power off; if the
  guest does not act on it, that wait is what looks like a hang. `lxc stop
  --force` kills the QEMU process instead, after which LXD sees the instance as
  stopped.

## Sharing a host path with a VM

```sh
lxc config device add haos sys disk source=/share/somewhere
```

LXD prefers virtiofs for that, and `virtiofsd` is a separate Rust project this
package does not ship, so what gets used is the 9p fallback — and for that LXD
starts `virtfs-proxy-helper`, which is why this package ships it. Without it the
device fails to start:

```
Failed to setup virtfs-proxy-helper for device "sys": Required binary
"virtfs-proxy-helper" couldn't be found
```

Two more things have to line up, and the second is the one that catches people:

* **Nothing is mounted for you.** The share shows up in the guest as a 9p
  device whose tag is `lxd_<device name>`, and the guest has to mount it:
  `mount -t 9p -o trans=virtio,version=9p2000.L lxd_<device> /mnt/share`.
* **The guest needs 9p support**, which plenty of appliances do not have. Check
  inside the guest (`cat /proc/filesystems`, `zcat /proc/config.gz | grep -i 9p`,
  or `ls /lib/modules/$(uname -r)/kernel/fs/9p` for a modular driver). Home
  Assistant OS has it built in (`CONFIG_NET_9P_VIRTIO=y`, `CONFIG_9P_FS=y`), so
  the share can be mounted there — it has no virtiofs, which is the other reason
  the 9p fallback is the route that gets used.
* **The mount does not survive a reboot.** In HAOS, mount it where you need it
  (a writable path such as `/mnt/data/...`); for anything long-lived, or for
  Home Assistant and its add-ons to see the data, Home Assistant's own network
  storage is the cleaner route. There is no supported way to add a boot-time
  mount: HAOS's root filesystem is read-only, and it persists only the
  directories it bind-mounts from its data partition at boot (`/etc/udev/rules.d`,
  `/etc/modprobe.d`, `/etc/modules-load.d`, `/etc/sysctl.d`, `/etc/default`,
  `/etc/NetworkManager/system-connections`, ...) — `/etc/systemd/system` is not
  among them.

### Mounting the share automatically in Home Assistant OS

`/etc/udev/rules.d` *is* persisted, and a rule there can mount the share, which
is the trick the community uses for USB drives
([eklex's rule](https://gist.github.com/eklex/c5fac345de5be9d9bc420510617c86b5)).
What matters is `systemd-mount`: it creates a transient systemd unit, so the
mount happens in the host's mount namespace. A plain `mount` inside a udev rule
runs in udev's own namespace and does not show up anywhere.

Save this as `/etc/udev/rules.d/80-mount-lxd-share.rules` (the mount point has
to be under `/mnt/data`, which is writable and where HA's media folder lives, so
it appears in Home Assistant as `/media/HA`):

```
# The LXD 9p share (device "HA" -> tag lxd_HA) in HAOS's media folder.
SUBSYSTEM!="virtio", GOTO="lxd_share_end"
DRIVER!="9pnet_virtio", GOTO="lxd_share_end"

ACTION=="add", RUN{program}+="/usr/bin/systemd-run --no-block --collect --unit=lxd-share-mkdir --property=RequiresMountsFor=/mnt/data /usr/bin/mkdir -p /mnt/data/supervisor/media/HA"
ACTION=="add", RUN{program}+="/usr/bin/systemd-run --no-block --collect --unit=lxd-share-mount --property=RequiresMountsFor=/mnt/data --property=After=lxd-share-mkdir.service /usr/bin/mount -t 9p -o rw,access=client,trans=virtio,version=9p2000.L lxd_HA /mnt/data/supervisor/media/HA"

LABEL="lxd_share_end"
```

Two details make or break it. udev only runs rules on *events*, so
`udevadm control --reload-rules` alone does nothing for a device that already
exists — re-trigger it (`udevadm trigger --action=add --subsystem-match=virtio`)
or reboot. And the mount has to go through `systemd-run`: `systemd-udevd` runs
`RUN` programs in a private mount namespace, so a plain `mount` would vanish
with it, and `systemd-mount` probes its source with blkid, which a 9p tag is
not. The transient unit also waits for `/mnt/data` via `RequiresMountsFor=`, so
the mount point is never created on the read-only root. Check with
`systemctl status lxd-share-mount`, `mount | grep lxd_HA` and
`ls /mnt/data/supervisor/media/HA`.

* **Do not let the mount point end up on the root filesystem.** If the
  directory is created before `/mnt/data` is mounted, it lands on the read-only
  root and the mount will be hidden — the "empty folder in /media" that the
  gist's comments are full of. If that happens, mount from a transient service
  instead, which systemd can order after the data partition:
  `systemd-run --unit=lxd-share --property=RequiresMountsFor=/mnt/data -- /bin/sh -c 'mkdir -p /mnt/data/supervisor/media/HA && mount -t 9p -o rw,access=client,trans=virtio,version=9p2000.L lxd_HA /mnt/data/supervisor/media/HA'`
* **Home Assistant may need a nudge** to notice the new folder (restarting the
  relevant add-on, or HA itself, is the usual fix).

## LXD caches vsock support at daemon start

This is the trap worth knowing about. LXD asks each driver's `Info()` **once,
when the daemon starts**, and stores the answer forever: `lxd/daemon.go` builds
`state.InstanceTypes` from `driver.Info.Error`, and the create path in
`lxd/instance/instance_utils.go` just returns that cached error. It never
re-evaluates.

So a daemon that started *before* the modules existed keeps answering

```
Instance type "virtual-machine" is not supported on this server: Vsock support is missing (no /dev/vsock)
```

even though `/dev/vsock` is right there and the daemon can see it. That exact
message is always about this one check, so if you see it, nothing else is wrong
yet. Loading the modules by hand, or from a boot hook that runs late, is not
enough on its own. The next check in the same chain has its own message: without
the UEFI firmware you get `QEMU failed to run feature checks`, and the reason is
only in LXD's log:

```
level=error msg="Unable to run feature checks during QEMU initialization: QEMU premature exit: exit status 1
    (qemu: could not load PC BIOS '/usr/share/OVMF/OVMF_CODE.fd')"
```

### What this package does, and what it deliberately does not

It `insmod`s the modules from its own directory, at boot and on install: nothing
goes into `/lib/modules`, and there is no `depmod` or `modprobe` anywhere. The
only things it puts outside its directory are symlinks:

* `/usr/local/bin/qemu-system-x86_64` → Container Station's QEMU. LXD finds QEMU
  through `PATH`, and that is the only directory on the daemon's `PATH` that is
  not Container Station's own;
* `/usr/local/bin/qemu-img` → the static build in this package (nothing on the
  NAS ships one);
* the four `OVMF_*.fd` files in `/usr/share/OVMF` (LXD's default, overridable
  with `LXD_OVMF_PATH`), linked rather than copied so the data stays in the
  package.

It does **not** reorder `/etc/config/qpkg.conf` (QTS adds and maintains this
package's own section there), and it does **not** start or restart LXD.

### The consequence

Container Station is already running when this package is installed, so its LXD
has cached an answer from before the modules existed. That is why one restart is
always needed after installing:

```sh
qpkg_cli --stop container-station && qpkg_cli --start container-station
```

After a reboot it depends on which package gets there first — the next section
has the detail — so `preflight` is the thing to run: it reports every check LXD
makes, whether the running daemon can see `/dev/vsock`, whether `/usr/share/OVMF`
is in place, whether each tool resolves, and whether the daemon predates the
modules.

### Why nothing here reorders the QPKGs

Until QTS 5.1 the boot started QPKGs in the order of their sections in
`/etc/config/qpkg.conf` (QTS derived the `/etc/rcS.d/QS<n><name>` links from it),
which is what the community's SortMyQPKGs package rewrote the file for. On
**QTS 5.2 and later that no longer works** — from SortMyQPKGs' own
documentation:

> "SortMyQPKGs is no-longer effective on QTS 5.2.0 or-later, as these QTS
> versions have been modified to start QPKGs asynchronously. I can't force QTS
> to load QPKGs in a specific order anymore. QPKGs must now make use of the
> 'Dependency' key."

The `Dependency` key (QDK: *"colon-separated list of other QPKGs this one
depends on... evaluated by QTS itself"*) means "those packages start before me",
so it would have to be declared on `container-station` — which means editing its
section, i.e. `qpkg.conf` again.

So this package does not attempt it. Its `insmod` takes milliseconds while
Container Station is still bringing up its network, Docker and supervisor before
it reaches LXD, so in practice the modules are usually loaded in time; when they
are not, `preflight` says so and one command fixes it. If you would rather have
it guaranteed, the deterministic options are to let Container Station load the
modules itself (its start script has a `qts_insmod $KMODS` step and an empty
`$CS/kernel-module/` directory) or to use QNAP's own early hook, `autorun.sh` —
see `nas/autorun/`.

### The tarball path

`install.sh` cannot influence QPKG start order at all, so unless your boot hook
runs before Container Station, expect to restart it after each boot — or use the
QPKG.

## Repository layout

```
build.sh                 entry point: fetch GPL source, modules, firmware,
                         qemu-img, packages
scripts/                 host-side build steps (00 fetch GPL, 10 modules,
                         20 firmware, 25 qemu-img, 30 packages) and
                         in-container/ for the part that runs inside the
                         build container
containers/              the Ubuntu 20.04 module/QPKG build image (with QNAP's
                         QDK) and the Alpine images that build the static tools
                         (QEMU, plus prlimit/ and nice/ from our own C)
nas/                     everything that ships to the NAS
  shared/qnap-lxd-vm.sh   the only place that loads/verifies anything, and
                         the only place that links the tools into PATH;
                         used by both install paths
  shared/qemu-wrapper.sh the qemu-system-x86_64 LXD finds: drops the SPICE
                         arguments, then execs the real emulator
  install.sh             tarball path
  autorun/autorun.sh     boot hook body for the tarball path
qpkg/                    QPKG source (qbuild packages this)
docs/                    compatibility.md: every LXD 5.0.2 / QEMU / kernel /
                         QTS 5.2 disagreement, and how it is handled
tests/                   local checks, no NAS needed
  qemu-config-check.sh   run the built emulator against an LXD-generated
                         qemu.conf to catch missing devices or ROMs
```

`build/` and `out/` are generated and not tracked.

## License

The files in this repository are GPLv3; see [LICENSE](LICENSE).

The vsock kernel modules that ship in the package are a different case: they are
built from QNAP's own GPL-2.0 kernel source drop and remain under the GPLv2 of
that source, as the kernel's license requires. The QEMU,
`virtfs-proxy-helper`, OVMF and `qemu-img` binaries carry their upstream
licenses.
