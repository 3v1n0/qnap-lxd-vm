# qnap-lxd-vm

Run LXD virtual machines on a QNAP NAS.

Container Station's LXD cannot create or start `--vm` instances on a stock NAS:
QNAP's kernel is built without the vsock stack, and Container Station ships
neither a usable QEMU, nor `qemu-img`, nor UEFI firmware. This package supplies
all of it — the three missing kernel modules, built against QNAP's own kernel
source, a static QEMU with seccomp, the UEFI firmware, and the small helpers LXD
looks for on `PATH` — so `lxc init … --vm` and `lxc start` just work.

Built and verified against a **TS-X53II running QTS 5.2.10 (kernel
5.10.60-qnap)**, including booting Home Assistant OS 18.3 end to end. Nothing
here is specific to that model; the kernel config to use is selectable.

## Installing

Download `QNAP_LXD_VM_1.0.0.qpkg` from the
[releases](https://github.com/3v1n0/qnap-lxd-vm/releases) (the `beta` release
always has the newest build of `main`) and install it from a share, as root:

```sh
scp QNAP_LXD_VM_1.0.0.qpkg admin@nas:/share/Public/
ssh admin@nas
sudo sh /share/Public/QNAP_LXD_VM_1.0.0.qpkg
```

A `.qpkg` is a self-extracting installer, so running it installs the package and
shows you its output. In App Center you can instead use *Install Manually* and
pick the file ([QNAP's
procedure](https://www.qnap.com/en/how-to/faq/article/how-to-install-qnap-applications-qpkg-files-manually)).
Afterwards `qpkg_cli` controls it: `--enable`, `--disable`, `--stop`, `--start`,
`-s` for status and `-R QNAP_LXD_VM` to remove. If it comes up disabled,
`sudo /sbin/qpkg_cli --enable QNAP_LXD_VM` starts it.

If you still have the previous `QNAP_Vsock` package installed, remove it first
(`sudo /sbin/qpkg_cli -R QNAP_Vsock`): the name changed, so QTS would keep both.

The package loads the modules and links the QEMU, `qemu-img`,
`virtfs-proxy-helper` and firmware files into place, and does the same on every
boot. It starts *after* Container Station, whose LXD has by then already decided
there is no vsock support, so **restart Container Station once** (or reboot):

```sh
sudo /sbin/qpkg_cli --stop container-station && sudo /sbin/qpkg_cli --start container-station
```

### From the tarball instead

```sh
scp qnap-lxd-vm-5.10.60-qnap.tar.gz admin@nas:/share/Public/
ssh admin@nas
cd /share/Public && tar xzf qnap-lxd-vm-5.10.60-qnap.tar.gz
cd qnap-lxd-vm && sudo ./install.sh
```

`install.sh` does not survive reboots by itself: wire `autorun/autorun.sh` into a
boot mechanism you control (see `nas/autorun/`), or use the QPKG. `sudo
./uninstall.sh` unloads the modules and removes the shims; the firmware is left
in `/usr/share/OVMF` on purpose.

## Checking it works

```sh
lxc info                 # VM support should no longer be reported as missing
lxc init ubuntu:24.04 testvm --vm -c security.secureboot=false
lxc start testvm
lxc exec testvm -- uname -a      # proves the lxd-agent works over vsock
lxc delete -f testvm
```

Use `-c security.secureboot=false`: most images, Home Assistant OS included, are
not signed for secure boot.

Diagnostics, if something is off:

```sh
sudo /share/*/.qpkg/QNAP_LXD_VM/qnap-lxd-vm.sh preflight   # every check LXD makes
sudo /share/*/.qpkg/QNAP_LXD_VM/qnap-lxd-vm.sh status
cat /var/lib/qnap-lxd-vm/qnap-lxd-vm.log
```

`preflight` reports whether each tool resolves, whether `/dev/vsock` and
`/usr/share/OVMF` are in place, and whether the running LXD predates the modules
— which is the usual reason a VM still looks unsupported after installing.

## Using VMs

### Console

`lxc console <vm>` (and `lxc start <vm> --console`) attaches to the VM's serial
console, which on this platform is the only one there is — the graphical console
needs SPICE, which is not built here. A guest only prints there if its own boot
configuration asks for it, so silence after GRUB proves nothing:

* **Home Assistant OS**: the command line lives in `cmdline.txt` on the EFI
  System Partition. The `ova` images ship `console=ttyS0 console=tty0`; the
  `generic-x86-64` images ship only `console=tty0` and stay silent after GRUB
  even when they boot. Either use the `ova` image, or edit `cmdline.txt` from
  inside HAOS (`mount -o remount,rw /mnt/boot`), or add the option for a single
  boot from GRUB's menu (`e`, append ` console=ttyS0,115200`, `Ctrl-X`).
* **Ubuntu and other Linux images**: append `console=ttyS0,115200` to
  `GRUB_CMDLINE_LINUX` in `/etc/default/grub` and run `update-grub`; for a login
  prompt, `systemctl enable --now serial-getty@ttyS0`. The images LXD publishes
  already do this.

`Ctrl-a q` detaches from a console.

### Shutting down

LXD learns a VM has stopped when QEMU exits, and QEMU exits when the guest
**powers off**. A guest that *halts* leaves QEMU running with its vCPU parked:
LXD keeps saying the instance is running, `lxc start` refuses, and the console
has nothing behind it.

* In the guest, use `poweroff`, not `halt`.
* From LXD, `lxc stop` sends the ACPI power button and waits — if the guest
  never acts on it, that wait looks like a hang. `lxc stop --force` kills QEMU
  instead.

### Reaching a VM on the network

A VM gets its address from the LXD bridge, not from the NAS, unless you give it
a bridged or macvlan NIC. `lxc list` and the bridge's leases say where to point a
browser. Note that HAOS's `:8123` hands off to a landing page on port 80 until it
has been onboarded, so a single-port forward or SSH tunnel is not enough; after
onboarding, `:8123` is the UI on its own.

### Sharing a host path with a VM

```sh
lxc config device add haos sys disk source=/share/somewhere
```

The share appears in the guest as a 9p device, tagged `lxd_<device name>`, and
the guest has to mount it:

```sh
mount -t 9p -o trans=virtio,version=9p2000.L lxd_sys /mnt/sys
```

The guest needs 9p support of its own (HAOS has it built in). The mount does not
survive a reboot, and for anything long-lived — or for Home Assistant and its
add-ons to see the data — HA's own network storage is the cleaner route.

## License

GPLv3; see [LICENSE](LICENSE). The kernel modules built from QNAP's GPL-2.0
kernel source drop stay under that source's GPLv2.

---

How this is built, why each piece exists, the full list of LXD/QEMU/kernel/QTS
incompatibilities and what handles them: see [AGENTS.md](AGENTS.md) and
[docs/compatibility.md](docs/compatibility.md).
