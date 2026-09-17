# Third-party attribution

This project is developed with reference to existing bootc implementations. Where code or
configuration is adapted from another project, that project is listed here together with its
license and the nature of the adaptation, as required by its license terms.

## bootcrew (Arch Linux bootc)

- Repositories:
  - `https://github.com/bootcrew/mono` (current; contains `arch/Containerfile` and
    `shared/{build.sh,initramfs.sh,bootc-rootfs.sh}`)
  - `https://github.com/bootcrew/arch-bootc` (deprecated predecessor; referenced by this
    project's original task prompt as `bootc-crew/arch-bootc`, which now redirects here)
- License: Apache License 2.0 (Copyright 2025 tulilirockz)
- Used as: a technical reference for building an Arch-family bootc image — in particular the
  pattern of building `bootc` from source and the base-image root filesystem layout
  (`/ostree` symlink, `/var` tmpfiles, `prepare-root.conf` with composefs, pacman `/var`
  relocation). Any file adapted from these repositories will note the attribution inline.

## bootc upstream

- Repository: `https://github.com/bootc-dev/bootc`
- License: Apache License 2.0 / MIT (dual)
- Used as: the source of the `bootc` binary (built from source into our image) and of the
  recommended base-image reference configuration under `baseimage/`. The sealed
  composefs/UKI build follows the upstream `docs/src/experimental-composefs.md` pattern
  (`bootc container split-kernel-and-rootfs` + `bootc container ukify`).
- `bootc-f2fs.patch` (in this repository) is a local, minimal patch to bootc source that
  adds `f2fs` as a known install filesystem (`Filesystem::F2fs`, the `"f2fs"` parse arm,
  and `supports_fsverity()`), plus the exhaustiveness arm in `baseline.rs`. It is derived
  from bootc's own source tree and is covered by bootc's dual Apache-2.0/MIT license.

## bootupd (superseded; not used)

- Repository: `https://github.com/coreos/bootupd`
- License: Apache License 2.0
- An earlier iteration built `bootupd` (with the AUR Arch path adaptation patch
  `hack/patches/bootupd-archlinux-grub-paths.patch`) because bootc's *ostree* backend
  requires it on x86_64. The project now uses the **composefs + systemd-boot + UKI** path,
  which does not use bootupd at all. Kept here as an attribution record; the patch and the
  bootupd source build have been **removed as unused**.

## In-repo reference: Containerfile.uki

- `Containerfile.uki` (provided in this repository) is a read-only reference for the
  Fedora-based sealed composefs + UKI + systemd-boot build. It is not modified; its approach
  is adapted into `Containerfile` for CachyOS. Secure Boot signing steps are omitted.

## CachyOS / Arch Linux

- Base image: `docker.io/cachyos/cachyos-v3` (Arch Linux-based).
- Packages are used under their respective upstream licenses.
