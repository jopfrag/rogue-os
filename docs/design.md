# Design

This document captures architectural decisions and constraints. Verified environment
details live in `docs/development.md`.

## Goal

Build a **sealed CachyOS bootc OCI image from scratch** in this repository, and an automated,
disposable libvirt/QEMU/KVM test workflow that:

1. builds and pushes the image to a local OCI registry;
2. boots a CachyOS installer environment in a VM;
3. partitions/formats/mounts a disk;
4. runs `bootc install to-filesystem` (+ the current finalize step);
5. reboots into the installed CachyOS bootc system;
6. waits for and connects over SSH;
7. runs integration tests (including update and rollback);
8. collects diagnostics and destroys everything.

No `bootc-image-builder`. No prebuilt CachyOS bootc image as the base.

## Target architecture (fixed)

The image is a **sealed** bootc image:

- **composefs backend** (selected automatically by bootc because the image carries a UKI);
- bootloader **systemd-boot** (bootc selects this when `bootupd` is absent);
- a **Unified Kernel Image** at `/boot/EFI/Linux/<kver>.efi`; the raw `vmlinuz` and
  `initramfs.img` are removed from the final image (embedded in the UKI);
- **sealed**: the composefs digest is baked into the UKI kernel command line and enforced at
  boot via fs-verity (root filesystem must support fs-verity; ext4 is used).
- **Secure Boot disabled**, UKI **unsigned**. Sealing and Secure Boot are independent;
  upstream explicitly supports a sealed UKI without Secure Boot.

Build pattern (see `Containerfile.uki`, a read-only reference): build the rootfs; split the
kernel/initramfs with `bootc container split-kernel-and-rootfs`; build the UKI with
`bootc container ukify` (no signing); copy it into the final image.

Upstream reference: `bootc-dev/bootc` `docs/src/experimental-composefs.md`. The image must
include systemd-boot and must **not** include `bootupd`.

## Key constraints discovered (Task 1)

1. **libvirt is the host's `qemu:///system`.** The container must always pass
   `-c qemu:///system`; the default URI is session mode.

2. **QEMU runs as host uid 107.** VM disks must be on the host filesystem and owned by
   uid 107. They cannot live under `/home` (mode 0700). Chosen location: host `/var/tmp`,
   seen from the container as `/run/host/var/tmp`. Domain XML uses the host path
   (`/var/tmp/...`); the container uses `/run/host/var/tmp/...`.

3. **`/run/host` is idmapped.** Files written by QEMU (uid 107) are unreadable from the
   container. Therefore capture the serial console through a PTY
   (`<serial type='pty'>` + `virsh console` under `script`), not `type='file'`.

4. **The container cannot modify host networking or the host firewall** (no netns admin).
   The local registry will be served by the container on the libvirt bridge address
   (`192.168.122.1:<port>`). VM→host inbound TCP is blocked while firewalld runs; the
   workflow must verify reachability and report a clear diagnostic if it fails.

5. **UEFI via OVMF** is auto-selected by `<os firmware='efi'>`; firmware lives on the host.

## Installation model

- Simple GPT layout: EFI System Partition + root filesystem (f2fs; default).
- No LUKS, LVM, btrfs subvolumes, RAID, or Secure Boot. Secure Boot is out of scope; the
  image is sealed (composefs + fs-verity) but the UKI is unsigned.
- The root filesystem must support fs-verity. f2fs is the default (verified sealed); btrfs
  is the only other bootc-supported fs-verity filesystem; ext4 is built-in in the kernel
  but bootc's `supports_fsverity()` marks only ext4/btrfs/f2fs (f2fs requires the local
  bootc patch, see below).
- The installer environment owns partitioning, filesystem creation and mounting.
- The bootc image owns the OS contents, kernel, initramfs, systemd, and the UKI.
- Installation path: `bootc install to-filesystem <root>` then `bootc install finalize <root>`.
  With a UKI present, bootc uses the composefs backend and installs systemd-boot.

### f2fs is the default sealed root (verified; requires a small bootc patch)

The sealed (composefs + fs-verity) image installs and boots on an **f2fs** root, with
`/sysroot` genuinely f2fs and fs-verity enforced. Verified end-to-end (install, boot,
sealed smoke test, `bootc switch` update, `bootc rollback`) with the default path.

Two small, local changes are required because upstream bootc does not know f2fs (checked
against pinned 1.16.13 and current `main`):

- **bootc enum** (`bootc-f2fs.patch`, applied in `Containerfile`): add an `F2fs` variant to
  `Filesystem`, accept `"f2fs"` in `TryFrom<&str>`, and include `F2fs` in
  `supports_fsverity()`. This removes the `Unknown filesystem: f2fs` and *"does not support
  fs-verity"* rejections. (An extra `F2fs` arm in `baseline.rs`'s `mkfs` match is required
  for exhaustiveness; it is only exercised by `bootc install to-disk`, which this project
  does not use.)
- **dracut driver** (`Containerfile`): `add_drivers+=" f2fs "`. The CachyOS `f2fs.ko` is a
  loadable module (ext4 is `=y` built-in), so the UKI initramfs must carry it or the
  initramfs `sysroot.mount` fails ("Failed to mount Root Partition" → emergency mode).

The kernel-side support was already there: `linux-cachyos`'s `f2fs.ko` exports
`f2fs_verityops` / `f2fs_begin_enable_verity` / `f2fs_get_verity_descriptor`.

`f2fs-tools` (including `fsck.f2fs`) is added to the image for repair/resize parity, and
the default `00-cachyos.toml` / installer default / test harness default are all `f2fs`.

## bootc install requirements (Task 2, verified against bootc 1.16.12 + upstream docs)

Source: the installed `bootc` CLI, `docs/src/bootc-install.md`, `bootc-images.md`,
`initramfs.md`, and the `bootc-install-config` man page on `bootc-dev/bootc@main`.

### Install flow

`bootc install to-filesystem <ROOT_PATH>` installs to an externally prepared and mounted
root filesystem. The external installer owns partitioning, `mkfs`, and mounting.

**For the sealed (UKI) image the install is a self-install.** The installer runs
`bootc install to-filesystem /target` from inside the target image (privileged podman, no
`--source-imgref`). This is required: with `--source-imgref` bootc sets `target_rootfs=None`,
never inspects the image for a UKI, and defaults to the **ostree** backend, failing with
`Failed to find kernel in /usr/lib/modules, /usr/lib/ostree-boot or /boot`. As a self-install,
bootc finds the UKI in its own rootfs, sets `unified=true`, and auto-selects the **composefs
backend + systemd-boot**.

**Partitioning must use DPS type GUIDs.** The sealed UKI cmdline has no `root=` (bootc
rejects `--karg` with a UKI), so the initramfs locates root via
`systemd-gpt-auto-generator`. The root partition must therefore carry the architecture
DPS GUID (x86-64 root `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`); a generic `8300` root type
results in emergency mode.

The ESP must be mounted at `<ROOT_PATH>/boot/efi` (bootc installs systemd-boot there).

Example installer flow (what our `installer/stage/install-bootc.sh` does):

```
sgdisk --new=1:0:+512M --typecode=1:ef00 --new=2:0:0 --typecode=2:<DPS-root-guid> /dev/vda
mkfs.vfat -F32 /dev/vda1 ; mkfs.ext4 /dev/vda2
mount /dev/vda2 /target ; mount /dev/vda1 /target/boot/efi
podman run --privileged --pid=host -v /dev:/dev -v /target:/target <image> \
    bootc install to-filesystem --target-imgref <ref> --skip-finalize /target
# then (on the installer): fstrim, remount,ro; inject root SSH keys; unmount; poweroff
```

Required/important options:

- `--source-imgref <imgref>`: fetch from an explicit reference instead of self-install.
  Accepted formats per `containers-transports(5)`. **Not used for the sealed image** (it
  would select the ostree backend).
- `--target-imgref <imgref>`: image to fetch for subsequent updates (day-2).
- `--target-transport <transport>`: e.g. `registry` (default), `oci`, `oci-archive`,
  `containers-storage`.
- `--karg <arg>` (repeatable): kernel arguments. **Rejected for a UKI**
  (`Cannot use externally specified kernel arguments with UKI`); the cmdline is embedded in
  the UKI instead.
- `--root-mount-spec` / `--boot-mount-spec`: override mount specs; defaults derive the
  filesystem UUID. An empty `--root-mount-spec=""` enables DPS auto-discovery.
- `--root-ssh-authorized-keys <path>`: inject root SSH keys via `systemd-tmpfiles`
  (`/etc/tmpfiles.d/bootc-root-ssh.conf`). **Only implemented for the ostree backend**, so it
  has no effect on our composefs/sealed image (see "Durable root SSH key injection" below).
- `--bootloader <grub|grub-cc|systemd|none>`: bootloader selection (auto-derived; `systemd`
  for the composefs+UKI path).
- `--skip-finalize`: skip bootc's fstrim + read-only remount + fsfreeze. **Used for our
  installer**: fsfreeze on the container-bind-mounted target hangs, so the installer performs
  the finalization itself on the host side.
- `--composefs-backend` / `--allow-missing-verity`: select the composefs backend / relax
  fs-verity. We pass neither: the backend is derived from the UKI, and fs-verity stays
  enforced.
- `--generic-image`: install all bootloader types, skip firmware changes.
- `--stateroot <name>` (default `default`), `--composefs-backend`.

`bootc install finalize <ROOT_PATH>` is the penultimate step before unmounting; it runs
sanity checks and fixups. `bootc install print-configuration` emits JSON whose current key
is `root-fs-type` (suitable for `mkfs.$type`).

### Image requirements

- `LABEL containers.bootc=1`.
- Exactly one kernel: `/usr/lib/modules/$kver/vmlinuz`; initramfs at
  `/usr/lib/modules/$kver/initramfs.img`. `ls /usr/lib/modules` must resolve to one dir.
- No content in `/boot` inside the image; bootc copies kernel/initramfs to `/boot` itself.
- `/sysroot` directory (mode ~0755).
- `/ostree -> /sysroot/ostree` symlink (needed for `bootc container lint`).
- `/usr/lib/ostree/prepare-root.conf` with `[composefs] enabled = true` (the composefs backend
  also creates a minimal `/ostree` holding a compatibility symlink).
- **Sealed/UKI images additionally:** systemd-boot present (and `bootupd` absent); exactly one
  kernel with `vmlinuz`/`initramfs.img`; no pre-built UKI in the base image; the build
  generates the UKI; the final image carries `/boot/EFI/Linux/<kver>.efi` and no raw
  `vmlinuz`/`initramfs.img` (they are embedded in the UKI).
- `/usr/lib/bootc/install/00-<osname>.toml` sets the default root fs type
  (`[install.filesystem.root] type = "ext4"`), merged alphanumerically.
- `bootc container lint` validates these invariants and is run as the final build step.
- Image must be built so `bootc` is present and `bootc container lint` passes.

### Bootloader

The bootloader is installed by bootc during installation. For the **sealed composefs** image
in this project, bootc installs **systemd-boot** automatically because the image contains a
UKI and does **not** contain `bootupd`. (If `bootupd` were present, bootc's ostree backend
would instead require GRUB via bootupd.)

### Update / rollback

- `bootc upgrade` stages an update (visible as `staged` in `bootc status`), applied at
  shutdown; `bootc upgrade --apply` stages and reboots. With the composefs backend each
  version carries its own UKI (with its own embedded composefs digest).
- `bootc switch <ref>` changes the tracked image reference and stages the next boot.
- `bootc rollback` switches back to the previous deployment/UKI;
  `bootc rollback --apply` rolls back and reboots. A staged upgrade is discarded.
- `bootc status --json` reports `booted` / `staged` / `rollback` deployments and the image
  digests — the basis for our update/rollback verification tests.
- The local test registry is plain HTTP, so update tests write an `insecure = true` entry for
  `192.168.122.1:5000` into the guest's `/etc/containers/registries.conf.d/` before switching.

**Verified:** a v1 image installs, `bootc switch` to v2 stages a composefs/UKI deployment
(`bootType: Uki`, `bootloader: systemd`, `missingVerityAllowed: false`), reboot boots v2, and
`bootc rollback` returns to v1. `tests/vm/upgrade.sh` and `tests/vm/rollback.sh` automate
this (`make vm-update`, `make vm-rollback`).

## Reference implementations (Task 4)

The repository named in the original prompt, `bootc-crew/arch-bootc`, **no longer exists**
(404). It moved to **`bootcrew/arch-bootc`**, whose README states it is itself deprecated in
favour of **`bootcrew/mono`**. Current reference material:

- `bootcrew/mono/arch/Containerfile` + `shared/{bootc-rootfs.sh,initramfs.sh,build.sh}` — the
  maintained Arch Linux bootc image build. It builds bootc from source in a builder stage and
  installs into `archlinux:latest`.
- **`Containerfile.uki`** (in this repository, read-only) — the sealed composefs + UKI +
  systemd-boot build pattern. Do not modify; adapt into `Containerfile`.
- Notable practices copied from `bootcrew/mono` (adapted for CachyOS):
  - move pacman's `/var` DB/cache into `/usr/lib/sysimage`;
  - remove `NoExtract` rules so all locales/docs install;
  - build/install `bootc` from source;
  - dracut config: `hostonly=no`, `add_dracutmodules+=" ostree bootc "`;
  - `/usr/lib/tmpfiles.d/bootc-base-dirs.conf` for `/var` subdirs;
  - `prepare-root.conf` with composefs enabled;
  - `LABEL containers.bootc 1` and `RUN bootc container lint` last.
- The `bootcrew/mono` image installs via `bootc install to-disk --via-loopback`; this project
  requires `bootc install to-filesystem`, which the sealed composefs/UKI path supports.

## Repository structure (Task 5)

```
.
├── AGENTS.md, MEMORY.md, README.md
├── Containerfile          # CachyOS bootc image build (sealed: composefs + UKI + systemd-boot)
├── Containerfile.uki      # read-only reference for the UKI/composefs build
├── Makefile               # agent/developer entry points (thin wrappers)
├── .gitignore
├── docs/
│   ├── design.md          # architecture, decisions, constraints
│   └── development.md     # verified environment facts
├── installer/             # installer environment build + install logic
│   ├── Containerfile      # installer rootfs image (podman/skopeo/partition tools)
│   ├── iso/build-iso.sh   # squashfs + GRUB EFI + El Torito ISO assembly
│   └── stage/             # install-bootc.{sh,service}
├── tests/
│   ├── image/test-image.sh   # VM-less image validation
│   └── vm/                   # disposable-VM integration tests
│       ├── install.sh        # boot installer ISO, install to disk
│       ├── boot.sh           # boot installed disk, wait for SSH
│       ├── smoke.sh          # sealed-state/system checks over SSH
│       ├── upgrade.sh        # v1 -> v2 update test
│       ├── rollback.sh       # rollback test
│       └── run.sh            # end-to-end orchestrator
├── hack/                  # helper scripts (registry, VM lifecycle, diagnostics)
│   └── lib/{vm.sh,ssh.sh}    # VM lifecycle + SSH helpers
└── contrib/               # third-party attribution
```

The Makefile targets are thin wrappers over scripts in `hack/` and `tests/`. Targets that are
not implemented yet fail loudly via `hack/not-implemented.sh` rather than silently succeeding.

## Image build (Tasks 6-7, retargeted; implemented in Task 26)

> Note: Tasks 6-7 were first implemented for the **ostree backend** (split kernel + GRUB +
> bootupd). That path is blocked on CachyOS because bootc's ostree install requires `bootupd`,
> which is Fedora/RPM-centric (needs a shim and Fedora's `/usr/lib/efi` metadata). The project
> was retargeted to the **sealed composefs + systemd-boot + UKI** path, which avoids bootupd
> entirely and **is now implemented** in `Containerfile`.

`Containerfile` builds a sealed CachyOS bootc image against
`docker.io/cachyos/cachyos-v3:latest`. Stages:

1. a **bootc-builder** stage compiles `bootc` from source (pinned by `BOOTC_VERSION`); no
   bootupd is built;
2. a **rootfs** stage installs the base, kernel, `dracut`, filesystem tools, `skopeo`,
   `podman`, `openssh`, and `systemd-ukify`. `systemd-boot` needs no extra package: the
   CachyOS `systemd` package ships `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` and
   `bootctl`. **`bootupd` is deliberately absent.** It adds
   `/usr/lib/bootc/kargs.d/00-console.toml`, `/usr/lib/composefs/setup-root-conf.toml`
   (bind `/etc` and `/var`), enables composefs in `/usr/lib/ostree/prepare-root.conf`, sets
   up networking/systemd, and runs `bootc container lint`;
3. a **split** stage removes the kernel/initramfs from the rootfs via
   `bootc container split-kernel-and-rootfs`;
4. a **sealed-uki** stage builds the unsigned UKI with `bootc container ukify` (no signing
   options, and no `--allow-missing-verity`, so fs-verity is enforced);
5. the **final** image is the split rootfs plus the UKI at `/boot/EFI/Linux/<kver>.efi`.

Verified result: one UKI (~43 MiB) with cmdline
`console=tty0 console=ttyS0 rw composefs=<sha512>` (no `?` prefix → fs-verity enforced),
no raw `vmlinuz`/`initramfs.img`, no bootupd, and `bootc container lint` passing (13 checks,
1 pre-existing `chcon` warning).

Build-environment fixes retained from the ostree iteration: pacman `DisableSandbox` (needed
under rootless podman builds), `libselinux` + `ostree` at runtime (the copied `bootc` binary
links them), pacman state relocated to `/usr/lib/sysimage`, `/var` declared via tmpfiles,
and the `/var`/`/tmp` cleanup that satisfies bootc's lint.

**CachyOS mirror pin (workaround):** the base image's default mirrorlist lists the cdn77 CDN
first, which has recently served a mismatched `cachyos.db`/`.sig` pair; pacman does not fall
through past a bad signature. `Containerfile` pins `us.cachyos.org`/`at.cachyos.org` instead.
Remove the pin once cdn77 is consistent again. The base `cachyos-keyring` also lags the
rotated CachyOS signing key; if a future base image lacks it, the build must
`pacman-key --recv-keys 882DCFE48E2051D48E2562ABF3B607488DB35A47` before the first sync.

## Local registry

The registry (`hack/registry.sh`, `make registry-*`) runs `docker.io/library/registry:2` as a
podman container named `cachyos-bootc-registry` with `--network host`, so it binds directly on
the VM-facing bridge address `192.168.122.1:5000`. Data lives in `registry-data/` (gitignored).

The image is pushed as `192.168.122.1:5000/cachyos-bootc:test` (plain HTTP, `--tls-verify=false`)
so the VM can pull it by IP. Pushing as `localhost:...` would not be reachable from the VM.

Firewalld is assumed stopped (see `docs/development.md`): with it running, inbound TCP from the
libvirt bridge to a host-bound service is refused. A quick guest access check is part of the VM
workflow.

## Installer environment (Task 10)

A minimal custom CachyOS **live ISO** (`installer/`), built by `hack/build-installer.sh`:

1. `installer/Containerfile` builds the installer rootfs image
   (`localhost/cachyos-installer:test`) on the CachyOS base, adding kernel, dracut, `skopeo`,
   `podman`, `sgdisk`/`parted`, `mkfs.*`, `curl`, `dhcpcd`, and the auto-install unit.
2. The rootfs is exported and, in a builder container (`squashfs-tools`, `grub`, `xorriso`,
   `dracut`), packed into a squashfs and assembled into a UEFI-bootable ISO
   (`artifacts/cachyos-bootc-installer.iso`) using GRUB EFI + El Torito.

The ISO boots as a `dmsquash-live` image (`root=live:CDLABEL=CACHYOS_BOOTC rd.live.image`).
On boot, `install-bootc.service` runs `installer/stage/install-bootc.sh`, which:

- reads parameters from the kernel command line and/or an attached FAT volume labelled
  `BOOTCINSTAL` (`install.env`): `BOOTC_INSTALL_{IMGREF,DEVICE,ROOTFS,ACTION,FINALIZE,ROOT_SSH_KEY}`;
- partitions the target (`sgdisk`, GPT: 512M ESP with `ef00` + root with the **DPS x86-64 root
  GUID** `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`), creates vfat + ext4, mounts root at
  `/target` and the ESP at `/target/boot/efi`;
- pulls the image with `skopeo copy` (TLS disabled for the local registry) into
  containers-storage (overlay driver with `fuse-overlayfs`), then runs a **self-install**
  `bootc install to-filesystem --target-imgref <ref> --skip-finalize /target` from inside the
  image via `podman run --privileged --pid=host -v /dev:/dev -v <target>:/target`. bootc finds
  the UKI in its own rootfs and auto-selects the **composefs backend + systemd-boot**;
- (no `--karg`: rejected for a UKI) performs its own finalization (`fstrim`, `remount,ro`)
  because bootc's built-in finalize (`fsfreeze`) hangs on the bind-mounted target;
- optionally injects a root SSH key (write a tmpfiles drop-in to the target) and then
  reboots or powers off. (`bootc install finalize` is ostree-only and is skipped.)

The installer is transient; the same VM boots the installed sealed system from disk.

Verified: the ISO reaches multi-user, the self-install completes
(`Bootloader: systemd`, `Installation complete!`), and the installed system boots from disk
via systemd-boot/UKI with DPS root discovery and is reachable over SSH.

### Superseded: bootupd / ostree path

Earlier work installed `bootupd` (with an Arch path-adaptation patch) and the image used the
ostree backend. `bootc`'s ostree backend on x86_64 requires `bootupd` for bootloader
install, and bootupd's EFI payload expects a Fedora-style shim/`/usr/lib/efi` layout that
CachyOS does not provide. This is why the project moved to the sealed composefs + systemd-boot
+ UKI path, which does not use bootupd.

## Open questions to resolve in later tasks

- **(Resolved, Task 28) Durable root SSH key injection for the composefs backend.**
  `--root-ssh-authorized-keys` is ostree-only, so the installer writes a `d`+"f~" tmpfiles
  drop-in into the per-deployment `/etc` (`state/deploy/<digest>/etc/tmpfiles.d/`); the key
  survives `bootc switch` and rollback via the three-way `/etc` merge. No password is baked
  into the image.
- (Resolved) registry reachability: run the registry on the libvirt bridge address
  `192.168.122.1:5000` with firewalld treated as stopped; verified in Task 1.
