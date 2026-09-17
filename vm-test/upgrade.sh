#!/usr/bin/env bash
# v1 -> v2 update test against a running, installed VM.
#
# Assumes a VM installed from the v1 image (see vm-test/run.sh --image ...:v1), boots it,
# then `bootc switch`-es to the v2 image, reboots, and verifies the new version is booted.
#
# Usage: vm-test/upgrade.sh --state FILE [--to REF] [--from-version 1] [--to-version 2]
set -euo pipefail

vmtest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "${vmtest_dir}/config.env"
# shellcheck source=lib/vm.sh
source "${vmtest_dir}/lib/vm.sh"
# shellcheck source=lib/ssh.sh
source "${vmtest_dir}/lib/ssh.sh"

state=""; to=""; from_version=1; to_version=2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state) state="$2"; shift 2 ;;
        --to) to="$2"; shift 2 ;;
        --from-version) from_version="$2"; shift 2 ;;
        --to-version) to_version="$2"; shift 2 ;;
        *) echo "usage: upgrade.sh --state FILE [--to REF]" >&2; exit 2 ;;
    esac
done
[[ -n "${state}" && -f "${state}" ]] || { echo "upgrade.sh: --state FILE required" >&2; exit 2; }
# shellcheck disable=SC1090,SC1091
source "${state}"
: "${VM_NAME:?state file missing VM_NAME}"
to="${to:-${VM_IMAGE_V2}}"

echo "==> BEFORE: booted version"
before="$(ssh_guest "${VM_NAME}" 'cat /usr/lib/bootc-image-version' 2>/dev/null | tr -d '[:space:]')"
echo "    version=${before}"
[[ "${before}" == "${from_version}" ]] || {
    echo "upgrade.sh: expected booted version ${from_version}, got '${before}'" >&2; exit 1; }

echo "==> staging ${to}"
# The local test registry is served over plain HTTP. The production image deliberately does
# NOT bake in an insecure-registry entry, so the test configures it on the guest first
# (/etc is writable machine-local state).
ssh_guest "${VM_NAME}" "install -d /etc/containers/registries.conf.d && printf '[[registry]]\\nlocation = \"${to%%/*}\"\\ninsecure = true\\n' > /etc/containers/registries.conf.d/10-local.conf" 2>&1 | tail -3
ssh_guest "${VM_NAME}" "bootc switch --transport registry ${to}" 2>&1 | tail -5

echo "==> staged state"
ssh_guest "${VM_NAME}" 'bootc status' 2>&1 | sed -n '/staged:/,/^  [a-z]/p' | head -15

echo "==> rebooting"
ssh_guest "${VM_NAME}" 'systemctl reboot' >/dev/null 2>&1 || true
sleep 5
vm="${VM_NAME}"
vm_domain_exists "${vm}" || { echo "VM gone after reboot" >&2; exit 1; }

echo "==> waiting for the rebooted system"
ip="$(ssh_guest_ip "${vm}" 240)" || { echo "sshd not reachable after update" >&2; exit 1; }
echo "    guest at ${ip}"

after="$(ssh_guest "${VM_NAME}" 'cat /usr/lib/bootc-image-version' 2>/dev/null | tr -d '[:space:]')"
echo "==> AFTER: booted version=${after}"

ok=0
if [[ "${after}" == "${to_version}" ]]; then
    echo "ok   booted version is now ${to_version}"
else
    echo "FAIL booted version is ${to_version} (got '${after}')" >&2; ok=1
fi
if ssh_guest "${VM_NAME}" 'bootc status --json' 2>/dev/null | grep -q '"staged": *null'; then
    echo "ok   no staged deployment after update"
else
    echo "FAIL no staged deployment after update" >&2; ok=1
fi

exit "${ok}"
