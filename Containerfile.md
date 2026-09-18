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
- **fs-verity enforcement is on**;
- the UKI and `systemd-boot` are **signed for Secure Boot when signing keys are supplied at
  build time**, and the UKI carries a **signed TPM2 PCR policy** for disk-encryption
  unlock; without keys the build produces an unsigned UKI and Secure Boot is not used;
- the bootloader is **systemd-boot** and **bootupd is deliberately not installed** (bootc
  selects systemd-boot when bootupd is absent; installing bootupd would select the
  ostree/GRUB path instead).

The image is built from the CachyOS/Arch base image. This repository constructs the bootc
image itself; it does not derive from another bootc image.

After a shared `cachyos-base` stage (the base image plus the pacman sandbox/mirror
fixup, so it is not repeated per stage), the build has five stages:

1. **bootc-builder** — compile the `bootc` binary from source.
2. **rootfs** — CachyOS base + kernel/initramfs/systemd, laid out per bootc.
3. **split** — `bootc container split-kernel-and-rootfs` (kernel out of the rootfs).
4. **sealed-uki** — `bootc container ukify` builds the UKI, optionally signing it for
   Secure Boot and with a TPM2 PCR policy.
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
- `KERNEL_PKGS` — kernel package(s); defaults to `linux-cachyos-server-lto` (the CachyOS
  server kernel, Clang ThinLTO build: stock EEVDF, 300 Hz, lazy preemption, no BORE/Cachy
  sauce).
- `FIRMWARE_PKGS` — firmware packages. The default is `linux-firmware amd-ucode`: the full
  firmware set (so the image is not tied to one machine's GPU/NIC) plus AMD CPU microcode.
  Override with `--build-arg` (e.g. `intel-ucode`) for a different CPU vendor.
- `TEST_PKGS` — test-only packages. Defaults to empty; `bcvk` needs `bubblewrap` inside the
  image, so the `Justfile` passes `--build-arg TEST_PKGS=bubblewrap`, while production
  builds leave it empty and ship without `bwrap`.

## Optional signing secrets

Signing is opt-in via Podman build secrets. A plain `podman build` produces the unsigned
image; supplying secrets produces a signed one. See "Disk encryption and Secure Boot" below
for the full rationale.

- `db_key` / `db_cert` — db private key and certificate (PEM). Signs `systemd-boot` (in
  `rootfs`) and the UKI (in `sealed-uki`).
- `pcr_key` / `pcr_pub` — PCR-policy private key and matching public key (PEM). Used by
  `ukify` to embed the `.pcrsig`/`.pcrpkey` sections.

The Secure Boot enrollment material (`PK.auth`, `KEK.auth`, `db.auth`) is **not** generated
at build time. Instead, pre-made `.auth` files are committed to the repository under
`root/usr/lib/bootc/install/secureboot-keys/auto/` and copied into the image via the
existing `COPY root /`. Regenerate them when the keys change.

> **Consistency requirement:** `db_cert` **must match** the certificate baked into `db.auth`.
> The firmware verifies `systemd-boot` and the UKI against the cert inside `db.auth`; if
> `db_cert` differs, the image is signed but unbootable. Regenerate `db.auth` whenever
> `db_key`/`db_cert` are rotated.

Because BuildKit does not fold secret contents into the layer cache key, a signed build
should be run with `--no-cache` (or a bumped build arg) to avoid reusing a stale unsigned
layer:

```sh
podman build --no-cache \
  --secret id=db_key,src=./db.key \
  --secret id=db_cert,src=./db.crt \
  --secret id=pcr_key,src=./pcr.key \
  --secret id=pcr_pub,src=./pcr.pub \
  -t ghcr.io/jopfrag/rogue:latest -f Containerfile .
```

## Stage 1 — bootc-builder

Builds the `bootc` binary from source.

### Pacman sandbox and mirror pin

`sed -i '/^\[options\]/a DisableSandbox'` disables the base image's pacman sandbox. The
base image sandboxes downloads and package hooks (Landlock/seccomp), but that sandbox cannot
isolate the network inside a rootless podman build, which makes package hooks (`depmod`,
`dracut`, `systemd`) fail. Disabling it is required for the build.

Both the `DisableSandbox` edit and the optional `CACHYOS_MIRROR` pin live in one dedicated
first stage, `cachyos-base`, and `bootc-builder`, `rootfs` and `sealed-uki` are all based on
it. This applies them exactly once instead of repeating the `RUN` in every pacman-using
stage, and lets those stages share the layer. When `CACHYOS_MIRROR` is empty, the base
image's default mirrorlist (with fallback) is used; that is the robust default given
recurring upstream mirror flakiness.

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

The Makefile hardcodes the in-tree `target/` path (so `CARGO_TARGET_DIR` cannot be
used), so the build step creates `ln -s /build/target /tmp/bootc/target`; cargo writes
through the symlink into the cache mount, and `rm -rf /tmp/bootc` later only unlinks it.
The bootc compile is already reused from the layer cache while nothing upstream changes,
but on a `BOOTC_VERSION`/`BOOTC_COMMIT`/patch bump the cargo cache makes the rebuild
incremental instead of a cold ~15 minute compile.

### f2fs patch

`bootc-f2fs.patch` is copied into the build and applied after checkout. It is a small,
reviewable local patch that adds `f2fs` as an install filesystem. Upstream bootc (pinned
1.16.13 and current `main`) hardcodes `Filesystem { Xfs, Ext4, Btrfs }` and
`supports_fsverity() == ext4 | btrfs`, so without it `bootc install` rejects f2fs with
`Unknown filesystem: f2fs` (or *"does not support fs-verity"*). The patch adds an `F2fs`
variant, the `"f2fs"` parse arm, `F2fs` in `supports_fsverity()`, and the corresponding
exhaustiveness arm in `baseline.rs`. `baseline.rs` also handles the filesystem UUID
(`-U`) and now emits the label flag f2fs actually accepts (`-l`, not the generic `-L`),
which is required by `bootc install to-disk`, and passes the f2fs mkfs options
`-i -O extra_attr,inode_checksum,sb_checksum,verity` (see "Default root filesystem"). It
applies cleanly to the pinned bootc commit; it must be re-checked when
`BOOTC_VERSION`/`BOOTC_COMMIT` are bumped. See the full f2fs investigation and end-to-end
verification results in this document's "Default root filesystem" section below.

bootc's upstream `make bin` builds the binary and `make install` installs the systemd
units, dracut module, and baseimage reference content into `/output`, which later stages
copy from.

## Stage 2 — rootfs

The actual root filesystem of the image.

### Package set

Beyond the base system, the packages are:

- `${KERNEL_PKGS}` — the kernel (default `linux-cachyos-server-lto`).
- `${FIRMWARE_PKGS}` — firmware (see the build argument above).
- `dracut` + `cpio` — initramfs generation.
- `ostree` + `libselinux` — bootc dependencies (`ostree` also provides the bootc backend
  data).
- `cryptsetup`, `tpm2-tss`, `tpm2-tools` — LUKS root and TPM2 unlock: `cryptsetup` provides
  the userspace tools and `libcryptsetup`, `tpm2-tss` the TPM2 stacks, and `tpm2-tools` the
  `tpm2` binary required by dracut's `tpm2-tss` module (see "Initramfs generation").
- Filesystem tools: `e2fsprogs`, `xfsprogs`, `btrfs-progs`, `f2fs-tools`, `dosfstools`.
- `systemd-ukify` — builds the UKI (pulls in `binutils`, `python-pefile`, …).
- `skopeo` + `podman` + `fuse-overlayfs` — image transport/pulling and the rootless overlay
  store.
- `systemd` (from `base`) also ships systemd-boot (`bootctl` + `systemd-bootx64.efi`), so no
  separate systemd-boot package is required. **`bootupd` is deliberately not installed.**
- `dbus` + `dbus-glib` + `glib2`, `shadow`, `openssh` — userspace.
- `ansible-core` — provides `ansible-pull` for local configuration management (see
  "ansible-pull"). The full `ansible` metapackage (collections bundle) is deliberately not
  installed.
- `${TEST_PKGS}` — test-only packages. `bcvk` (the rootless test tool) re-execs itself
  through a bubblewrap namespace inside a container created from this image, and refuses to
  run if `bwrap` is absent; the `Justfile` therefore builds with
  `--build-arg TEST_PKGS=bubblewrap`. The default is empty, so production images do not
  ship `bubblewrap`.
- `efibootmgr` — used by `bootctl` to manage EFI boot variables during install.
- `nftables` — netfilter userspace tools (a `podman`/netavark dependency). The package's
  stock `/etc/nftables.conf` is left in place, but `nftables.service` is **not** enabled:
  its default-drop `forward` chain blocks rootful container egress and its input chain has
  no container-bridge rule (container→host DNS). The image therefore ships without an
  active host firewall.
- `smartmontools` + `sysstat` + `lm_sensors` — health telemetry for a headless server. The
  `smartd` and `sysstat` services are enabled (sysstat pulls in its collect/summary/rotate
  timers); `lm_sensors` is installed but its service is left off because it needs a
  machine-specific `sensors-detect` run.
- `irqbalance` — spreads IRQs on multi-core hosts (`irqbalance.service`).
- `jq` — used by the staged-update auto-reboot helper (see "Unattended updates").

`cachyos-rate-mirrors` is deliberately **not** installed: it is a desktop feature that
re-ranks and rewrites the pacman mirrorlists, which a sealed bootc server does not use for
updates (bootc pulls OCI images).

The CachyOS base image also ships `base-devel` (the full compiler/toolchain metapackage).
A sealed server image never compiles anything, so it is removed with
`pacman -Rns base-devel`. pacman keeps the toolchain dependencies that other installed
packages still need (`pkgconf` for `dracut`, `binutils` for `systemd-ukify`, `which` for
`ostree`). `sudo` and `diffutils` are not build tools but are only pulled in as
`base-devel` dependencies, so they are re-installed explicitly rather than silently
dropped.

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

### Static files (`root/`)

Every static file the image adds is stored under `root/` in the build context, mirroring its
absolute path (e.g. `root/usr/lib/systemd/network/20-wired.network` →
`/usr/lib/systemd/network/20-wired.network`), and installed with a single `COPY root /`.
This keeps the `Containerfile` to commands instead of heredocs/`printf` and makes the
configuration reviewable as ordinary files. `COPY` preserves file modes, which matters for
the executable `/usr/libexec/bootc-auto-reboot` (mode `0755`, tracked by git).

The tree provides: the bootc install filesystem config and kargs, the auto-reboot
helper/service/timer, the composefs drop-ins for the upstream update units, the
SSH hardening drop-in, the networkd config, the `resolv.conf`
and `/var` tmpfiles, the composefs `setup-root-conf.toml`, the dracut config, and
`prepare-root.conf`.

Only genuinely dynamic content stays in `RUN`: `/etc/machine-id`, the `/etc/localtime`
symlink, the bootc image-version marker, and the base-filesystem relayout/symlinks.

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

`bootc install` formats f2fs with `-i -O extra_attr,inode_checksum,sb_checksum,verity`
(mkfs options, not mount options):

- `-i` — extended node bitmap (more inodes).
- `extra_attr,inode_checksum,sb_checksum` — let `fsck.f2fs` detect/repair more corruption.
- `verity` — sets the `F2FS_FEATURE_VERITY` superblock bit. This matters on current
  kernels: `f2fs_ioc_enable_verity` (the `FS_IOC_ENABLE_VERITY` handler) returns
  `-EOPNOTSUPP` unless that bit is set, and upstream bootc only passes `-O verity` for
  ext4. The patch extends it to f2fs so fs-verity can be enabled.

### Kernel command line defaults

`/usr/lib/bootc/kargs.d/00-console.toml` sets kernel arguments that `bootc container ukify`
bakes into the UKI:

- `console=tty0` / `console=ttyS0` — serial console so the VM test harness can capture early
  boot.
- `rw` — makes `/sysroot` writable so the `/etc` and `/var` bind mounts work without a
  workaround.
- `rootflags=noatime,gc_merge,atgc` — f2fs mount options for the root filesystem (there is
  no fstab): `noatime` suppresses atime writes (and implies `nodiratime`), `gc_merge` lets
  background GC absorb foreground GC requests, and `atgc` enables age-threshold GC. `atgc`
  cannot be toggled on remount without `rw`/`rootflags`, which the `rw` above provides.

### Enabled services

- `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd` — networking and time.
- `sshd` — remote access.
- `systemd-boot-update.service` — copies the current `systemd-bootx64.efi` onto the ESP on
  each boot, keeping the boot *loader* in sync with the image across updates (bootc only
  manages the UKI, not the loader binary).
- `bootc-fetch-apply-updates.timer` + `bootc-auto-reboot.timer` — unattended updates and
  maintenance-window reboots (see "Unattended updates and reboots").
- `fstrim.timer` — periodic TRIM for the f2fs root.
- `smartd.service`, `sysstat.service`, `irqbalance.service` — telemetry and IRQ balancing.
- `ansible-pull.timer` — periodic pull-based configuration (see "ansible-pull").
- `systemd-firstboot.service` is **masked** to avoid first-boot interactive prompts.

The default target is set to `multi-user.target` (`systemctl set-default`); no graphical
stack is installed.

### ansible-pull

`ansible-pull.timer` runs `ansible-pull.service` hourly (plus 5 minutes after boot) to
apply machine-local configuration from a git repository. The mechanism is image-managed;
the repository is configured in `/etc/ansible/pull.env`:

- `ANSIBLE_PULL_REPO` — git URL. While empty the service is skipped (`ExecCondition`), so
  the timer is harmless on an unconfigured host.
- `ANSIBLE_PULL_BRANCH`, `ANSIBLE_PULL_PLAYBOOK`, `ANSIBLE_PULL_DIR` — defaults `main`,
  `local.yml`, `/var/lib/ansible/pull`.
- `ANSIBLE_PULL_VERIFY_COMMIT=yes` (default) passes `--verify-commit`, so the checked-out
  commit must carry a valid GPG signature from a key in the root keyring.
- `/usr/libexec/ansible-pull-run` is the wrapper: it builds the `ansible-pull` arguments and
  selects the vault password (a systemd credential named `vault` if present, otherwise
  `/etc/ansible/vault.pw`).

Bootc constraints: the repository is executed as **root**, so it is cloned with
`GIT_TERMINAL_PROMPT=0` and should be public-safe (secrets via `ansible-vault`, signed
commits, branch protection). The playbook must only manage `/etc` and `/var`; `/usr` is the
sealed composefs and is updated by bootc, so package installation is not possible. Extra
collections belong in `/var/lib/ansible/collections` (`ANSIBLE_COLLECTIONS_PATH`), not
`/usr/share/ansible`.

### Machine identity

`/etc/machine-id` is set to `uninitialized` (generated on first boot) and the timezone is set
to UTC so nothing prompts.

### `containers` user and subuid/subgid

The image ships a `containers` system user, declared in
`/usr/lib/sysusers.d/containers.conf` and materialized at build time with
`systemd-sysusers` (the `sysusers.d` declaration keeps `bootc container lint` clean).
`/etc/subuid` and `/etc/subgid` get the reserved range `containers:100000:65536`.
Podman's
`--userns=auto` (and Quadlet `UserNS=auto`) defaults to the `containers` user for its
user-namespace mapping; without the user and range, `podman pod create --userns auto`
fails with *"Cannot find mappings for user containers: no subuid ranges found"*. The
range is reserved here once so service-specific ranges (added by the ansible-pull
repository) stay disjoint from it.

### Headless server defaults

The image targets unattended servers, not a desktop:

- The default target is `multi-user.target`; there is no graphical stack.
- `nftables.service` is **not** enabled. The package's stock `/etc/nftables.conf` is kept
  but unloaded: its `forward` chain is an empty `policy drop` (no rootful container egress)
  and its input chain has no container-bridge rule (no container→host DNS). The image
  therefore ships without an active host firewall.
- SMART (`smartd.service`) and system activity (`sysstat.service`) monitoring are enabled.
  `lm_sensors` is installed, but its service is not enabled because it requires a
  machine-specific `sensors-detect` run first.
- `irqbalance.service` and `fstrim.timer` are enabled.

### Unattended updates and reboots

bootc separates *staging* an update from *applying* it:

- `bootc-fetch-apply-updates.timer` (upstream unit: `bootc upgrade --apply --quiet`, first
  run `OnBootSec=1h`, then every eight hours with a two-hour randomized delay) stages OS
  updates but never reboots.
- The upstream update service/timer are gated on `ConditionPathExists=/run/ostree-booted`,
  but upstream documents that **native composefs boots do not write that marker** (only the
  ostree backend does). This image boots via composefs, so vendor drop-ins
  (`/usr/lib/systemd/system/bootc-fetch-apply-updates.{timer,service}.d/10-composefs.conf`)
  reset `ConditionPathExists=` to let the timer run. `bootc upgrade` itself detects the
  composefs environment, so no marker is required at runtime.
- `bootc-auto-reboot.timer` (Sunday 03:00, `RandomizedDelaySec=1h`, not `Persistent`)
  starts `bootc-auto-reboot.service` (gated on `ConditionKernelCommandLine=composefs`),
  which runs `/usr/libexec/bootc-auto-reboot`. That helper reads `bootc status --json` and
  reboots **only** when a deployment is staged and is not `downloadOnly`, logging its
  decision via `logger`. `jq` is installed in the image for that check.
- Because the timer is not `Persistent`, a missed maintenance window does not force an
  immediate reboot on the next boot.

In development the tracked image is the local `localhost/rogue:latest`, which is not
pullable from inside a test VM; there the update service will fail its pull and can be
ignored. Production images track a registry reference such as `ghcr.io/jopfrag/rogue`.

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
- `/usr/lib/systemd/network/10-podman-veth.network` matches `Kind=veth` and marks it
  `Unmanaged=yes`. veth has no udev `DEVTYPE=`, so it resolves to `Type=ether` and would
  otherwise be caught by `20-wired.network` (DHCP on every container veth); the `10-` prefix
  makes this file take precedence.
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

The initramfs also carries the modules needed to unlock a LUKS root with a TPM2 token:
`add_dracutmodules+=" crypt systemd-cryptsetup tpm2-tss "` pulls in the `cryptsetup`
helpers, `systemd-cryptsetup`, the TPM2 stacks, the
`libcryptsetup-token-systemd-tpm2.so` token plugin, and the TPM kernel drivers (the CachyOS
server kernel has the core `tpm`, `tpm_tis` and `tpm_crb` built in, so no TPM modules are
needed). The `tpm2-tss` module's `check()` requires the `tpm2` binary from `tpm2-tools`,
which is why that package is installed even though the final image does not otherwise need
it.

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
passed**.

Everything after `--` is forwarded to `ukify` unchanged. When the signing secrets are
supplied, the build appends:

- `--signtool sbsign --secureboot-private-key … --secureboot-certificate …` (from
  `sbsigntools`), signing the UKI for Secure Boot;
- `--pcr-private-key … --pcr-public-key …`, which makes `ukify` invoke `systemd-measure`
  and embed a `.pcrsig`/`.pcrpkey` **signed PCR policy** (PCR 11) so a LUKS volume can be
  bound to the image and still unlock across updates.

Without the secrets the command is byte-for-byte the unsigned build.

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

## Disk encryption (LUKS) and TPM2

The image supports a LUKS2-encrypted root that is auto-unlocked via a TPM2 **signed PCR
policy combined with a literal PCR 7 binding**. As bootc's `docs/src/filesystem-encryption.md`
recommends, disk encryption is handled independently of bootc's installer, via
`systemd-cryptsetup`/`systemd-cryptenroll`; the binding uses a signed PCR policy rather than
bootc's built-in `tpm2-luks`:

- `ukify` embeds a `.pcrsig` (a signature over the predicted PCR 11 value) and `.pcrpkey`
  (the matching public key) into the UKI when the PCR signing secrets are supplied.
- `systemd-stub` copies those sections into the initrd as
  `/.extra/tpm2-pcr-signature.json` and `/.extra/tpm2-pcr-public-key.pem`, so
  `systemd-cryptsetup` can unlock the root with the TPM2 token.
- Enrollment combines the signed policy with a literal **PCR 7** binding:
  `systemd-cryptenroll --tpm2-public-key=<pub.pem> --tpm2-pcrs=7:sha256 --tpm2-device=auto`
  (see `INSTALL.md`). The token then requires **both** a valid PCR 11 signature and the PCR
  7 value recorded at enrollment. Every UKI signed by the same PCR key unlocks, so
  `bootc upgrade` does not break auto-unlock; no NV-index refresh hook is needed (unlike
  `systemd-pcrlock`). Because PCR 7 reflects the firmware's Secure Boot policy, booting with
  Secure Boot disabled, or with changed Secure Boot keys, fails the policy and falls back
  to the passphrase prompt.

The image deliberately does **not** enable bootc's built-in `block = ["tpm2-luks"]`.
That path calls `systemd-cryptenroll --tpm2-device=auto` with **no** `--tpm2-pcrs`, i.e. it
binds to the mere presence of the TPM, wipes the passphrase slot (`--wipe-slot=all`), and
carries no signed PCR policy. Disk encryption is set up with the manual `to-filesystem`
flow and enrolled afterwards, as documented in `INSTALL.md`.

### Secure Boot and the boot loader

Firmware verifies `systemd-boot` before the UKI, so both must be signed with the same key.
`systemd-boot` lives at `/usr/lib/systemd/boot/efi/systemd-bootx64.efi`, which is inside
the composefs digest; it is therefore signed in the `rootfs` stage, **before**
`sealed-uki` computes the digest. Signing it afterwards (for example in the final stage)
would make the digest and the on-disk rootfs disagree and fail fs-verity verification. The
`sbsigntools` package is installed only for the duration of that step and removed again.

Enrolling the certificate into the target firmware is the last mile. The Secure Boot
enrollment material — `PK.auth`, `KEK.auth` and `db.auth` — is pre-made outside the build
and committed to the repository under `root/usr/lib/bootc/install/secureboot-keys/auto/`.
`COPY root /` places them in the image, and bootc copies them to `<ESP>/loader/keys/auto/`
at install time. `systemd-boot` then offers a one-time enrollment entry in its boot menu.
The firmware must be in **Setup Mode** for the authenticated writes to succeed.

The `.auth` files contain only public certificates (signed auth structures); no private
keys are in the image. Regenerate them with `efitools` when the key material changes.

bootc's `get_secureboot_keys()` reads `usr/lib/bootc/install/secureboot-keys/` and treats
**every entry directly under it as a key-set directory**, bailing with
`... is not a directory` if it finds a plain file there. It then copies only `*.auth` files
found inside those subdirectories. The `auto/README` that documents the expected names
therefore lives *inside* `auto/` (where non-`.auth` files are ignored), not directly under
`secureboot-keys/`; a file placed directly under `secureboot-keys/` breaks `bootc install`
before the bootloader is even written.

### Boot loader configuration

`root/usr/lib/bootc/loader.conf` is the vendored `systemd-boot` configuration:

```
timeout 5
console-mode keep
editor no
secure-boot-enroll if-safe
```

bootc does not copy it automatically. `/loader/loader.conf` lives on the ESP, which is
outside the composefs image, so it can be written after `bootc install` without affecting
the fs-verity digest; `INSTALL.md` describes the step. The `default <entry-token>-*` line
written by `bootctl install` is preserved by appending the vendored file. `editor no` and
`secure-boot-enroll if-safe` keep the boot menu from editing the measured command line and
leave Secure Boot enrollment manual.
