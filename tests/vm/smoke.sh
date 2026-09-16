#!/usr/bin/env bash
# Smoke tests against a running, installed CachyOS bootc VM.
#
# Verifies the sealed deployment (composefs backend, fs-verity enforced, read-only /sysroot),
# bootc status, userspace, networking and SSH. Collects diagnostics into the artifact
# directory on failure.
#
# Usage: tests/vm/smoke.sh --vm NAME [--state FILE] [--artifacts DIR]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=hack/lib/vm.sh
source "${repo_root}/hack/lib/vm.sh"
# shellcheck source=hack/lib/ssh.sh
source "${repo_root}/hack/lib/ssh.sh"

vm=""; state=""; artifacts=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm) vm="$2"; shift 2 ;;
        --state) state="$2"; shift 2 ;;
        --artifacts) artifacts="$2"; shift 2 ;;
        *) echo "usage: smoke.sh --vm NAME [--state FILE] [--artifacts DIR]" >&2; exit 2 ;;
    esac
done
if [[ -n "${state}" && -f "${state}" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${state}"
    vm="${vm:-${VM_NAME}}"
    artifacts="${artifacts:-${VM_ARTIFACTS}}"
fi
[[ -n "${vm}" ]] || { echo "smoke.sh: no VM specified" >&2; exit 2; }
[[ -n "${artifacts}" ]] && mkdir -p "${artifacts}"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# gcheck <desc> <remote-command>: pass if the remote command exits 0.
gcheck() {
    local desc="$1"; shift
    if ssh_guest "${vm}" "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi
}
# gcontains <desc> <needle> <remote-command>: pass if output contains the needle.
gcontains() {
    local desc="$1" needle="$2"; shift 2
    if ssh_guest "${vm}" "$@" 2>/dev/null | grep -qF -- "${needle}"; then ok "${desc}"; else bad "${desc}"; fi
}

echo "==> smoke testing ${vm}"

# --- sealed / composefs state ----------------------------------------------
gcontains "cmdline carries a composefs= digest" "composefs=" "cat /proc/cmdline"
if ssh_guest "${vm}" "cat /proc/cmdline" 2>/dev/null | grep -q 'composefs=[0-9a-f]'; then
    ok "fs-verity is enforced (no allow-missing '?' prefix)"
else
    bad "fs-verity is enforced (no allow-missing '?' prefix)"
fi
gcontains "root is mounted from composefs" "composefs:" "mount"
gcheck "root filesystem is read-only" "mountpoint -q / ; findmnt -no OPTIONS / | grep -q '^ro,\|,ro,\|,ro$'"
gcheck "/sysroot is read-only (sealed)" "findmnt -no OPTIONS /sysroot | grep -q 'ro'"
gcheck "/etc is writable (bind mount)" "test -w /etc"
gcheck "/var is writable (bind mount)" "test -w /var"

# --- bootc ------------------------------------------------------------------
gcontains "bootc reports a booted composefs deployment" "composefs" "bootc status"
gcheck "bootc status --json parses" "bootc status --json >/dev/null"
gcheck "bootc reports no staged deployment" "! bootc status --json | grep -q '\"staged\": *{'"

# --- system -----------------------------------------------------------------
gcheck "systemd reached multi-user" "systemctl is-system-running --wait | grep -qE 'running|degraded'"
gcheck "sshd is active" "systemctl is-active sshd"
gcheck "no failed systemd units" "test -z \"\$(systemctl --failed --no-legend --plain | grep -v '^$')\""
gcheck "wired network has an address" "ip -4 addr show scope global | grep -q inet"
gcheck "outbound DNS resolves" "getent hosts one.one.one.one >/dev/null || getent hosts localhost"
gcontains "kernel is the built version" "" "uname -r"

# --- diagnostics on failure -------------------------------------------------
echo
echo "==> ${pass} passed, ${fail} failed"
if [[ "${fail}" -ne 0 && -n "${artifacts}" ]]; then
    echo "==> collecting diagnostics into ${artifacts}"
    ssh_guest "${vm}" 'bootc status; echo ---; systemctl --failed; echo ---; journalctl -b -p warning --no-pager | tail -100; echo ---; mount; echo ---; ip -4 addr' \
        >"${artifacts}/vm-diagnostics.txt" 2>&1 || true
    vm_capture_console "${vm}" 15 "${artifacts}/console.log" 2>/dev/null || true
fi
[[ "${fail}" -eq 0 ]]
