#!/usr/bin/env bash
# Assemble the installer ISO. Runs inside the iso-builder container.
#
# Inputs (mounted):
#   /output/installer-rootfs  exported installer root filesystem
#   /iso/                     this directory (grub config, etc.)
# Output:
#   /output/cachyos-bootc-installer.iso
set -euo pipefail

rootfs=/output/installer-rootfs
work=/tmp/iso-work
iso_root="${work}/iso"
out_iso=/output/cachyos-bootc-installer.iso

echo "iso: installing build tools"
sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
# Pin a consistent CachyOS mirror: the default cdn77 CDN first entry serves a mismatched
# db/sig pair (see the main Containerfile).
printf 'Server = https://us.cachyos.org/repo/$arch/$repo\nServer = https://at.cachyos.org/repo/$arch/$repo\n' \
    > /etc/pacman.d/cachyos-mirrorlist
pacman -Sy --noconfirm --needed \
    squashfs-tools grub xorriso mtools dosfstools dracut cpio linux >/dev/null
pacman -Scc --noconfirm >/dev/null

kver="$(ls "${rootfs}/usr/lib/modules" | head -n1)"
echo "iso: kernel ${kver}"

# --- squashfs of the installer rootfs --------------------------------------
echo "iso: creating squashfs"
rm -rf "${work}"
mkdir -p "${iso_root}/LiveOS" "${iso_root}/EFI/BOOT" "${iso_root}/boot/grub"

# dracut's dmsquash-live expects the squashfs at LiveOS/squashfs.img
mksquashfs "${rootfs}" "${iso_root}/LiveOS/squashfs.img" \
    -comp zstd -noappend -wildcards \
    -e 'proc/*' 'sys/*' 'dev/*' 'tmp/*' 'run/*' 'var/cache/*'

# --- kernel and initramfs ---------------------------------------------------
# Use the installer's own kernel. Its initramfs already includes dmsquash-live.
cp "${rootfs}/usr/lib/modules/${kver}/vmlinuz" "${iso_root}/boot/vmlinuz"
cp "${rootfs}/usr/lib/modules/${kver}/initramfs.img" "${iso_root}/boot/initramfs.img"

# --- efiboot.img (FAT image containing the EFI bootloader) ------------------
echo "iso: building EFI boot image"
# Embed the menuentry directly so the standalone image needs no external
# configfile.mod (which is not present in a minimal grub-mkstandalone).
cat > "${work}/grub-embed.cfg" <<'EOF'
set timeout=1
set default=0
insmod search_label
insmod linux
insmod initrd
search --no-floppy --label --set=root CACHYOS_BOOTC
menuentry "CachyOS bootc installer" {
    linux /boot/vmlinuz rd.neednet=1 ip=dhcp root=live:CDLABEL=CACHYOS_BOOTC rd.live.image rd.overlay=LABEL=OVERLAY rd.overlay.reset rd.overlay.nouserconfirmprompt console=ttyS0,115200n8
    initrd /boot/initramfs.img
}
EOF

grub-mkstandalone \
    --format=x86_64-efi \
    --output="${iso_root}/EFI/BOOT/BOOTX64.EFI" \
    --modules="search search_label linux normal all_video part_gpt part_msdos fat iso9660" \
    --locales="" --fonts="" \
    "boot/grub/grub.cfg=${work}/grub-embed.cfg"

# Build a small FAT filesystem image holding the EFI bootloader, then embed it.
efi_img="${work}/efiboot.img"
dd if=/dev/zero of="${efi_img}" bs=1M count=16 status=none
mkfs.vfat -F16 "${efi_img}" >/dev/null
mmd -i "${efi_img}" ::/EFI ::/EFI/BOOT
mcopy -i "${efi_img}" "${iso_root}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# a config on the ISO itself
cat > "${iso_root}/boot/grub/grub.cfg" <<'EOF'
set timeout=1
set default=0
menuentry "CachyOS bootc installer" {
    linux /boot/vmlinuz rd.neednet=1 ip=dhcp root=live:CDLABEL=CACHYOS_BOOTC rd.live.image rd.overlay=LABEL=OVERLAY rd.overlay.reset rd.overlay.nouserconfirmprompt console=ttyS0,115200n8
    initrd /boot/initramfs.img
}
EOF

# --- assemble the ISO -------------------------------------------------------
echo "iso: running xorriso"
xorriso -as mkisofs \
    -o "${out_iso}" \
    -isohybrid-gpt-basdat \
    -volid CACHYOS_BOOTC \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    -append_partition 2 0xef "${efi_img}" \
    "${iso_root}"

echo "iso: done"
ls -la "${out_iso}"
