# Containerfile

This document explains the `Containerfile` that builds the sealed CachyOS bootc image.
The `Containerfile` itself is kept deliberately free of comments; the rationale for each
step lives here.

## Overview

The image is **sealed**:

- the **composefs** backend is used (selected automatically because the image carries a
  UKI);
- the kernel is packaged as a **Unified Kernel Image (UKI)** that carries the composefs
  digest on its kernel command line;
- **fs-verity enforcement is on**; the UKI is deliberately **unsigned** and **Secure Boot
  is not used**;
- the bootloader is **systemd-boot** and **bootupd is deliberately not installed** (bootc
  selects systemd-boot when bootupd is absent; installing bootupd would select the
  ostree/GRUB path instead).

The image is built from the CachyOS/Arch base image. This repository constructs the bootc
image itself; it does not derive from another bootc image.

The build has five stages:

1. **bootc-builder** — compile the `bootc` binary from source.
2. **rootfs** — CachyOS base + kernel/initramfs/systemd, laid out per bootc.
3. **split** — `bootc container split-kernel-and-rootfs` (kernel out of the rootfs).
4. **sealed-uki** — `bootc container ukify` builds the unsigned UKI.
5. **final** — the split rootfs plus the UKI at `/boot/EFI/Linux/<kver>.efi`.

References: the upstream bootc image requirements (`bootc-dev/bootc`,
`docs/src/bootc-images.md`).

## Global build arguments

- `BOOTC_VERSION` / `BOOTC_COMMIT` — the bootc source is pinned to an exact commit so builds
  are reproducible and immune to tag moves. `BOOTC_COMMIT` is the dereferenced commit for
  the `BOOTC_VERSION` annotated tag. **When bumping, update both.**
- `CACHYOS_MIRROR` — optional CachyOS mirror pin(s). Empty (the default) means "use the base
  image's own mirrorlist", which carries ~40 mirrors and fallback. Set it to space-separated
  `Server = ` URLs to pin a specific mirror, e.g. to work around a transient mismatch
  (upstream mirror flakiness is recurring). Each entry may use the pacman `$arch`/`$repo`
  placeholders.
- `KERNEL_PKGS` — kernel package(s); defaults to `linux-cachyos` (the CachyOS BORE kernel).
- `FIRMWARE_PKGS` — firmware packages. The default is a trimmed set for this development
  laptop (AMD 5500U "Green Sardine" iGPU + Intel AX200). Override with `--build-arg` to
  build a portable image (e.g. `FIRMWARE_PKGS="linux-firmware"`).

## Stage 1 — bootc-builder

Builds the `bootc` binary from source.

### Pacman sandbox and mirror pin

`sed -i '/^\[options\]/a DisableSandbox'` disables the base image's pacman sandbox. The
base image sandboxes downloads and package hooks (Landlock/seccomp), but that sandbox cannot
isolate the network inside a rootless podman build, which makes package hooks (`depmod`,
`dracut`, `systemd`) fail. Disabling it is required for the build.

The optional `CACHYOS_MIRROR` pin is applied here (and in every other stage that runs
pacman). When empty, the base image's default mirrorlist (with fallback) is used; this is
the robust default given recurring upstream mirror flakiness.

### Build dependencies

`libselinux` headers and `clang`/`libclang` are required by `selinux-sys`/bindgen;
`pkgconf`, `ostree` and `glibc` complete the native dependency set. `go-md2man`, `cmake`,
`jq`, `make`, `git` and `patch` are needed by the upstream build and our local patch.

`libselinux` is a **runtime** dependency of the produced binary (the copied `bootc` links it),
not merely a build-time header dependency, so it is installed wherever the binary is copied
(see stage 4, sealed-uki).

### Release profile tuning

The upstream Makefile builds the `release` profile, which keeps debug info and yields a
~330 MiB binary. The `CARGO_PROFILE_RELEASE_*` environment variables strip it and optimise
for size (~10 MiB) **without** changing the Makefile:

- `DEBUG=false`, `STRIP=true`, `LTO=true`, `OPT_LEVEL=s`, `CODEGEN_UNITS=1`, `PANIC=abort`.

### f2fs patch

`bootc-f2fs.patch` is copied into the build and applied after checkout. It is a small,
reviewable local patch that adds `f2fs` as an install filesystem. Upstream bootc (pinned
1.16.13 and current `main`) hardcodes `Filesystem { Xfs, Ext4, Btrfs }` and
`supports_fsverity() == ext4 | btrfs`, so without it `bootc install` rejects f2fs with
`Unknown filesystem: f2fs` (or *"does not support fs-verity"*). The patch adds an `F2fs`
variant, the `"f2fs"` parse arm, `F2fs` in `supports_fsverity()`, and the corresponding
exhaustiveness arm in `baseline.rs`. `baseline.rs` also handles the filesystem UUID
(`-U`) and now emits the label flag f2fs actually accepts (`-l`, not the generic `-L`),
which is required by `bootc install to-disk`. It applies cleanly to the pinned bootc
commit; it must be re-checked when `BOOTC_VERSION`/`BOOTC_COMMIT` are bumped. See the full
f2fs investigation and end-to-end verification results in this document's "Default root
filesystem" section below.

bootc's upstream `make bin` builds the binary and `make install` installs the systemd
units, dracut module, and baseimage reference content into `/output`, which later stages
copy from.

## Stage 2 — rootfs

The actual root filesystem of the image.

### Package set

Beyond the base system, the packages are:

- `${KERNEL_PKGS}` — the kernel (default `linux-cachyos`).
- `${FIRMWARE_PKGS}` — firmware (see the build argument above).
- `dracut` + `cpio` — initramfs generation.
- `ostree` + `libselinux` — bootc dependencies (`ostree` also provides the bootc backend
  data).
- Filesystem tools: `e2fsprogs`, `xfsprogs`, `btrfs-progs`, `f2fs-tools`, `dosfstools`.
- `systemd-ukify` — builds the UKI (pulls in `binutils`, `python-pefile`, …).
- `skopeo` + `podman` + `fuse-overlayfs` — image transport/pulling and the rootless overlay
  store.
- `systemd` (from `base`) also ships systemd-boot (`bootctl` + `systemd-bootx64.efi`), so no
  separate systemd-boot package is required. **`bootupd` is deliberately not installed.**
- `dbus` + `dbus-glib` + `glib2`, `shadow`, `openssh` — userspace.
- `bubblewrap` — required in the image by `bcvk`, the rootless test tool: `bcvk` re-execs
  itself through a bubblewrap namespace inside a container created from this image, and
  refuses to run if `bwrap` is absent.
- `efibootmgr` — used by `bootctl` to manage EFI boot variables during install.
- `cachyos-rate-mirrors` — keeps the installed system's mirrorlist fast and working.

### Relocating pacman state

Pacman's mutable state is moved out of `/var` so the image's `/var` is (nearly) empty, as
required by bootc's `var-tmpfiles` lint. On a bootc system `/var` is machine-local state and
only the image's initial `/var` content is provisioned; keeping the package database and
cache there would interfere. Adapted from `bootcrew/arch-bootc` and `bootcrew/mono`
(Apache-2.0).

The three standard writable locations (`DBPath`, `CacheDir`, `LogFile`) are relocated
explicitly rather than parsed out of `pacman.conf`, so this does not drift with the base.
Content is **moved** out of `/var` (not copied) so the image's `/var` stays empty as bootc
requires; any populated directory is re-created empty under `/usr/lib/sysimage`. The
`DownloadUser` directive is removed.

### bootc installation

`COPY --from=bootc-builder /output /` installs the bootc binary, systemd units, dracut
module, and baseimage reference content built in stage 1.

### Default root filesystem

`/usr/lib/bootc/install/00-cachyos.toml` sets the default root filesystem type for
`bootc install` and for external installers that consult
`bootc install print-configuration`. The composefs backend enforces fs-verity on a sealed
UKI, so the root filesystem must support it. **f2fs** is used (not ext4): it supports
fs-verity, and the sealed install on f2fs is verified via the manual
`bootc install to-filesystem` flow (see `INSTALL.md`). The rootless `bcvk to-disk` path has
a known intermittent finalize issue.
Because f2fs is a loadable module, it is forced into the initramfs via the dracut
`add_drivers` line below.

### Kernel command line defaults

`/usr/lib/bootc/kargs.d/00-console.toml` sets kernel arguments that `bootc container ukify`
bakes into the UKI:

- `console=tty0` / `console=ttyS0` — serial console so the VM test harness can capture early
  boot.
- `rw` — makes `/sysroot` writable so the `/etc` and `/var` bind mounts work without a
  workaround.

### Enabled services

- `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd` — networking and time.
- `sshd` — remote access.
- `systemd-boot-update.service` — copies the current `systemd-bootx64.efi` onto the ESP on
  each boot, keeping the boot *loader* in sync with the image across updates (bootc only
  manages the UKI, not the loader binary).
- `cachyos-rate-mirrors.timer` — periodically re-ranks mirrors so the installed system keeps
  a fast, working mirrorlist without manual intervention.
- `systemd-firstboot.service` is **masked** to avoid first-boot interactive prompts.

### Machine identity

`/etc/machine-id` is set to `uninitialized` (generated on first boot) and the timezone is set
to UTC so nothing prompts.

### SSH

- Root login is allowed **by key only** (`PermitRootLogin prohibit-password`,
  `PasswordAuthentication no`). The test harness injects an ephemeral public key at install
  time, so no password is needed.
- **Host keys are not baked into the image**: every install of a shared image would
  otherwise share the same host keys (MITM-able). Any pre-generated keys are removed and
  `sshdgenkeys.service` (Arch's host-key generator) creates machine-unique keys on first
  boot. `sshd` refuses to start until its host keys exist, so this also acts as a first-boot
  gate.

### Networking

- `/usr/lib/systemd/network/20-wired.network` brings up wired ethernet via DHCP.
  systemd-networkd ignores interfaces without a `.network` file; matching `Type=ether`
  catches `eth0`/`ens3`/etc. (including the QEMU virtio NIC).
- `/usr/lib/tmpfiles.d/resolv-conf.conf` points `/etc/resolv.conf` at systemd-resolved's
  stub, created via tmpfiles at boot (`resolv.conf` is bind-mounted by the container runtime
  during build).

### composefs /etc and /var bind mounts

`/usr/lib/composefs/setup-root-conf.toml` binds `/etc` and `/var` onto the writable
`/sysroot`. This is the composefs-native layout recommended by bootc; it keeps `/etc` and
`/var` writable under an otherwise read-only composefs root.

### Initramfs generation

The initramfs is generated with the `ostree` + `bootc` dracut modules. `hostonly=no` keeps
the image generic. `dracut` must be told the kernel version explicitly (its default targets
the running kernel, which is not the image's kernel).

`add_drivers+=" f2fs "` forces the loadable `f2fs.ko` into the initramfs. f2fs is the
default root filesystem and, unlike ext4 (built-in), it is a module; without it the
initramfs cannot mount `/sysroot` and boot drops to emergency mode.

There must be exactly one kernel: `bootc container split-kernel-and-rootfs`/`ukify` assume a
single kernel, and picking an arbitrary one would produce a UKI that does not match the
loaded modules. The build **fails loudly** if there is not exactly one kernel directory.

### Base root filesystem layout

Required by bootc (ostree symlink, `/var` as the writable tree, tmpfiles for `/var`
subdirectories, composefs prepare-root config). Adapted from `bootcrew/mono`
`shared/bootc-rootfs.sh` (Apache-2.0).

- `/boot`, `/home`, `/root`, `/usr/local`, `/srv`, `/opt`, `/mnt` are removed and recreated
  as symlinks into `/var` (or `/sysroot`), because bootc treats `/var` as the writable,
  machine-local tree.
- `/usr/lib/tmpfiles.d/bootc-base-dirs.conf` declares the `/var` subdirectories so they are
  recreated on each boot.
- `/usr/lib/ostree/prepare-root.conf` enables composefs.

### Normalizing /var and /tmp

bootc expects:

- every directory in `/var` to have a matching systemd tmpfiles.d entry, so it is recreated
  on each boot instead of only being provisioned from the image;
- `/var` to contain no generated files (build artifacts are not allowed on a bootc system);
- `/run` and `/tmp` to be empty (they are tmpfs at runtime).

`bootc-cachyos-var.conf` declares the `/var` tree. Then the relocated pacman cache/log are
removed, known generated files are removed, `/run` (except `secrets` and `.containerenv`)
and `/tmp` are emptied, and `/var/cache` and `/var/log` are re-created. This satisfies the
`var-tmpfiles`, `var-log`, and `nonempty-run-tmp` lints.

### Version marker

`IMAGE_VERSION` (default `1`) is written to `/usr/lib/bootc-image-version` and symlinked from
`/etc/bootc-image-version`, and is also recorded as the OCI label
`org.cachyos.bootc.image-version`. It lets us build distinguishable vN images from the same
Containerfile for update/rollback testing; because the marker lives in `/usr` (part of the
immutable composefs image), a v1→v2 update changes the composefs digest and the deployment
visibly. Distinct versions therefore get distinct composefs digests. The default `1` means a
plain `podman build` is a valid v1. Build versioned images with
`podman build --build-arg IMAGE_VERSION=N -t rogue:vN -f Containerfile .`.

### Lint

`bootc container lint --fatal-warnings --skip runtime-deps` validates the rootfs against
bootc's own invariants before sealing. Lint only makes sense here, on the state that carries
a kernel; the split and sealed stages remove it.

- `--fatal-warnings` turns every warning into a build error, so regressions in the `/var`
  layout (`var-tmpfiles`/`var-log`) or other lints cannot silently pass again.
- `--skip runtime-deps` allows the one warning we deliberately accept: the missing `chcon`.
  Arch/CachyOS has no SELinux and `chcon` is only provided by the conflicting
  `coreutils-uutils`, so it is intentionally absent and `runtime-deps` is skipped in both
  the rootfs-stage and final-stage lints.

## Stage 3 — split

`bootc container split-kernel-and-rootfs --rootfs / --output /kernel` splits the
kernel/initramfs out of the rootfs. The UKI embeds them, so the sealed image must not also
carry a raw `vmlinuz`/`initramfs.img` (bootc reads the UKI from `/boot/EFI/Linux` and treats
it as the single kernel).

## Stage 4 — sealed-uki

Builds the UKI.

### Packages

`systemd-ukify` is required. `bootc` is copied from the builder so the same pinned version is
used; the bootc binary links `libselinux` at runtime, so `libselinux` must be installed here
as well (with `ostree`).

### Building the UKI

`bootc container ukify` computes the composefs digest of the rootfs and bakes it (along with
`kargs.d`) into the UKI command line. Sealing is left on: **`--allow-missing-verity` is not
passed**. No `--signtool`/`--secureboot-*` is passed, so the UKI stays **unsigned** and
Secure Boot is not used.

The `split` stage is mounted into this stage (`/target` read-write for the rootfs,
`/kernel` for the extracted kernel) so `ukify` can read both.

## Stage 5 — final

The final sealed image is the split rootfs plus the UKI copied to `/boot/EFI/Linux/`.

- `LABEL containers.bootc=1` marks it as a bootc image.
- `LABEL org.cachyos.bootc.image-version="${IMAGE_VERSION}"` records the image version in
  the OCI metadata.

The final lint re-validates the split image because the kernel was removed and the UKI added
by the split/ukify steps; this guards against those steps introducing drift. The same
`--fatal-warnings --skip runtime-deps` rationale as the rootfs-stage lint applies.
