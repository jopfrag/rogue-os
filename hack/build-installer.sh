#!/usr/bin/env bash
# Build the CachyOS bootc installer environment as a UEFI-bootable ISO.
#
# Produces: artifacts/cachyos-bootc-installer.iso
#
# Steps:
#   1. build the installer rootfs image (installer/Containerfile)
#   2. export its root filesystem to artifacts/installer-rootfs
#   3. (in a builder container with squashfs/grub/xorriso/dracut) make a squashfs of it,
#      generate a dmsquash-live initramfs, and assemble an EFI-bootable ISO
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${INSTALLER_IMAGE:-localhost/cachyos-installer:test}"
out_dir="${repo_root}/artifacts"
rootfs_dir="${out_dir}/installer-rootfs"
out_iso="${out_dir}/cachyos-bootc-installer.iso"

mkdir -p "${out_dir}"

case "${1:-}" in
    ""|all) ;;
    --iso-only) skip_rootfs=1 ;;
    *) echo "usage: build-installer.sh [--iso-only]" >&2; exit 2 ;;
esac

if [[ -z "${skip_rootfs:-}" ]]; then
    echo "==> building installer rootfs image (${image})"
    podman build -t "${image}" -f "${repo_root}/installer/Containerfile" "${repo_root}/installer"

    echo "==> exporting installer rootfs"
    sudo rm -rf "${rootfs_dir}"
    mkdir -p "${rootfs_dir}"
    cid="$(podman create "${image}" /bin/true)"
    podman export "${cid}" | tar -x -C "${rootfs_dir}"
    podman rm "${cid}" >/dev/null
    # The export may contain entries owned by uid 65534 (unmapped), which we cannot
    # remove as an unprivileged user; make everything owned by us so rebuilds are clean.
    sudo chown -R "$(id -u):$(id -g)" "${rootfs_dir}"
fi

[[ -d "${rootfs_dir}" ]] || { echo "missing rootfs export; run without --iso-only" >&2; exit 1; }

echo "==> assembling ISO"
podman run --rm \
    --name cachyos-bootc-iso-builder \
    -v "${out_dir}:/output:z" \
    -v "${repo_root}/installer/iso:/iso:z,ro" \
    docker.io/cachyos/cachyos-v3:latest \
    bash /iso/build-iso.sh

echo "==> ISO: ${out_iso}"
ls -la "${out_iso}"
