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

## Optional: encrypted root (LUKS + TPM2 auto-unlock)

The runbook above installs a plain f2fs root. To encrypt the root and unlock it with the
TPM2 **signed PCR policy** embedded in a signed UKI, replace step 4 and add an enrollment
step before step 7. This requires an image built with the `pcr_key`/`pcr_pub` secrets; keep
`pcr_pub` on the live medium so it can be passed to `systemd-cryptenroll`.

### 4. Partition, format and mount (encrypted variant)

The GPT layout is unchanged; only the root partition is opened as LUKS2 and formatted
through the mapper:

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

cryptsetup luksFormat --type luks2 "${rootfs}"
cryptsetup open "${rootfs}" root
mkfs.f2fs -f -l root -i -O extra_attr,inode_checksum,sb_checksum,verity /dev/mapper/root

modprobe f2fs
mkdir -p /mnt/target
mount -t f2fs /dev/mapper/root /mnt/target
mkdir -p /mnt/target/boot/efi
mount "${esp}" /mnt/target/boot/efi
```

Keep the LUKS passphrase you set here: it is the recovery path and is never enrolled to the
TPM.

### 5. Install

Unchanged: run `bootc install to-filesystem` against `/mnt/target` as in the main runbook.
With the image's default discoverable-partition discovery, the initrd finds the LUKS root by
its GPT type GUID and unlocks it with the TPM2 token; if that does not work on your
firmware, add `--karg=luks.uuid=<UUID of ${rootfs}>` and
`--karg=luks.options=tpm2-device=auto,headless=true` to the install command.

### Enrollment (after step 6, before step 7)

Enroll the TPM2 token while the target disk is still available from the live medium. This
must run on the target machine so the token binds to the target's TPM, and it must run with
**Secure Boot enabled** and the image's `secureboot_cert` already enrolled in the firmware:
the token records the current PCR 7 value, and PCR 7 encodes the Secure Boot policy.
Enrolling a new keyslot prompts for the existing passphrase and leaves the passphrase
keyslot in place:

```sh
systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=7:sha256 \
    --tpm2-public-key=/path/to/pcr_pub.pem \
    "${rootfs}"
```

The token now requires **both** of the following to unlock:

- **PCR 7** to hold the Secure Boot policy value recorded at enrollment, and
- the UKI to carry a valid **signed PCR 11 policy** (`.pcrsig` signed by `pcr_key`).

Booting with Secure Boot disabled, or after changing the firmware's Secure Boot keys,
changes PCR 7, so the TPM refuses to release the key and the passphrase is requested. This
is intentional for an unattended server.

Then run step 7 (finalize) and reboot. The initramfs should unlock the root without a
prompt; if it ever fails, the LUKS passphrase still works.

> Auto-unlock is only possible for a UKI whose `.pcrsig` was signed by `pcr_key`. Every
> image built with the same `pcr_key` continues to unlock, so `bootc upgrade` does not break
> it. A Secure Boot key/db change or a firmware reset does change PCR 7 and will require
> re-enrollment; the retained passphrase slot lets you do that.
