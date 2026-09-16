#!/usr/bin/env bash
# Shared SSH helpers for test VMs.
#
# Sourced by test scripts. Uses key-based auth only: the installer injects an ephemeral
# public key at install time (see installer/stage/install-bootc.sh), and the matching
# private key is recorded in the run's state file (VM_SSH_KEY).
#
# Environment:
#   VM_SSH_USER   default: root
#   VM_SSH_KEY    path to a private key, required for ssh_guest

VM_SSH_USER="${VM_SSH_USER:-root}"
VM_SSH_KEY="${VM_SSH_KEY:-}"

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
# Run a command over SSH using the configured key.
ssh_guest() {
    local name="$1"; shift
    [[ -n "${VM_SSH_KEY}" ]] || { echo "no SSH key configured (VM_SSH_KEY)" >&2; return 1; }
    local ip
    ip="$(ssh_guest_ip "${name}")" || { echo "sshd not reachable on ${name}" >&2; return 1; }

    local -a opts
    mapfile -t opts < <(_ssh_opts)
    ssh "${opts[@]}" -o IdentitiesOnly=yes -i "${VM_SSH_KEY}" \
        "${VM_SSH_USER}@${ip}" "$@"
}
