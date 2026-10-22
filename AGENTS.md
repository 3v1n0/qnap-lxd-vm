# Working on qnap-lxd-vm

Notes for whoever (or whatever) works on this repository: why the code looks the
way it does, how the build is put together, and what the CI does. The README is
the user-facing document; this is the engineering one.

## The problem being solved

`lxc init ... --vm` on a stock QNAP NAS fails with:

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

Three more things LXD needs are also missing on a stock Container Station:
`qemu-system-x86_64` is not on the LXD daemon's `PATH` (the only QEMU is a
kata-static build under Container Station's own prefix), there is no UEFI
firmware at `/usr/share/OVMF`, which LXD uses for every x86 VM, and there is no
`qemu-img`, which LXD runs for all of its image work:

```
Failed creating instance from image: Failed reading image info "...rootfs":
    Failed to find executable "qemu-img": exec: "qemu-img": executable file not found in $PATH
```

None of that is the whole story: LXD 5.0.2, Container Station's QEMU, the 5.10
kernel and QTS 5.2 each disagree with the next in ways that surface one failing
`lxc` command at a time. Every one of them — with the message it produces, the
cause and what handles it — is written up in
[docs/compatibility.md](docs/compatibility.md).

## What LXD reaches for, and where it comes from

| Tool | Used for | Provided by |
| --- | --- | --- |
| `qemu-system-x86_64` | the VM itself | this package: a static QEMU built with seccomp, behind a wrapper |
| `qemu-img` | every image operation | this package (static) |
| `prlimit` | bounds `qemu-img`'s CPU and memory | this package (static) |
| `nice` | runs image conversion at low priority (`nice -n19 qemu-img convert`) | this package (static) |
| `virtfs-proxy-helper` | a VM's 9p shares (a disk device pointing at a host path) | this package (static) |
| `OVMF_CODE.fd`, `OVMF_VARS.fd` | UEFI firmware | this package |
| `modprobe`, `ip` | kernel modules, interfaces and routes | QTS |
| `nft` / `iptables` / `ebtables` | firewall | QTS (one of the three) |
| `apparmor_parser` | LXD's `qemu-img` profile | QTS, needed only when AppArmor is enabled |
| `dnsmasq` | LXD-managed networks only | Container Station / QTS |
| `virtiofsd` | the preferred way to share a host path with a VM | not shipped: LXD falls back to 9p, which needs `virtfs-proxy-helper` |
| `swtpm` | `tpm` devices, optional | only needed if you add one |
| `mkisofs` | cloud-init config drive, optional | only needed for a cloud-init disk device |
| `xz`, `zstd`, `gzip`, `bzip2`, `lzma` | compressed images | QTS, needed only for the matching image format |

`preflight` prints exactly this list with `present`/`MISSING`, so the answer to
"what else might be missing" is one command rather than one failed attempt per
tool. LXD resolves all of them through `PATH` when it needs them, so a tool that
appears later needs no restart.

## Why there is a wrapper around QEMU

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

## Version pins

`scripts/versions.sh` is the single source for the versions that determine the
build outputs; the scripts default from it and environment overrides win:

| pin | meaning |
| --- | --- |
| `QTS_GPL` | QNAP GPL source release to fetch |
| `KERNEL_MAJOR` | kernel series in the QNAP tree |
| `MODEL` | model whose `kernel_cfg` configures the tree (default `TS-X53II`) |
| `QEMU_VERSION` | emulator version, pinned deliberately — see below |
| `OVMF_UBUNTU_RELEASE` | Ubuntu release whose `ovmf` package provides the firmware |
| `BUILDER_UBUNTU` | Ubuntu release of the gcc-9 toolchain image |

The kernel *release* is never pinned: it is read back from the QNAP tree
(`scripts/kernel-release.sh`), asserted against every module built, and
cross-checked against the NAS at install time.

`QEMU_VERSION` (currently 9.0.3, against Container Station's 5.0.0) is not the
newest on purpose, because two later QEMU changes break LXD 5.0.2: 9.1 compares
the `O_DIRECT` bit of the descriptors LXD hands over (it opens VM disks without
it, then asks QEMU for it), and 9.2 rejects the string-typed QMP integers LXD
sends for `bootindex` and `vectors`. Bumping the pin means re-running
`tests/qemu-config-check.sh` against a real config, which makes both of those
calls.

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
./build.sh tools                # just the static tools
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

* QNAP kernels are built with `CONFIG_MODVERSIONS` off, so symbol versions do
  not matter and only the vermagic string has to match. That is verified against
  `modinfo -F vermagic`, which also means the compiler version is irrelevant to
  ABI compatibility — Ubuntu 20.04/gcc 9 is used only because newer gcc versions
  do not build 5.10 kernel headers cleanly.
* Only the 5.10 tree and the per-model configs are unpacked from the GPL
  archive; the unrelated 4.14 tree is skipped.
* The static tools are built in Alpine with musl and `--static`/`-static`, so
  each is a single file (plus QEMU's `pc-bios/` directory of option ROMs) with no
  libraries to ship and nothing to match on the NAS. `qemu-img` and
  `qemu-system-x86_64` come from upstream QEMU (`x86_64-softmmu`, the tools,
  seccomp, linux-aio, libusb — the last two are what LXD's own QMP calls need,
  and configure would silently drop them); that step needs the network, because
  9.0 requires libfdt for `x86_64-softmmu` and meson fetches the pinned `dtc`
  subproject with `git` to build it. `prlimit` and `nice` are small
  implementations of our own (`containers/prlimit/prlimit.c`,
  `containers/nice/nice.c`): util-linux' `prlimit` is not an `--enable-` option
  (it only builds when its dependencies happen to be enabled), QTS has no `nice`
  in the daemon's `PATH`, and neither autotools nor coreutils would buy anything
  for a `setrlimit` or `setpriority` wrapper.
* The firmware is the `ovmf` package of `OVMF_UBUNTU_RELEASE`, installed by apt
  inside its own image, so no download URL is hardcoded anywhere; upgrading is
  changing that pin.
* The newest GPL drop on SourceForge is `5.2.3.20250218` while the NAS runs
  5.2.10. That is fine: the release string is still `5.10.60-qnap`.

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

## CI

`.github/workflows/build.yml` runs `./build.sh`, the packaging checks, and the
config check on every push to `main`, on `v*` tags and on pull requests:

* **build** — the artifacts (`out/*.qpkg`, `out/*.tar.gz`) are uploaded as the
  `qnap-lxd-vm` artifact.
* **beta** — a push to `main` refreshes a rolling `beta` prerelease: created if
  missing, re-targeted otherwise, assets replaced with `--clobber`.
* **release** — a `v*` tag publishes a stable release, after asserting that the
  tag matches `QPKG_VER` in `qpkg/qpkg.cfg` (so `v1.0.0` for `QPKG_VER=1.0.0`;
  a bare `v1` is refused on purpose).

Caching is scoped to what does *not* depend on how we build:

* `build/src/gpl` — the downloaded QNAP tarballs, keyed on `scripts/versions.sh`
  only. A refactor of the fetch script does not invalidate them.
* `build/podman-graph`, `build/bin`, `build/firmware`, `build/qemu-datadir` —
  the container images and the third-party binaries they produce, keyed on
  `CACHE_TAG`, `scripts/versions.sh` and `containers/**`. The per-step guards in
  the build scripts skip whatever comes back intact.

The package itself, the modules and `build/ovmf`'s extract are regenerated on
every run — they depend on the current tree. `CACHE_TAG` (in the workflow env) is
the manual buster for base-image updates: distro images are pinned by tag, so a
distro update republishes layers under the same tag and cached images would keep
serving the old ones. Its restore keys are bump-scoped, so a forced update cannot
resurrect the previous images, while the GPL downloads stay cached.

Two ownership details matter because podman runs as root there: `build/` is
created by the runner (so the build scripts can `mkdir` into it), the
`podman-graph` directory is handed to the runner (so restoring the cache can
write into it), and `build/` is handed back to the runner after the build (so
the post-job cache save can read it).

`UBUNTU_MIRROR` (also in the workflow env) points the images' `apt-get` at
`http://azure.archive.ubuntu.com/ubuntu`, which is local to GitHub's runners.
It is deliberately not part of any cache key: it changes where packages come
from, not which versions are pinned.

## What the package does, and what it deliberately does not

It `insmod`s the modules from its own directory, at boot and on install: nothing
goes into `/lib/modules`, and there is no `depmod` or `modprobe` anywhere. The
only things it puts outside its directory are symlinks:

* `/usr/local/bin/qemu-system-x86_64` → this package's QEMU, through its wrapper
  (or Container Station's, if the payload is not there). LXD finds QEMU through
  `PATH`, and that is the only directory on the daemon's `PATH` that is not
  Container Station's own;
* `/usr/local/bin/qemu-img` → the static build in this package (nothing on the
  NAS ships one), plus `prlimit`, `nice` and `virtfs-proxy-helper`;
* the four `OVMF_*.fd` files in `/usr/share/OVMF` (LXD's default, overridable
  with `LXD_OVMF_PATH`), linked rather than copied so the data stays in the
  package.

It does **not** reorder `/etc/config/qpkg.conf` (QTS adds and maintains this
package's own section there), and it does **not** start or restart LXD — the
scripts and the QPKG only ever tell you to.

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
are not, `preflight` says so and one restart of Container Station fixes it. If
you would rather have it guaranteed, the deterministic options are to let
Container Station load the modules itself (its start script has a
`qts_insmod $KMODS` step and an empty `$CS/kernel-module/` directory) or to use
QNAP's own early hook, `autorun.sh` — see `nas/autorun/`.

## Repository layout

```
build.sh                 entry point: fetch GPL source, modules, firmware,
                         tools, packages
scripts/                 host-side build steps (00 fetch GPL, 10 modules,
                         20 firmware, 25 tools, 30 packages), versions.sh with
                         the pins, and in-container/ for the part that runs
                         inside the build container
containers/              the Ubuntu module/QPKG build image (with QNAP's QDK),
                         the ovmf image, and the Alpine images that build the
                         static tools (QEMU, plus prlimit/ and nice/ from our
                         own C)
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

## Conventions

* One atomic change per commit, with fixups placed in a rebase stall immediately
  after the commit they fix — not appended at the tip, which reorders badly when
  a fixup touches a file a *later* commit creates.
* Tag releases `v` + `QPKG_VER` (`v1.0.0`); the CI refuses anything else.
* Never hardcode the kernel release; derive it from the tree or `uname -r` and
  cross-check. Do not hardcode the architecture either.
* Do not add LXD start/restart logic to the scripts or the QPKG: tell the user
  what to run.
* Do not write to `/etc/config/qpkg.conf`, and do not touch the flash DOM
  partition (`autorun.sh`): the wrong write bricks the NAS.
* Build with podman, not Docker.

## License

The files in this repository are GPLv3; see [LICENSE](LICENSE).

The vsock kernel modules that ship in the package are a different case: they are
built from QNAP's own GPL-2.0 kernel source drop and remain under the GPLv2 of
that source, as the kernel's license requires. The QEMU,
`virtfs-proxy-helper`, OVMF and `qemu-img` binaries carry their upstream
licenses.
