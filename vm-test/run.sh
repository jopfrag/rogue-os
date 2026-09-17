#!/usr/bin/env bash
# End-to-end disposable-VM workflow: build-check, install, boot, verify.
#
#   registry reachable -> install (installer ISO -> disk) -> boot from disk -> smoke test
#
# Every resource is uniquely named and removed on exit (unless --keep). On failure the
# artifact directory (console logs, diagnostics) is preserved.
#
# Usage: vm-test/run.sh [--keep] [--image REF] [--iso PATH]
set -euo pipefail

vmtest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${vmtest_dir}/.." && pwd)"
# shellcheck source=config.env
source "${vmtest_dir}/config.env"
# shellcheck source=lib/vm.sh
source "${vmtest_dir}/lib/vm.sh"

keep=0
image="${VM_IMAGE}"
iso="${INSTALLER_ISO}"
mode="smoke"
to_image=""
rollback=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=1; shift ;;
        --image) image="$2"; shift 2 ;;
        --iso) iso="$2"; shift 2 ;;
        --update) mode="update"; shift ;;
        --to) to_image="$2"; shift 2 ;;
        --rollback) rollback=1; shift ;;
        *) echo "usage: run.sh [--keep] [--image REF] [--iso PATH] [--update] [--to REF] [--rollback]" >&2; exit 2 ;;
    esac
done

[[ -f "${iso}" ]] || { echo "installer ISO missing: ${iso} (run: make installer)" >&2; exit 1; }

# --- registry reachability (precondition for the guest pull) -----------------
reg_host="${image%%/*}"; reg_host="${reg_host%%:*}"
if ! timeout 5 bash -c "echo > /dev/tcp/${reg_host}/5000" 2>/dev/null; then
    echo "run.sh: registry ${reg_host}:5000 not reachable (run: make registry-push)" >&2
    exit 1
fi

artifacts=""
cleanup() {
    local rc=$?
    if [[ -n "${artifacts}" && -f "${artifacts}/state.env" ]]; then
        # shellcheck disable=SC1090,SC1091
        source "${artifacts}/state.env"
        if [[ "${keep}" -eq 1 ]]; then
            echo "==> --keep: leaving VM ${VM_NAME} (disk: ${VM_HOST_DIR_BASE}/${VM_NAME})"
        else
            echo "==> removing VM ${VM_NAME}"
            vm_destroy "${VM_NAME}" || true
        fi
    fi
    if [[ "${rc}" -ne 0 ]]; then
        echo "run.sh: FAILED (exit ${rc}); artifacts: ${artifacts:-<none>}" >&2
    fi
    return "${rc}"
}
trap cleanup EXIT

artifacts="${ARTIFACTS:-${repo_root}/artifacts/t$(date +%s)-$$}"
mkdir -p "${artifacts}"

echo "==> [1/3] install"
export ROOTFS="${ROOTFS:-}"
INSTALLER_ISO="${iso}" VM_IMAGE_REF="${image}" "${vmtest_dir}/install.sh" --keep --artifacts "${artifacts}" >/tmp/run-install.log 2>&1 || {
    tail -30 /tmp/run-install.log >&2; exit 1
}
[[ -f "${artifacts}/state.env" ]] || { echo "run.sh: no state file from install" >&2; exit 1; }

echo "==> [2/3] boot"
"${vmtest_dir}/boot.sh" --state "${artifacts}/state.env" --timeout 180 >/tmp/run-boot.log 2>&1 || {
    tail -30 /tmp/run-boot.log >&2; exit 1
}
ip="$(tail -n1 /tmp/run-boot.log)"
echo "    guest IP: ${ip}"

echo "==> [3/3] smoke test"
"${vmtest_dir}/smoke.sh" --state "${artifacts}/state.env"

if [[ "${mode}" == "update" ]]; then
    echo
    echo "==> [4/4] update test"
    if [[ -n "${to_image}" ]]; then
        "${vmtest_dir}/upgrade.sh" --state "${artifacts}/state.env" --to "${to_image}"
    else
        "${vmtest_dir}/upgrade.sh" --state "${artifacts}/state.env"
    fi
fi

if [[ "${rollback}" -eq 1 ]]; then
    echo
    echo "==> [5/5] rollback test"
    "${vmtest_dir}/rollback.sh" --state "${artifacts}/state.env" --expect-version 1
fi

echo
echo "==> end-to-end OK (artifacts: ${artifacts})"
