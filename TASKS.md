# Tasks

Source of truth for project progress. One task may be In Progress at a time.

Scope: document manual installation of the sealed CachyOS bootc image from a stock Arch
Linux installation ISO (`INSTALL.md`). See `PROMPT.md` for the objective and `AGENTS.md`
for how to work.

## Completed

- [x] Task 1 — Verify live-environment tooling and command syntax.
      Evidence: all checks run in disposable `docker.io/archlinux:latest` containers
      (podman 5.8.4). Logs kept under `artifacts/task1-live-tools/` (gitignored).
      * Packages install and are present in the live environment:
        - releng ISO set (upstream `configs/releng/packages.x86_64`) already contains
          `parted` (3.7), `gptfdisk`/`sgdisk` (1.0.10), `f2fs-tools`/`mkfs.f2fs` (1.16.0),
          `dosfstools`/`mkfs.fat` (4.2), `util-linux` (2.42.3), `openssh`, `mtools`.
        - `podman` installs from *extra* (6.1.2 in the container) and is enough; `skopeo`
          also installs but is **not** needed (see decision below).
      * Target-disk syntax accepted (on a sparse loop file + extracted partitions):
        `parted -s -a opt D mklabel gpt`; `parted -s -a opt D mkpart ESP fat32 1MiB 1GiB`;
        `parted -s D set 1 esp on`; `parted -s -a opt D mkpart root f2fs 1GiB 100%`;
        `parted -s D type 2 4f68bce3-e8cd-4db1-96e7-fbcaf984b709`. `sgdisk -i 2` then reports
        `Linux x86-64 root (/)` (the DPS GUID). `mkfs.vfat -F32 -n EFI` and
        `mkfs.f2fs -f -l root` succeed; `blkid` shows the `EFI`/`root` labels.
      * `systemd-tmpfiles` root-key injection: a `f~ … <base64>` line creates
        `authorized_keys` with the exact public-key content and mode 0600 on Arch's systemd
        (261), verified with `systemd-tmpfiles --create --root=…`.
      * podman default graphroot is `/var/lib/containers/storage` (Arch ships no
        `/etc/containers/storage.conf`; confirmed with `podman info`), so mounting scratch at
        `/var/lib/containers` is correct.
      * Upstream `bootc` v1.16.13 (`crates/lib/src/install.rs`): `install to-filesystem`
        accepts `--target-imgref` and `--skip-finalize` plus the positional root; a unified
        (UKI) kernel auto-selects the composefs backend (`composefs_required`), and a UKI
        rejects external kernel arguments.
      * Live ISO: root has an empty password and airootfs sets
        `PermitRootLogin yes`/`PasswordAuthentication yes`; `sshd.service` is enabled. Hence
        setting a password is enough to log in over SSH. `cow_spacesize` defaults to `256M`;
        incremental installed size of `podman` beyond the releng set is ~139 MiB, so it fits.

- [x] Task 2 — Write `INSTALL.md`.
      Evidence: `INSTALL.md` exists and follows the resolved layout (single GPT disk, 1 GiB
      ESP + f2fs DPS root, scratch mounted at `/var/lib/containers`) and the tested logic in
      `installer/stage/install-bootc.sh` (self-install via podman, `--skip-finalize`,
      per-deployment tmpfiles SSH-key injection, manual finalize). The document also mirrors
      `vm-test/smoke.sh` for post-install checks.

- [x] Task 3 — Verify `INSTALL.md` and reconcile documentation.
      Evidence: every command traced to container runs (Task 1 logs) or upstream documentation:
      - Container-verified: `parted` 3.7 `mklabel`/`mkpart`/`set`/`type` and the DPS GUID;
        `mkfs.vfat -F32 -n EFI` and `mkfs.f2fs -f -l root`; `podman` install, version and
        default graphroot; `lsblk -o …`, `fstrim --quiet-unsupported -v`, `podman images
        [IMAGE]`; the exact step 9 shell snippet applied with `systemd-tmpfiles --create
        --root=…`; the overlay-size estimate.
      - Upstream-verified: releng `packages.x86_64`/`profiledef.sh`; archiso airootfs
        `10-archiso.conf`/`shadow` and enabled `sshd.service`; `mkinitcpio-archiso`
        `cow_spacesize`/`copytoram`; Arch kernel `CONFIG_F2FS_FS=m`; bootc v1.16.13
        `install to-filesystem` flags and composefs/UKI behavior.
      - Called out as not testable in a container (documented as such in the doc): actual
        UEFI/firmware boot and Secure Boot state; the real USB scratch mount; the full
        `bootc install to-filesystem` run on hardware. The exact podman/bootc invocation is
        taken from the VM-tested installer and the flags are confirmed against the pinned
        bootc source.
      - `README.md` links to `INSTALL.md`; the sealed architecture is unchanged (no changes
        to `Containerfile`, `Containerfile.uki`, `installer/` or `vm-test/`).

- [x] Task 4 — Set the manual-layout ESP size to 1 GiB.
      Evidence: by explicit user decision, `INSTALL.md` now uses `1GiB` for both the ESP end
      and the root start (was 2.5 GiB). Verified in an `archlinux` container (log
      `artifacts/task1-live-tools/20-esp-1g-syntax.log`): `parted -s -a opt D mkpart ESP
      fat32 1MiB 1GiB` + `mkpart root f2fs 1GiB 100%` yields a 1 GiB ESP and the f2fs root
      at 100%. The automated installer (`installer/stage/install-bootc.sh`) is intentionally
      left at `+512M`; only the manual document was changed.

## In Progress

*(none)*

## Remaining

*(none)*

## Blocked

*(none)*

## Notes

### Resolved decisions

1. **Scratch storage**: an **existing** partition on the Arch ISO USB (or another local
   disk), mounted at `/var/lib/containers` (podman graphroot), with `TMPDIR` on the same
   scratch. Disposable. `INSTALL.md` assumes it already exists and only mounts it.
2. **Target layout**: single disk, GPT via `parted` with `align=opt`; `p1` FAT32 ESP
   1 GiB (`esp` flag); `p2` f2fs 1 GiB → 100% with the DPS x86-64 root GUID. (Changed from
   2.5 GiB by explicit user decision; `INSTALL.md` only — the automated installer still uses
   a 512 MB ESP.)
3. **One ESP only** — no separate `/boot`, no GRUB/`bootupd`.
4. **Image**: `ghcr.io/jopfrag/cachyos-bootc:latest` (public, no auth).
5. Device names are placeholders in the document; the reader substitutes their own.

### Facts established during Task 1

- Stock Arch ISO writable overlay defaults to `cow_spacesize=256M` (verified in upstream
  `mkinitcpio-archiso`: `hooks/archiso`, `cow_spacesize="$(getarg 'cow_spacesize' '256M')"`).
  This is why the scratch step is mandatory. The releng ISO's kernel cmdline has no
  `copytoram=`, so archiso uses `copytoram=auto` (copies the squashfs to RAM and unmounts the
  ISO when RAM allows).
- The archiso `releng` package set already includes `gptfdisk`, `parted`, `dosfstools`,
  `e2fsprogs`, `xfsprogs`, `btrfs-progs`, `f2fs-tools`, and `openssh`, but **not** `podman`
  (nor `skopeo`). Arch's `linux` has `CONFIG_F2FS_FS=m` with module autoloading enabled.
- The image sets `PermitRootLogin prohibit-password` and `PasswordAuthentication no`; root
  has no password. SSH key injection is therefore mandatory, not optional. Host keys are
  generated by `sshdgenkeys.service`.
- The live airootfs sets `PermitRootLogin yes` and `PasswordAuthentication yes` and has an
  empty root password, and `sshd.service` is enabled — so `passwd` is all that is required to
  reach the live system over SSH.
- Arch does not ship `/etc/containers/storage.conf`; podman's compiled default graphroot is
  `/var/lib/containers/storage`. Therefore the manual flow must **not** bind-mount
  `/etc/containers/storage.conf` (as the automated installer does in its own rootfs).

### Resolved open items

- `parted` alignment: use the global `-a opt` option before the device; raw GUIDs are set with
  the `type NUMBER TYPE-UUID` subcommand (GNU parted 3.7).
- Scratch partition: by decision, the manual procedure **assumes the scratch partition already
  exists** on the ISO USB (or another local disk) and only mounts it. Creating it is out of
  scope for `INSTALL.md`.
- podman graphroot: `/var/lib/containers/storage` (default), so mount scratch at
  `/var/lib/containers`.
- `bootc install to-filesystem`: `--target-imgref` and `--skip-finalize` confirmed for
  v1.16.13; `install finalize` is ostree-only and is intentionally not used for composefs.
- Image fetching: use `podman pull` instead of `skopeo copy`. Both use the same
  containers/image stack and land the image in the same graphroot; `podman pull` avoids
  installing `skopeo` and its dependencies (~26 MiB + deps) in the 256 MiB live overlay. The
  image is public (no auth): `skopeo inspect` returned its manifest anonymously.
