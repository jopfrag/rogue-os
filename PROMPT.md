# Refactor: Three Independent Targets

Read `AGENTS.md` before doing anything else. It defines how you must work.

Your job is to refactor this repository so that it exposes **three independent targets**.
The only thing they may share is `Containerfile` (the bootc image definition, plus its
documentation `Containerfile.md` and its patch `bootc-f2fs.patch`).

You must **not** change the image architecture. The image stays a sealed CachyOS bootc
image: composefs backend, systemd-boot, unsigned UKI, fs-verity enforced, f2fs root,
Secure Boot disabled, and `bootupd` absent. This refactor is layout and entrypoint work
only.

## The three targets

### Target 1 — CI builds `Containerfile`

A GitHub Actions workflow that builds the OCI image from `Containerfile`.

- Lives in `.github/workflows/`.
- Does not depend on the installer ISO or the VM test.
- Pull requests: build only.
- Push to the main branch: build and push the image.
- Builds `Containerfile` directly (its own build step), so that only `Containerfile` is
  shared with the other targets.

### Target 2 — Make target builds the Arch Linux installer ISO

An **Arch Linux** live/installer ISO, built with Arch's own tooling (`mkarchiso`), intended
to be used as a manual control environment for installing the bootc image on real hardware.

This replaces the previous purpose-built CachyOS installer (`installer/`, which used an
auto-install systemd service). The bootc installation itself is **out of scope**: the
operator runs it manually over SSH. The ISO only has to provide:

- a bootable Arch Linux live environment;
- `sshd` running, with **root password authentication** enabled;
- root password set to `root`;
- enough writable space to build/pull the container image.

This target must be independent: it needs only the Arch releng profile, `mkarchiso`, and
the build-environment shims. It does not need `Containerfile` at build time.

### Target 3 — Make target tests the installation in a VM

The existing disposable libvirt/QEMU/KVM workflow: build/push the image, boot an installer,
install the bootc image, boot the installed system, and run the automated tests (install,
boot, smoke, update, rollback), cleaning up afterwards.

This target **consumes** an image reference and an installer ISO path. It does not build
either. It is being **migrated behind a clean entrypoint, not redesigned**, in this refactor:
move it, parameterize the hardcoded values, keep its behaviour otherwise identical.

## Structure

```
.github/workflows/     Target 1 (CI image build)
iso/                   Target 2 (Arch installer ISO profile + build script + shims)
vm-test/               Target 3 (disposable VM test workflow)
Containerfile          shared by all three
Makefile               thin dispatchers for the local targets
```

Each target owns its own scripts and configuration. Do not have one target source another
target's scripts or Makefile.

## Verified environment facts (do not re-derive)

These were established empirically. They constrain the implementation.

- The agent runs inside a **CachyOS Distrobox** (Arch family) inside a **Fedora host**.
- **`mkarchiso` (archiso 90-1) is already installed** in this environment. It is Arch's
  official ISO-building tool, driven by a *profile* directory.
- **This container forbids creating fresh `devtmpfs`/`proc`/`sysfs` mounts.** `mkarchiso`
  (through `pacstrap`) requires them. A `mount`/`umount` shim that substitutes `tmpfs`+bind
  for `devtmpfs` and `--rbind` for `proc`/`sysfs` is **required**. A working shim exists at
  `/home/jopfrag/shim/bin/` from a previous session; it must be vendored into `iso/shims/`
  so the repository is self-contained.
- The stock Arch **releng profile already enables `sshd`** and already sets
  `PermitRootLogin yes` and `PasswordAuthentication yes` in
  `airootfs/etc/ssh/sshd_config.d/10-archiso.conf`. The only real change needed for Target 2
  is to **set a root password** (stock Arch leaves it empty, and sshd refuses
  empty-password authentication).
- The Arch live system's writable layer is the **`cow_spacesize`** boot parameter, which
  mounts a **tmpfs** and defaults to **256M**. "More disk space" means enlarging
  `cow_spacesize` on the kernel command line of the profile's boot entries. A companion
  disk-backed `cow_device` is the RAM-independent alternative for real hardware.
- libvirt is the **host's** `qemu:///system`; VM disks live under host `/var/tmp`
  (container path `/run/host/var/tmp`) owned by uid 107; test domains need
  `<cpu mode='host-passthrough'/>`.
- The local OCI registry serves plain HTTP on the libvirt bridge (`192.168.122.1:5000`).

A previous session already built a Target 2 ISO successfully (`/var/tmp/` still contains the
output and the `mkarchiso` logs). Its sshd override and mount shims are the correct starting
point. The profile itself was removed from the tree; recreate it under `iso/`.

## Decisions

These are the current decisions. Confirm or correct them before implementing a task that
depends on them, and record changes in `TASKS.md`.

1. **Base ISO**: official Arch Linux **releng** profile, built with `mkarchiso`.
2. **Root password**: literal `root`.
3. **SSH**: root login over SSH with password authentication enabled (`AllowUsers root`).
   Key auth may remain enabled. This applies only to the throwaway installer ISO, never to
   the final bootc image (which stays key-only with password auth disabled).
4. **Writable space**: enlarge `cow_spacesize` on the boot entries. Prefer a disk-backed
   `cow_device` for real hardware if it can be done without overcomplicating the build.
5. **Mount shims**: vendor `mount`/`umount` into `iso/shims/`; `iso/build.sh` prepends them
   to `PATH` when invoking `mkarchiso`.
6. **CI push target**: GHCR (`ghcr.io/<owner>/cachyos-bootc`), built with the runner's podman.
7. **Target 3**: migrate and parameterize only; do not redesign.

## Constraints

- One task at a time. `TASKS.md` is the source of truth.
- Do not change the sealed-image architecture (composefs + UKI + systemd-boot, f2fs,
  fs-verity enforced, no `bootupd`, no Secure Boot).
- `Containerfile.uki` is a read-only reference. Never modify it.
- Scripts use `set -euo pipefail`, quote variables, clean up with traps, and never hide
  failures (`|| true` only deliberately and documented).
- Tests and builds must be disposable and must only touch resources they created.
- Do not document functionality that does not exist.
- Verify every step before marking a task complete. "Probably works" is not done.

## Definition of done

- `.github/workflows/` builds `Containerfile`; PRs build only, main pushes.
- `make iso` produces a bootable Arch Linux live ISO with root/`root` SSH access and enough
  writable space, built stand-alone.
- `make vm-test` installs and tests the image in a disposable VM, taking the image reference
  and ISO path as inputs, without building either.
- `make build` still builds the image.
- The three targets share nothing except `Containerfile`.
- README and `TASKS.md` match the resulting layout, and the intended sealed architecture is
  preserved.

## First actions

1. Read `AGENTS.md`, then `PROMPT.md`, then `TASKS.md`.
2. Confirm the decisions above (especially `cow_spacesize` value/size and CI push target).
3. Implement one task at a time, verifying each before moving on.
