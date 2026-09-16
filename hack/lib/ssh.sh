#!/usr/bin/env bash
# Shared SSH helpers for test VMs.
#
# Sourced by test scripts. Supports key-based auth (preferred) and password auth
# (bring-up fallback while key injection is being reworked; see TASKS.md Task 28).
#
# Environment:
#   VM_SSH_USER   default: root
#   VM_SSH_KEY    path to a private key, if any
#   VM_SSH_PASS   password to use if no key is configured

VM_SSH_USER="${VM_SSH_USER:-root}"
VM_SSH_KEY="${VM_SSH_KEY:-}"
VM_SSH_PASS="${VM_SSH_PASS:-}"
# VM_SSH_AUTH: 'key' or 'password'. If unset, it is derived at call time: key when a key
# is configured, else password. This allows a state file sourced after this library to
# change the effective method.
VM_SSH_AUTH="${VM_SSH_AUTH:-}"

# _ssh_resolve_auth: set VM_SSH_AUTH if unset.
_ssh_resolve_auth() {
    if [[ -z "${VM_SSH_AUTH}" ]]; then
        if [[ -n "${VM_SSH_KEY}" ]]; then VM_SSH_AUTH=key; else VM_SSH_AUTH=password; fi
    fi
}

# ssh_guest_ip <vm-name> [timeout-seconds]
# Resolve the guest's IPv4 address from libvirt DHCP leases, polling until sshd accepts
# a TCP connection on port 22. Prints the IP on stdout.
ssh_guest_ip() {
    local name="$1" timeout="${2:-180}"
    local deadline=$(( $(date +%s) + timeout )) ip=""
    while [[ $(date +%s) -lt ${deadline} ]]; do
        ip="$(virsh_cmd domifaddr "${name}" --source lease 2>/dev/null \
            | awk '/ipv4/{print $4}' | cut -d/ -f1 | grep -v '^$' | tail -n1)"
        if [[ -n "${ip}" ]] && timeout 5 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then
            echo "${ip}"
            return 0
        fi
        sleep 5
    done
    return 1
}

# _ssh_opts: common non-interactive options.
_ssh_opts() {
    printf '%s\n' \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=15
}

# ssh_guest <vm-name> <command...>
# Run a command over SSH, using the key if configured, else the password.
ssh_guest() {
    local name="$1"; shift
    _ssh_resolve_auth
    local ip
    ip="$(ssh_guest_ip "${name}")" || { echo "sshd not reachable on ${name}" >&2; return 1; }

    if [[ "${VM_SSH_AUTH}" == "key" ]]; then
        local -a opts
        mapfile -t opts < <(_ssh_opts)
        ssh "${opts[@]}" -o IdentitiesOnly=yes -i "${VM_SSH_KEY}" \
            "${VM_SSH_USER}@${ip}" "$@"
        return
    fi

    # Password auth via a small python pty driver (no sshpass dependency).
    VM_SSH_PASS="${VM_SSH_PASS}" python3 - "${ip}" "${VM_SSH_USER}" "$@" <<'PY'
import sys, pty, os, select, time
ip, user = sys.argv[1], sys.argv[2]
remote_cmd = " ".join(sys.argv[3:]) if len(sys.argv) > 3 else "true"
password = os.environ.get("VM_SSH_PASS", "")
argv = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=15",
        "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
        f"{user}@{ip}", remote_cmd]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("ssh", argv)
buf = b""
sent = False
rc = 1
deadline = time.time() + 120
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if fd in r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if data:
            buf += data
            if b"password:" in buf.lower() and not sent:
                os.write(fd, (password + "\n").encode()); sent = True
        else:
            # EOF on the pty: the child is exiting; reap it below.
            wpid, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
            break
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid:
        rc = os.waitstatus_to_exitcode(status)
        # Drain any remaining output.
        while True:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            buf += d
        break
else:
    # Timed out: kill and reap.
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    rc = 124
# Strip the local pty echo of the password prompt (and the trailing CR) for clean output.
text = buf.decode(errors="replace")
lines = [ln for ln in text.splitlines() if "password:" not in ln.lower()]
sys.stdout.write("\n".join(lines))
if lines:
    sys.stdout.write("\n")
sys.exit(rc)
PY
}
