#!/usr/bin/env bash
# Open an interactive SSH session on a running, installed test VM.
#
# Usage: hack/vm-shell.sh [VM_NAME]
#   VM_NAME  a running cachyos-bootc-test-* domain. If omitted and exactly one such domain
#            is running, it is used.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vm.sh
# shellcheck disable=SC1091
source "${repo_root}/hack/lib/vm.sh"

vm="${1:-}"
if [[ -z "${vm}" ]]; then
    mapfile -t running < <(virsh_cmd list --name 2>/dev/null | grep '^cachyos-bootc-test-' || true)
    case "${#running[@]}" in
        0) echo "vm-shell: no running cachyos-bootc-test-* VM" >&2; exit 1 ;;
        1) vm="${running[0]}" ;;
        *) echo "vm-shell: multiple candidates; pass VM=<name>. Found: ${running[*]}" >&2; exit 1 ;;
    esac
fi
virsh_cmd domstate "${vm}" >/dev/null 2>&1 || { echo "vm-shell: no such domain: ${vm}" >&2; exit 1; }

ip="$(virsh_cmd domifaddr "${vm}" --source lease 2>/dev/null \
    | awk '/ipv4/{print $4}' | cut -d/ -f1 | grep -v '^$' | tail -n1)"
[[ -n "${ip}" ]] || { echo "vm-shell: no DHCP lease for ${vm}" >&2; exit 1; }

echo "==> connecting to ${vm} (${ip})"
exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "root@${ip}"
