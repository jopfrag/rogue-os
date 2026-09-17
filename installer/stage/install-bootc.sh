#!/usr/bin/env bash
# Automatic bootc installation, run by install-bootc.service on installer boot.
#
# Partition the target disk, create the filesystems, fetch the CachyOS bootc image and
# install it with `bootc install to-filesystem`, finalize, then reboot (or power off).
#
# Parameters come from the kernel command line:
#   bootc.install.imgref=<image reference>   (required)
#   bootc.install.target=container|filesystem  (default: container)
#   bootc.install.device=<block device>      (default: /dev/vda)
#   bootc.install.rootfs=<ext4|xfs|btrfs|f2fs>  (default: f2fs)
#   bootc.install.action=reboot|poweroff     (default: poweroff)
#   bootc.install.finalize=yes|no            (default: yes)
#
# `bootc.install.target=container` runs `bootc install to-filesystem` from inside the
# target container image via podman (the documented external-installer path).
set -euo pipefail

log() { printf 'install-bootc: %s\n' "$*" >&2; }
die() { printf 'install-bootc: ERROR: %s\n' "$*" >&2; exit 1; }

# --- gather parameters ------------------------------------------------------
# Parameters may be provided on the kernel command line and/or in an attached FAT volume
# labelled BOOTCINSTAL (file: install.env). The config volume is convenient for automated
# runs and avoids editing the bootloader menu.
cmdline="$(cat /proc/cmdline)"

config_dir=/run/bootc-install-config
mkdir -p "${config_dir}"
config_dev="$(blkid -L BOOTCINSTAL || true)"
if [[ -n "${config_dev}" ]]; then
    mount "${config_dev}" "${config_dir}" 2>/dev/null || true
    if [[ -f "${config_dir}/install.env" ]]; then
        log "reading parameters from ${config_dev}:/install.env"
        # Parse simple KEY=VALUE lines without sourcing (avoids executing the file).
        while IFS='=' read -r key value; do
            [[ -z "${key}" || "${key}" == \#* ]] && continue
            export "${key}=${value}"
        done < "${config_dir}/install.env"
    fi
fi

# Command-line values take precedence over the config volume.
cmdline_val() {
    sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"${cmdline}" | head -n1
}
imgref="${BOOTC_INSTALL_IMGREF:-}"; v="$(cmdline_val bootc.install.imgref)"; [[ -n "$v" ]] && imgref="$v"
device="${BOOTC_INSTALL_DEVICE:-/dev/vda}"; v="$(cmdline_val bootc.install.device)"; [[ -n "$v" ]] && device="$v"
rootfs="${BOOTC_INSTALL_ROOTFS:-f2fs}"; v="$(cmdline_val bootc.install.rootfs)"; [[ -n "$v" ]] && rootfs="$v"
action="${BOOTC_INSTALL_ACTION:-poweroff}"; v="$(cmdline_val bootc.install.action)"; [[ -n "$v" ]] && action="$v"
finalize="${BOOTC_INSTALL_FINALIZE:-yes}"; v="$(cmdline_val bootc.install.finalize)"; [[ -n "$v" ]] && finalize="$v"
# Optional path to an SSH public key for root. bootc injects it via tmpfiles.d so it is
# reapplied on every boot. Provided on the config volume (e.g. /run/bootc-install-config/
# root_ssh_key.pub) or on the kernel command line.
root_ssh_key="${BOOTC_INSTALL_ROOT_SSH_KEY:-}"; v="$(cmdline_val bootc.install.root_ssh_key)"; [[ -n "$v" ]] && root_ssh_key="$v"
# The config volume is mounted read-only under this path; accept a plain filename there.
if [[ -n "${root_ssh_key}" && ! -f "${root_ssh_key}" && -f "${config_dir}/${root_ssh_key}" ]]; then
    root_ssh_key="${config_dir}/${root_ssh_key}"
fi
# vfat may expose the file with an 8.3 short name; fall back to a case-insensitive match.
if [[ -n "${root_ssh_key}" && ! -f "${root_ssh_key}" ]]; then
    found="$(find "${config_dir}" -maxdepth 1 -iname "$(basename "${root_ssh_key}")" 2>/dev/null | head -n1)"
    [[ -n "${found}" ]] && root_ssh_key="${found}"
fi

[[ -n "${imgref}" ]] || die "no image reference (set BOOTC_INSTALL_IMGREF or bootc.install.imgref=)"
[[ -b "${device}" ]] || die "target device not found: ${device}"
if [[ -n "${root_ssh_key}" && ! -f "${root_ssh_key}" ]]; then
    die "root SSH key not found: ${root_ssh_key}"
fi

log "image=${imgref} device=${device} rootfs=${rootfs} action=${action}"
if [[ -n "${root_ssh_key}" ]]; then
    log "root SSH key: ${root_ssh_key}"
else
    log "root SSH key: (none)"
fi

# --- partition the disk (GPT: ESP + root) ----------------------------------
# The root partition MUST use the architecture-specific Discoverable Partitions
# Specification (DPS) type GUID. The sealed UKI cmdline has no `root=` argument (bootc
# rejects kargs with a UKI), so the initramfs finds the root filesystem via
# systemd-gpt-auto-generator, which only recognises the DPS root GUID. A generic Linux
# filesystem type (8300) is NOT discoverable and results in emergency mode
# ("Dependency failed for Initrd Root Device").
#   ESP  (EFI System Partition) = c12a7328-f81f-11d2-ba4b-00a0c93ec93b  (sgdisk ef00)
#   root (x86-64 root)          = 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
root_type_guid="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"  # DPS ROOT_X86_64
log "partitioning ${device}"
partprobe "${device}" 2>/dev/null || true
sgdisk --zap-all "${device}"
sgdisk --clear \
    --new=1:0:+512M --typecode=1:ef00 --change-name=1:EFI \
    --new=2:0:0     --typecode="2:${root_type_guid}" --change-name=2:root \
    "${device}"
partprobe "${device}"
# wait for the kernel to expose the partitions
for _i in $(seq 1 20); do
    [[ -b "${device}1" && -b "${device}2" ]] && break
    sleep 0.5
done
[[ -b "${device}1" && -b "${device}2" ]] || die "partitions did not appear for ${device}"

# --- filesystems ------------------------------------------------------------
log "creating filesystems"
mkfs.vfat -F32 -n EFI "${device}1"
case "${rootfs}" in
    ext4)  mkfs.ext4 -L root -F "${device}2" ;;
    xfs)   mkfs.xfs -f -L root "${device}2" ;;
    btrfs) mkfs.btrfs -f -L root "${device}2" ;;
    f2fs)  mkfs.f2fs -f -l root "${device}2" ;;
    *)     die "unsupported root filesystem: ${rootfs}" ;;
esac

# --- mount the target -------------------------------------------------------
target=/mnt/target
mkdir -p "${target}"
# Explicitly make the chosen filesystem's kernel module available before mounting.
# The live image's initramfs only bundles the live-image drivers (not every filesystem
# driver); for a module-backed filesystem the full module tree is under /usr/lib/modules
# only after switch-root, so `modprobe`+explicit `-t` avoids relying on mount auto-probe.
modprobe "${rootfs}" 2>/dev/null || true
mount -t "${rootfs}" "${device}2" "${target}"
mkdir -p "${target}/boot/efi"
mount "${device}1" "${target}/boot/efi"

root_uuid="$(blkid -s UUID -o value "${device}2")"
[[ -n "${root_uuid}" ]] || die "could not determine root UUID"
log "root UUID=${root_uuid}"
# --- install ----------------------------------------------------------------
# `bootc install` must run from inside the target container image (bootc reads the image's
# own layout/configuration). Pull the image into containers-storage and run it privileged
# with the target and /dev bind-mounted.
export CONTAINERS_STORAGE_CONF=/etc/containers/storage.conf
export TMPDIR=/var/tmp
mkdir -p "${TMPDIR}"

# Fetch the image into the installer's own containers-storage. `bootc install to-filesystem`
# runs as a self-install from *inside* this image, so the image must be present locally;
# podman resolves `--target-imgref`/the running image from this storage.
log "pulling ${imgref}"
skopeo copy \
    --src-tls-verify=false --dest-tls-verify=false \
    "docker://${imgref}" "containers-storage:${imgref}"

cleanup() {
    log "cleanup: unmounting target"
    umount "${target}/boot/efi" 2>/dev/null || true
    umount "${target}" 2>/dev/null || true
}
trap cleanup EXIT

# Install as a *self-install*: bootc runs from inside the sealed image itself. This is
# required for a UKI/sealed image. bootc inspects its own rootfs, finds the UKI at
# /boot/EFI/Linux/<kver>.efi (unified=true), and thereby auto-selects the composefs backend
# and systemd-boot. By contrast, the external-installer path (`--source-imgref`) sets
# target_rootfs=None, so bootc never sees the UKI and defaults to the ostree backend,
# failing with "Failed to find kernel in /usr/lib/modules, /usr/lib/ostree-boot or /boot".
#
# We therefore pass neither --source-imgref nor --composefs-backend: the backend must be
# derived from the image, not forced. Forcing it in this mode would bypass the UKI-driven
# digest/fs-verity handling. We also pass no --karg: with a UKI bootc rejects externally
# supplied kernel arguments ("Cannot use externally specified kernel arguments with UKI");
# the cmdline, including the composefs= digest, is embedded in the UKI.
# --allow-missing-verity is NOT passed, so fs-verity is enforced (ext4 supports it).
log "running bootc install to-filesystem (self-install from inside the image)"
# --skip-finalize: bootc's built-in finalization (fstrim + `mount -o remount,ro` + fsfreeze
# on the target) hangs when the target is bind-mounted from the installer host: the host
# still holds the filesystem writable, so the remount/fsfreeze blocks indefinitely. We
# therefore skip it inside the container and perform the finalization ourselves below, on
# the installer side, where we control the mounts. This is the documented use of
# --skip-finalize ("then the caller must do it").
podman run --rm --privileged --pid=host --ipc=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /etc/containers/storage.conf:/etc/containers/storage.conf:ro \
    -v "${target}:/target" \
    "${imgref}" \
    bootc install to-filesystem \
        --target-imgref "${imgref}" \
        --skip-finalize \
        /target

# `bootc install finalize` is an *ostree-backend* step: it loads an ostree sysroot
# (`ostree/repo`), which does not exist on the composefs backend. We therefore skip the
# separate finalize step for this sealed image (the `bootc.install.finalize` parameter is
# ignored; kept for interface stability).
if [[ "${finalize}" == "yes" ]]; then
    log "skipping 'bootc install finalize' (ostree-only; composefs finalizes differently)"
fi

# Root SSH key injection.
#
# `bootc install --root-ssh-authorized-keys` is only implemented for the *ostree* backend
# (crates/lib/src/install.rs: inject_root_ssh_authorized_keys is called from
# install_container, which the composefs path does not use). For the composefs backend we
# replicate bootc's own mechanism ourselves: write a systemd-tmpfiles drop-in into the
# target's /etc/tmpfiles.d that recreates /root/.ssh/authorized_keys on every boot.
#
# On the composefs backend /etc is NOT the plain ${target}/etc directory. At boot the
# initramfs bind-mounts the running /etc from the per-deployment state directory
# ${target}/state/deploy/<composefs-digest>/etc (see bootc initramfs `mount_subdir` and
# `bootc_composefs/state.rs`; the deployment digest equals the `composefs=` value baked into
# the UKI cmdline). Writes to ${target}/etc land in a directory nothing mounts, so the key
# would never appear on the running system. The same per-deployment directory is carried
# across `bootc switch`/upgrade via the three-way /etc merge, so a drop-in placed there is
# durable. There is exactly one deployment dir after a clean install, so we resolve it by
# globbing state/deploy/*.
if [[ -n "${root_ssh_key}" ]]; then
    log "injecting root SSH authorized_keys via tmpfiles"
    [[ -f "${root_ssh_key}" ]] || die "root SSH key not found: ${root_ssh_key}"

    # Locate the single composefs deployment's writable /etc backing store.
    deploy_etc=""
    for d in "${target}"/state/deploy/*; do
        [[ -d "${d}/etc" ]] || continue
        [[ -n "${deploy_etc}" ]] && die "multiple deployment state dirs under ${target}/state/deploy"
        deploy_etc="${d}/etc"
    done
    [[ -n "${deploy_etc}" ]] || die "no deployment state dir (${target}/state/deploy/*/etc) found"

    # systemd tmpfiles "f~" lines take the file contents base64-encoded (see systemd
    # CREDENTIALS / tmpfiles.d(5)).
    b64="$(base64 -w0 <"${root_ssh_key}")"
    # Resolve /root on the target; on a bootc image it is a symlink to var/roothome.
    if [[ -L "${target}/root" ]]; then
        roothome="$(readlink "${target}/root")"
    else
        roothome="root"
    fi
    # Declare the parent directory too (`d` line): tmpfiles "f~" does not create parent
    # directories, and /root/.ssh does not exist on a pristine bootc image.
    install -d -m 0755 "${deploy_etc}/tmpfiles.d"
    printf 'd /%s/.ssh 0700 root root -\nf~ /%s/.ssh/authorized_keys 600 root root - %s\n' \
        "${roothome}" "${roothome}" "${b64}" \
        > "${deploy_etc}/tmpfiles.d/bootc-root-ssh.conf"
    log "wrote ${deploy_etc}/tmpfiles.d/bootc-root-ssh.conf (-> /${roothome}/.ssh/authorized_keys)"
fi

# Finalization (replaces bootc's skipped --skip-finalize step): flush writes, then trim and
# remount the target read-only. Done last, after the SSH key injection above has written to
# the target's /etc. No fsfreeze: it can block while the target is mounted, and the clean
# remount/unmount flushes the journal anyway.
log "finalizing target filesystem (fstrim + remount ro)"
sync
fstrim --quiet-unsupported -v "${target}" 2>&1 | tail -1 || true
umount "${target}/boot/efi" 2>/dev/null || true
mount -o remount,ro "${target}" || true

cleanup
trap - EXIT

log "installation complete"
sync

case "${action}" in
    reboot)   log "rebooting"; systemctl reboot ;;
    poweroff) log "powering off"; systemctl poweroff ;;
    *)        die "unknown action: ${action}" ;;
esac
