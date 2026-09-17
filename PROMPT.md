# Objective: Document manual installation from a stock Arch Linux ISO

Read `AGENTS.md` before doing anything else. It defines how you must work.

## Goal

Create `INSTALL.md`: a step-by-step manual procedure for installing this repository's
sealed CachyOS bootc image, starting from a **stock official Arch Linux installation ISO**.

This is the manual counterpart to:

- the automated installer (`installer/`), and
- the disposable VM test (`vm-test/`),

for users who do **not** use the custom installer ISO and want to install from a plain
Arch ISO by hand.

The intended flow is:

1. Boot the stock Arch ISO (UEFI).
2. In the live environment, set a root password and start `sshd`.
3. Do everything else **over SSH** from a workstation:
   - create scratch storage on the Arch ISO USB and mount it where podman expects images,
   - install the packages needed in the live environment,
   - partition and format the single target disk,
   - pull the image and install it,
   - inject the root SSH public key,
   - finalize and reboot,
   - verify the sealed deployment.

The document must mirror the **already-tested** logic in `installer/stage/install-bootc.sh`
(the automated installer) and the checks in `vm-test/`. Do not invent a new installation
method.

## Resolved installation layout

- **Arch ISO USB**: existing ISO and EFI partitions, plus one new **scratch** partition in
  the free space. Mounted at `/var/lib/containers` (podman's graphroot); `TMPDIR` points at
  it too. Disposable, used only during installation.
- **Target disk (a single disk)**:
  - GPT partition table, created with `parted` and `align=opt`.
  - `p1`: FAT32 EFI System Partition, **2.5 GB**, `esp` flag.
  - `p2`: **f2fs**, from **2.5 GB to 100%**, with the architecture-specific Discoverable
    Partitions Specification (DPS) x86-64 root GUID
    (`4f68bce3-e8cd-4db1-96e7-fbcaf984b709`).
  - No separate `/boot` partition. One ESP is correct: systemd-boot and the UKI live on the
    ESP, and `bootupd`/GRUB are absent.
- **Image reference**: `ghcr.io/jopfrag/cachyos-bootc:latest` (public, no authentication).
- Device names are **placeholders** in the document (target disk vs. ISO USB); the reader
  substitutes their own. Do not hardcode a specific machine's device names.

## Fixed architecture (do not change)

The sealed-image architecture is fixed and out of scope for change: composefs backend,
systemd-boot, unsigned UKI, fs-verity enforced, f2fs root, Secure Boot disabled, `bootupd`
absent. `Containerfile.uki` is a read-only reference and must not be modified.

This installation procedure is **UEFI-only**. BIOS/legacy boot is out of scope.

## Constraints

- Mirror the tested logic in `installer/stage/install-bootc.sh`; do not redesign it.
- Do not document functionality that does not exist.
- Verify commands in a disposable `archlinux` container where possible (package names,
  `parted` syntax, `mkfs` options); for anything that cannot be exercised there, confirm it
  against current upstream documentation or source (GNU parted, f2fs-tools, mkinitcpio-archiso,
  bootc).
- The live Arch ISO has only a small writable overlay (`cow_spacesize` default `256M`), so
  the document must clearly explain the scratch-storage step.
- No new automated test harness. "Automated tests are not really the goal."
- Scripts (if any are added) use `set -euo pipefail`, quote variables, and clean up.

## Definition of done

- `INSTALL.md` exists, is accurate, and is derived from the tested installer logic.
- Every command in it has been verified in a container or against upstream docs; anything
  unverifiable is called out explicitly.
- `README.md` links to `INSTALL.md`.
- `TASKS.md` reflects the work and its verification.
- The sealed-image architecture is unchanged.

## First actions

1. Read `AGENTS.md`, `PROMPT.md`, `TASKS.md`.
2. Verify the live-environment tooling and command syntax (`TASKS.md` Task 1).
3. Write `INSTALL.md` (Task 2).
4. Verify it and update `README.md` / `TASKS.md` (Task 3).
