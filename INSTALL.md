# Installing the sealed CachyOS bootc image from a stock Arch ISO

By-hand install of `ghcr.io/jopfrag/rogue:latest`. UEFI-only; Secure Boot must be
disabled. The result is sealed: composefs root with fs-verity enforced and an unsigned UKI
booted by systemd-boot.

## Assumptions

- Stock Arch ISO booted in UEFI mode.
- A spare, formatted scratch partition for podman's image store (the live overlay is only
  `256M`).
- The target disk will be wiped.

## 1. Live environment

```sh
passwd
ip -br addr          # address for `ssh root@<live-ip>`
```

## 2. Scratch store and podman

```sh
scratch=/dev/disk/by-label/scratch   # <-- your scratch partition
mkdir -p /var/lib/containers
mount "${scratch}" /var/lib/containers
mkdir -p /var/lib/containers/tmp
export TMPDIR=/var/lib/containers/tmp

pacman -Sy --needed podman
```

## 3. Target disk

```sh
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
```

## 4. Partition, format and mount

The root partition uses the DPS x86-64 root type GUID
(<https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>).

```sh
disk=/dev/nvme0n1
esp="${disk}p1"      # SATA/virtio: "${disk}1"
rootfs="${disk}p2"   # SATA/virtio: "${disk}2"

parted -s -a opt "${disk}" mklabel gpt
parted -s -a opt "${disk}" mkpart ESP fat32 1MiB 1GiB
parted -s        "${disk}" set 1 esp on
parted -s -a opt "${disk}" mkpart root f2fs 1GiB 100%
parted -s        "${disk}" type 2 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
partprobe "${disk}"
udevadm settle

mkfs.vfat -F32 -n EFI "${esp}"
mkfs.f2fs  -f   -l root -i -O extra_attr,inode_checksum,sb_checksum,verity "${rootfs}"

modprobe f2fs
mkdir -p /mnt/target
mount -t f2fs "${rootfs}" /mnt/target
mkdir -p /mnt/target/boot/efi
mount "${esp}" /mnt/target/boot/efi
```

## 5. Install

```sh
imgref=ghcr.io/jopfrag/rogue:latest
podman pull "${imgref}"

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

## 6. Root SSH key

```sh
# from the workstation
scp ~/.ssh/id_ed25519.pub root@<live-ip>:/root/authorized_keys.pub
```

```sh
key=/root/authorized_keys.pub
deploy_etc=$(ls -d /mnt/target/state/deploy/*/etc)
test -d "${deploy_etc}"
roothome=$(readlink /mnt/target/root); : "${roothome:=root}"
b64=$(base64 -w0 < "${key}")

install -d -m 0755 "${deploy_etc}/tmpfiles.d"
printf 'd /%s/.ssh 0700 root root -\nf~ /%s/.ssh/authorized_keys 600 root root - %s\n' \
    "${roothome}" "${roothome}" "${b64}" \
    > "${deploy_etc}/tmpfiles.d/bootc-root-ssh.conf"
```

## 7. Finalize

```sh
sync
fstrim --quiet-unsupported -v /mnt/target
umount /mnt/target/boot/efi
mount -o remount,ro /mnt/target
umount /mnt/target
```
