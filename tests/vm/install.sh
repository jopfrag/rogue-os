#!/usr/bin/env bash
# Boot the installer ISO in a disposable VM and install the CachyOS bootc image.
#
# Covers: create the VM, boot the installer, partition/format/mount the disk, run
# `bootc install to-filesystem` (+ finalize), then power off. On success the VM disk holds a
# bootable CachyOS bootc system; the VM is left defined (powered off) for the boot stage.
#
# Usage: tests/vm/install.sh [--keep] [--timeout SECONDS]
#
# Prints the VM name on the last line (consumed by tests/vm/run.sh).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=hack/lib/vm.sh
source "${repo_root}/hack/lib/vm.sh"

install_timeout=1500
keep=0
artifacts_opt=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=1; shift ;;
        --timeout) install_timeout="$2"; shift 2 ;;
        --artifacts) artifacts_opt="$2"; shift 2 ;;
        *) echo "usage: install.sh [--keep] [--timeout SECONDS] [--artifacts DIR]" >&2; exit 2 ;;
    esac
done

iso="${INSTALLER_ISO:-${repo_root}/artifacts/cachyos-bootc-installer.iso}"
vm_imgref="${VM_IMAGE_REF:-192.168.122.1:5000/cachyos-bootc:test}"
[[ -f "${iso}" ]] || { echo "installer ISO missing: ${iso} (run: make installer)" >&2; exit 1; }

# The live overlay pathspec depends on the ISO's volume label and UUID; export them so
# vm_create can seed the overlay disk with the directory structure dmsquash-live expects.
LIVE_LABEL="$(blkid -s LABEL -o value "${iso}")"
LIVE_UUID="$(blkid -s UUID -o value "${iso}")"
export LIVE_LABEL LIVE_UUID
[[ -n "${LIVE_LABEL}" && -n "${LIVE_UUID}" ]] || { echo "could not read ISO label/uuid" >&2; exit 1; }
echo "==> ISO live label=${LIVE_LABEL} uuid=${LIVE_UUID}"

run_id="t$(date +%s)-$$"
vm="cachyos-bootc-test-${run_id}"
if [[ -n "${artifacts_opt}" ]]; then
    artifacts="${artifacts_opt}"
    mkdir -p "${artifacts}"
    # Derive a stable VM name from a caller-supplied artifacts dir (for run.sh).
    vm="cachyos-bootc-test-$(basename "${artifacts}")"
else
    artifacts="${repo_root}/artifacts/${run_id}"
    mkdir -p "${artifacts}"
fi
console_log="${artifacts}/installer-console.log"
cfg_dir="${artifacts}/config"
mkdir -p "${cfg_dir}"

# Generate an ephemeral SSH keypair for this run. The public key is handed to the
# installer (written to the target via bootc's tmpfiles.d mechanism); the private key is
# kept for the boot/test stages. Never reused across runs.
ssh_key="${artifacts}/id_ed25519"
ssh-keygen -t ed25519 -N '' -C "cachyos-bootc-test-${run_id}" -f "${ssh_key}" >/dev/null
cp "${ssh_key}.pub" "${cfg_dir}/root_ssh_key.pub"
echo "==> SSH key: ${ssh_key}"

# The boot/test stages need the key path and VM name; record them for the caller.
state_file="${artifacts}/state.env"

echo "==> VM ${vm}"

cleanup() {
    local rc=$?
    if [[ "${keep}" -eq 1 ]]; then
        echo "==> --keep: leaving VM ${vm} (disk: ${VM_HOST_DIR_BASE}/${vm})"
    else
        echo "==> removing VM ${vm}"
        vm_destroy "${vm}"
    fi
    return "${rc}"
}
trap cleanup EXIT

# Installer parameters, provided via an attached BOOTCINSTALL FAT volume.
cat >"${cfg_dir}/install.env" <<EOF
BOOTC_INSTALL_IMGREF=${vm_imgref}
BOOTC_INSTALL_DEVICE=/dev/vda
BOOTC_INSTALL_ROOTFS=ext4
BOOTC_INSTALL_ACTION=poweroff
BOOTC_INSTALL_FINALIZE=yes
BOOTC_INSTALL_ROOT_SSH_KEY=root_ssh_key.pub
EOF
echo "    config: ${cfg_dir}/install.env"

echo "==> creating VM"
vm_overlay_size="${VM_OVERLAY_SIZE:-16G}"
disk_dir="$(vm_create "${vm}" 24G "${iso}" 2 4096 "${cfg_dir}")"
echo "    disk dir: ${disk_dir}"

echo "==> starting installer (timeout ${install_timeout}s)"
# Start the console capture first; it waits for the domain to be running. This gives us
# the full boot/install log and avoids racing `virsh start`.
( vm_capture_console "${vm}" "${install_timeout}" "${console_log}" ) &
console_pid=$!
vm_start "${vm}"

# Poll for completion: the installer powers the VM off when done.
deadline=$(( $(date +%s) + install_timeout ))
status="timeout"
while [[ $(date +%s) -lt ${deadline} ]]; do
    state="$(vm_domstate "${vm}")"
    case "${state}" in
        "shut off") status="shutoff"; break ;;
        "") status="gone"; break ;;
    esac
    sleep 5
done

# Give the console capture a moment to flush, then stop it.
sleep 3
kill "${console_pid}" 2>/dev/null || true
wait "${console_pid}" 2>/dev/null || true
pkill -f "virsh -c ${LIBVIRT_URI} console ${vm}" 2>/dev/null || true

# Always show the relevant installer output.
echo "==> installer console (install-bootc lines)"
tr -d '\r' <"${console_log}" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | grep -aE 'install-bootc|Kernel panic|Failed|Error|error' | tail -40 || true

if [[ "${status}" != "shutoff" ]]; then
    echo "==> installer did not complete (status=${status})" >&2
    echo "    full console: ${console_log}" >&2
    exit 1
fi

echo "==> installation finished; VM powered off"
echo "    console: ${console_log}"
# Record state for the boot/test stages and print the artifact directory on the last line.
cat >"${state_file}" <<EOF
VM_NAME=${vm}
VM_SSH_KEY=${ssh_key}
VM_SSH_AUTH=password
VM_SSH_PASS=bootc-test
VM_ARTIFACTS=${artifacts}
VM_IMAGE_REF=${vm_imgref}
EOF
echo "    state:   ${state_file}"
echo "${artifacts}"
