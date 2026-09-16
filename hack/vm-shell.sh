#!/usr/bin/env bash
# Open an interactive SSH session on a running, installed test VM.
#
# Usage: hack/vm-shell.sh [VM_NAME] [STATE_FILE]
#   VM_NAME   a running cachyos-bootc-test-* domain. If omitted and exactly one such
#             domain is running, it is used.
#   STATE_FILE  path to a run's state.env (sets VM_SSH_KEY). Optional; if omitted, the
#             most recent artifacts/*/state.env is used.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vm.sh
# shellcheck disable=SC1091
source "${repo_root}/hack/lib/vm.sh"
source "${repo_root}/hack/lib/ssh.sh"

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

# Resolve an SSH key from an explicit state file, else the most recent one.
state="${2:-}"
if [[ -z "${state}" ]]; then
    state="$(find "${repo_root}/artifacts" -maxdepth 2 -name state.env -printf '%T@ %p\n' \
        2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
fi
if [[ -n "${state}" && -f "${state}" ]]; then
    # shellcheck disable=SC1090
    source "${state}"
fi
[[ -n "${VM_SSH_KEY:-}" ]] || { echo "vm-shell: no VM_SSH_KEY (pass a state.env path)" >&2; exit 1; }

ip="$(ssh_guest_ip "${vm}" 60)" || { echo "vm-shell: no SSH on ${vm}" >&2; exit 1; }

echo "==> connecting to ${vm} (${ip})"
exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -i "${VM_SSH_KEY}" \
    "${VM_SSH_USER}@${ip}"
