#!/usr/bin/env bash
# Boot the installed CachyOS bootc system from its disk and wait for SSH.
#
# Consumes the state file written by vm-test/install.sh (or takes --vm NAME). Detaches
# the installer media, boots from disk, and waits until the guest's sshd is reachable.
# Prints the guest IP on the last line.
#
# Usage: vm-test/boot.sh [--vm NAME] [--state FILE] [--timeout SECONDS]
set -euo pipefail

vmtest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm.sh
source "${vmtest_dir}/lib/vm.sh"
# shellcheck source=lib/ssh.sh
source "${vmtest_dir}/lib/ssh.sh"

vm=""; state=""; boot_timeout=180
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm) vm="$2"; shift 2 ;;
        --state) state="$2"; shift 2 ;;
        --timeout) boot_timeout="$2"; shift 2 ;;
        *) echo "usage: boot.sh [--vm NAME] [--state FILE] [--timeout SECONDS]" >&2; exit 2 ;;
    esac
done

if [[ -z "${vm}" && -n "${state}" && -f "${state}" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${state}"
    vm="${VM_NAME}"
fi
[[ -n "${vm}" ]] || { echo "boot.sh: no VM specified (--vm or --state)" >&2; exit 2; }
vm_domain_exists "${vm}" || { echo "boot.sh: domain not found: ${vm}" >&2; exit 1; }

echo "==> booting ${vm} from disk"
vm_boot_from_disk "${vm}"

echo "==> waiting for SSH"
ip="$(ssh_guest_ip "${vm}" "${boot_timeout}")" || {
    echo "boot.sh: sshd not reachable within ${boot_timeout}s" >&2
    vm_capture_console "${vm}" 20 "/tmp/${vm}-boot-fail.log" 2>/dev/null || true
    exit 1
}
echo "==> guest is up at ${ip}"
echo "${ip}"
