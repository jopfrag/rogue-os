# Installing the sealed CachyOS bootc image from a stock Arch ISO

This is the manual, by-hand equivalent of the automated installer (`installer/`) and the
disposable VM test (`vm-test/`). It installs the sealed CachyOS bootc image
(`ghcr.io/jopfrag/cachyos-bootc:latest`) onto a single disk, starting from a **stock
official Arch Linux installation ISO** (`archlinux-*.iso`).

The installation logic mirrors the tested script
[`installer/stage/install-bootc.sh`](installer/stage/install-bootc.sh); the post-install
checks mirror [`vm-test/smoke.sh`](vm-test/smoke.sh). Where this document differs from the
automated installer, the difference is called out explicitly.

The result is a **sealed** system:

- composefs backend for the root filesystem;
- an unsigned Unified Kernel Image (UKI) on the ESP, booted by systemd-boot;
- the composefs digest embedded in the UKI and enforced with fs-verity;
- f2fs root, no separate `/boot`, no GRUB and no `bootupd`;
- **Secure Boot must be disabled** (the UKI is unsigned).

This procedure is **UEFI-only**. BIOS/legacy boot is out of scope.

## Assumptions

- The target machine boots the stock Arch ISO in **UEFI** mode.
- The Arch ISO USB already has an extra partition that will be used as scratch storage
  during the installation, and that partition is already formatted (e.g. ext4). Creating
  that partition is out of scope here; the procedure only mounts it.
  - Scratch holds podman's image store and temporary files. It is disposable and is not
    part of the installed system.
  - The Arch live overlay is small (`cow_spacesize`, default `256M`), which is why a real
    scratch partition is required instead of the overlay.
- A workstation that can reach the target machine over SSH.
- The target disk is dedicated and will be wiped. A disk of 20 GB or more is recommended.
- Device names below (`/dev/nvme0n1`, `/dev/disk/by-label/scratch`, `nvme0n1p1`, …) are
  **placeholders**. Substitute your own. On NVMe devices partitions are `${disk}pN`
  (e.g. `/dev/nvme0n1p1`); on SATA/virtio they are `${disk}N` (e.g. `/dev/sda1`).

## 1. Boot the Arch ISO and enable SSH

At the ISO console (the live ISO auto-logs in as `root` on tty1):

1. Set a root password so you can log in over SSH:

   ```sh
   passwd
   ```

2. `sshd` is already running on the stock Arch ISO (`sshd.service` is enabled); optionally
   confirm and find the address:

   ```sh
   systemctl status sshd
   ip -br addr
   ```

From the workstation, log in (use the live machine's address):

```sh
ssh root@<live-ip>
```

Run the remaining steps in this SSH session, or re-export `TMPDIR` if you reconnect.

## 2. Mount the scratch storage

Identify the existing scratch partition:

```sh
lsblk -f
```

Mount it where podman expects its image store, and put temporary files there too. Podman's
default graphroot is `/var/lib/containers/storage`, so the mount point is
`/var/lib/containers`:

```sh
scratch=/dev/disk/by-label/scratch   # <-- your scratch partition

mkdir -p /var/lib/containers
mount "${scratch}" /var/lib/containers

mkdir -p /var/lib/containers/tmp
export TMPDIR=/var/lib/containers/tmp
```

Confirm the mount:

```sh
findmnt /var/lib/containers
```

## 3. Install podman in the live environment

The releng live ISO does not ship podman. Install it (and free the small overlay again):

```sh
pacman -Sy --needed podman
pacman -Scc --noconfirm
```

> `skopeo` is not required. `podman pull` uses the same containers/image stack and stores
> the image in the same graphroot, so the automated installer's `skopeo copy` step is
> replaced by `podman pull` here. This avoids installing skopeo and its dependencies in the
> 256 MiB live overlay.

## 4. Identify the target disk

```sh
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
```

Make sure the disk you are about to erase is the right one. Throughout this document the
target disk is `<disk>` and its two partitions are `<esp>` and `<rootfs>`.

## 5. Partition the target disk (GPT: one ESP + f2fs root)

The root partition must carry the architecture-specific Discoverable Partitions
Specification (DPS) x86-64 root type GUID (`4f68bce3-e8cd-4db1-96e7-fbcaf984b709`). The
sealed UKI's command line has no `root=` argument (bootc rejects kernel arguments with a
UKI), so the initramfs finds the root filesystem through `systemd-gpt-auto-generator`,
which only recognises the DPS root GUID. A generic Linux filesystem type (`8300`) is **not**
discoverable and the system would drop to emergency mode.

```sh
disk=/dev/nvme0n1          # <-- your target disk
esp="${disk}p1"
rootfs="${disk}p2"

parted -s -a opt "${disk}" mklabel gpt

# ESP. `mkpart ... fat32` only names it; `set 1 esp on` sets the partition type GUID to
# the EFI system partition GUID (C12A7328-F81F-11D2-BA4B-00A0C93EC93B).
parted -s -a opt "${disk}" mkpart ESP fat32 1MiB 1GiB
parted -s        "${disk}" set 1 esp on

# Root: DPS x86-64 root type GUID (required for systemd-gpt-auto-generator).
parted -s -a opt "${disk}" mkpart root f2fs 1GiB 100%
parted -s        "${disk}" type 2 4f68bce3-e8cd-4db1-96e7-fbcaf984b709

parted -s "${disk}" unit MiB print
```

Expected: partition 1 is `ESP` with flags `boot, esp`; partition 2 is `root` with the DPS
x86-64 root GUID.

Format the two partitions:

```sh
mkfs.vfat -F32 -n EFI "${esp}"
mkfs.f2fs  -f   -l root "${rootfs}"
```

## 6. Mount the target

The f2fs kernel module is not built into the Arch live kernel (`CONFIG_F2FS_FS=m`); it is
normally auto-loaded by `mount`. Load it explicitly for clarity:

```sh
modprobe f2fs

mkdir -p /mnt/target
mount -t f2fs "${rootfs}" /mnt/target

mkdir -p /mnt/target/boot/efi
mount "${esp}" /mnt/target/boot/efi
```

There is deliberately **no** separate `/boot` partition: systemd-boot and the UKI live on
the ESP.

These are the **install-time** mount points, matching `installer/stage/install-bootc.sh`
(the VM test installs exactly this way). bootc does not rely on the `/boot/efi` mount: it
locates the ESP from the target disk's partition table itself. On first boot,
`systemd-gpt-auto-generator` mounts the ESP at **`/boot`** (the image ships a `/boot`
directory), which is where systemd-boot and the UKI are seen at runtime.

## 7. Pull the image into the scratch store

```sh
podman pull ghcr.io/jopfrag/cachyos-bootc:latest
```

The image is public and requires no authentication. Confirm it is available locally:

```sh
podman images ghcr.io/jopfrag/cachyos-bootc
```

## 8. Run the installation (self-install from inside the image)

The image is installed as a **self-install**: podman runs the sealed image itself
(privileged, with `/dev`, the podman store and the mounted target), and `bootc install
to-filesystem` runs *inside* that image. This is required for a sealed/UKI image: bootc
inspects its own root filesystem, finds the UKI under `/boot/EFI/Linux/`, and auto-selects
the composefs backend and systemd-boot.

Do **not** pass `--source-imgref` or `--composefs-backend`: the backend must be derived
from the image, not forced, and forcing it would bypass the UKI-driven digest/fs-verity
handling. Do **not** pass `--karg`: with a UKI, bootc rejects externally supplied kernel
arguments. `--allow-missing-verity` is not passed, so fs-verity is enforced.

`--skip-finalize` skips bootc's built-in finalization. Its `fstrim`/remount-read-only step
can block when the target is bind-mounted from the live host, so finalization is done here
instead, in step 10.

```sh
imgref=ghcr.io/jopfrag/cachyos-bootc:latest

podman run --rm --privileged --pid=host --ipc=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /mnt/target:/target \
    "${imgref}" \
    bootc install to-filesystem \
        --target-imgref "${imgref}" \
        --skip-finalize \
        /target
```

> Difference from the automated installer: `installer/stage/install-bootc.sh` additionally
> bind-mounts `/etc/containers/storage.conf` into the container. That file does not exist on
> a stock Arch live system (Arch ships no `/etc/containers/storage.conf`; podman uses its
> compiled-in default `/var/lib/containers/storage`), so it is omitted here. The bind-mount
> of `/var/lib/containers` still makes the scratch store visible to the container.

Do **not** run `bootc install finalize`: it is an ostree-backend step and the composefs
backend has no ostree sysroot.

## 9. Inject the root SSH public key

The image sets `PermitRootLogin prohibit-password` and `PasswordAuthentication no`, and
root has no password. Root login over SSH therefore requires an authorized key.

Copy your public key from the workstation to the live environment, then set up the
injection in the live SSH session:

```sh
# on the workstation
scp ~/.ssh/id_ed25519.pub root@<live-ip>:/root/authorized_keys.pub
```

```sh
# in the live SSH session
key=/root/authorized_keys.pub

# The composefs backend bind-mounts the running /etc from the per-deployment state
# directory (its digest is the `composefs=` value baked into the UKI). Writes to
# /mnt/target/etc would never be seen at boot, so write into the deployment state instead.
deploy_etc=$(ls -d /mnt/target/state/deploy/*/etc)
test -d "${deploy_etc}"

# /root is a symlink to var/roothome on a bootc image.
roothome=$(readlink /mnt/target/root)
: "${roothome:=root}"

# systemd tmpfiles "f~" lines take the file contents base64-encoded.
b64=$(base64 -w0 < "${key}")

install -d -m 0755 "${deploy_etc}/tmpfiles.d"
printf 'd /%s/.ssh 0700 root root -\nf~ /%s/.ssh/authorized_keys 600 root root - %s\n' \
    "${roothome}" "${roothome}" "${b64}" \
    > "${deploy_etc}/tmpfiles.d/bootc-root-ssh.conf"

cat "${deploy_etc}/tmpfiles.d/bootc-root-ssh.conf"
```

The tmpfiles rule recreates `/root/.ssh/authorized_keys` on every boot. This replicates
bootc's own `--root-ssh-authorized-keys` mechanism, which is only implemented for the
ostree backend.

## 10. Finalize the target

Flush writes, trim, then remount the target read-only. No `fsfreeze` is used: it can block
while the target is mounted, and the clean remount flushes the journal anyway.

```sh
sync
fstrim --quiet-unsupported -v /mnt/target

umount /mnt/target/boot/efi
mount -o remount,ro /mnt/target

umount /mnt/target
```

## 11. Reboot into the installed system

Make sure **Secure Boot is disabled** in firmware, then reboot and boot from the target
disk (change the boot order, or remove the Arch ISO USB first):

```sh
systemctl reboot
```

The installed system gets a DHCP address on the wired interface. From the workstation:

```sh
ssh -i ~/.ssh/id_ed25519 root@<target-ip>
```

## 12. Verify the sealed deployment

These mirror the checks in `vm-test/smoke.sh`:

```sh
# The cmdline carries the composefs digest baked into the UKI, and no '?' (allow-missing)
# prefix.
cat /proc/cmdline

# Root and /sysroot are read-only (sealed).
findmnt -no OPTIONS /
findmnt -no OPTIONS /sysroot

# /etc and /var are writable bind mounts.
test -w /etc && echo "/etc writable"
test -w /var && echo "/var writable"

# bootc reports a booted composefs deployment, no staged deployment, valid JSON.
bootc status
bootc status --json >/dev/null
! bootc status --json | grep -q '"staged": *{'

# System is healthy, sshd is active, no failed units, networking works.
systemctl is-system-running --wait
systemctl is-active sshd
systemctl --failed
ip -4 addr show scope global
```

Expected highlights: `cat /proc/cmdline` contains `composefs=<digest>`; `findmnt` shows `ro`
for `/` and `/sysroot`; `bootc status` shows a `composefs` deployment.

## Notes and troubleshooting

- **The target will not boot (emergency mode, "Dependency failed for Initrd Root
  Device")**: the root partition is missing the DPS x86-64 root GUID. Re-check step 5 with
  `sgdisk -i 2 "${disk}"`; it must report `Linux x86-64 root (/)`.
- **No SSH after reboot**: `authorized_keys` was written to `/mnt/target/etc` instead of the
  deployment state directory. Redo step 9 (the file must be
  `/mnt/target/state/deploy/<digest>/etc/tmpfiles.d/bootc-root-ssh.conf`).
- **Scratch runs out of space**: the image is roughly 1.8 GB compressed and larger once
  unpacked; size the scratch partition accordingly.
- **Live overlay runs out of space while installing podman**: install with
  `pacman -Scc --noconfirm` afterwards to reclaim the package cache, or boot the ISO with a
  larger `cow_spacesize=<size>` kernel argument (e.g. `cow_spacesize=1G`).
- **Secure Boot enabled**: the UKI is unsigned and will not be accepted; disable Secure
  Boot.
