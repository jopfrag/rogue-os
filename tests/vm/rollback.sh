#!/usr/bin/env bash
# Task 21 — rollback test against a running, installed VM.
#
# Assumes a VM that has been updated (v1 -> v2) and is now booted into v2 (see
# tests/vm/upgrade.sh). Runs `bootc rollback`, reboots, and verifies the previous version
# (v1) is booted again.
#
# Usage: tests/vm/rollback.sh --state FILE [--expect-version 1]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=hack/lib/vm.sh
source "${repo_root}/hack/lib/vm.sh"
# shellcheck source=hack/lib/ssh.sh
source "${repo_root}/hack/lib/ssh.sh"

state=""; expect=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state) state="$2"; shift 2 ;;
        --expect-version) expect="$2"; shift 2 ;;
        *) echo "usage: rollback.sh --state FILE [--expect-version N]" >&2; exit 2 ;;
    esac
done
[[ -n "${state}" && -f "${state}" ]] || { echo "rollback.sh: --state FILE required" >&2; exit 2; }
# shellcheck disable=SC1090,SC1091
source "${state}"
: "${VM_NAME:?state file missing VM_NAME}"

echo "==> BEFORE: booted version"
before="$(ssh_guest "${VM_NAME}" 'cat /usr/lib/bootc-image-version' 2>/dev/null | tr -d '[:space:]')"
echo "    version=${before}"

echo "==> bootc rollback"
ssh_guest "${VM_NAME}" 'bootc rollback' 2>&1 | tail -5

echo "==> rebooting"
ssh_guest "${VM_NAME}" 'systemctl reboot' >/dev/null 2>&1 || true
sleep 5

echo "==> waiting for the rebooted system"
ip="$(ssh_guest_ip "${VM_NAME}" 240)" || { echo "sshd not reachable after rollback" >&2; exit 1; }
echo "    guest at ${ip}"

after="$(ssh_guest "${VM_NAME}" 'cat /usr/lib/bootc-image-version' 2>/dev/null | tr -d '[:space:]')"
echo "==> AFTER: booted version=${after}"

if [[ "${after}" == "${expect}" ]]; then
    echo "ok   rolled back to version ${expect}"
    exit 0
else
    echo "FAIL expected version ${expect} after rollback (got '${after}')" >&2
    exit 1
fi
