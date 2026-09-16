#!/usr/bin/env bash
# Local OCI registry for the VM workflow.
#
# The registry runs as a podman container in this development environment. Because this
# container shares the host's network namespace, the registry is reachable from test VMs
# on the libvirt bridge at 192.168.122.1:<port>.
#
# Networking note (see docs/development.md): inbound TCP from the libvirt bridge to a
# host-bound service is blocked while the host firewall (firewalld) is running. Firewalld
# is assumed to be stopped for this workflow.
#
# Usage:
#   hack/registry.sh start [port]
#   hack/registry.sh stop
#   hack/registry.sh status
#   hack/registry.sh push <image> [host-prefix]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container_name="cachyos-bootc-registry"
port="${REGISTRY_PORT:-5000}"
data_dir="${repo_root}/registry-data"
bind_addr="${REGISTRY_BIND_ADDR:-0.0.0.0}"

# Address the VM uses to reach the registry (the libvirt bridge gateway).
vm_registry_host="${VM_REGISTRY_HOST:-192.168.122.1}"

require_podman() {
    command -v podman >/dev/null 2>&1 || { echo "podman not found" >&2; exit 1; }
}

registry_running() {
    [ "$(podman inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null || echo false)" = "true" ]
}

cmd_start() {
    require_podman
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        port="$1"
    fi

    mkdir -p "${data_dir}"

    if podman container exists "${container_name}"; then
        if registry_running; then
            echo "registry already running on ${bind_addr}:${port}"
            return 0
        fi
        podman rm -f "${container_name}" >/dev/null
    fi

    echo "==> starting registry ${container_name} on ${bind_addr}:${port}"
    # --network host so the registry listens on the host/VM-facing addresses directly.
    # :z relabels the data dir for the container.
    podman run -d \
        --name "${container_name}" \
        --replace \
        --network host \
        -v "${data_dir}:/var/lib/registry:z" \
        -e REGISTRY_HTTP_ADDR="${bind_addr}:${port}" \
        docker.io/library/registry:2 >/dev/null

    # Wait for the registry to answer.
    local _i
    for _i in $(seq 1 30); do
        if curl -fsS "http://${vm_registry_host}:${port}/v2/" >/dev/null 2>&1 \
           || curl -fsS "http://127.0.0.1:${port}/v2/" >/dev/null 2>&1; then
            echo "registry ready at ${vm_registry_host}:${port}"
            return 0
        fi
        sleep 1
    done

    echo "registry did not become ready" >&2
    podman logs --tail 30 "${container_name}" >&2 || true
    return 1
}

cmd_stop() {
    require_podman
    if podman container exists "${container_name}"; then
        echo "==> stopping registry ${container_name}"
        podman rm -f "${container_name}" >/dev/null
    else
        echo "registry not present"
    fi
}

cmd_status() {
    require_podman
    if registry_running; then
        echo "running: ${container_name} (${vm_registry_host}:${port})"
        curl -fsS "http://${vm_registry_host}:${port}/v2/" >/dev/null 2>&1 \
            && echo "reachable: yes" || echo "reachable: no"
    else
        echo "not running"
    fi
}

cmd_push() {
    require_podman
    local image="${1:?usage: registry.sh push <image> [host-prefix]}"
    local host="${2:-${vm_registry_host}:${port}}"

    podman image exists "${image}" || { echo "image not found: ${image}" >&2; exit 1; }

    # The VM must pull by IP (not "localhost") and over plain HTTP.
    podman tag "${image}" "${host}/cachyos-bootc:test"
    echo "==> pushing ${host}/cachyos-bootc:test"
    podman push --tls-verify=false "${host}/cachyos-bootc:test"
    echo "pushed: ${host}/cachyos-bootc:test"
}

case "${1:-}" in
    start)  shift; cmd_start "$@" ;;
    stop)   shift; cmd_stop "$@" ;;
    status) shift; cmd_status "$@" ;;
    push)   shift; cmd_push "$@" ;;
    *)
        echo "usage: registry.sh {start [port]|stop|status|push <image> [host-prefix]}" >&2
        exit 2
        ;;
esac
