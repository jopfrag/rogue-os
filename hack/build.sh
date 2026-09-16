#!/usr/bin/env bash
# Build the CachyOS bootc OCI image.
#
# Usage: hack/build.sh [IMAGE_TAG]
#   IMAGE_TAG  defaults to $IMAGE or localhost:5000/cachyos-bootc:test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-${IMAGE:-localhost:5000/cachyos-bootc:test}}"

command -v podman >/dev/null 2>&1 || { echo "podman not found" >&2; exit 1; }

echo "==> building ${image}"
podman build \
    --tag "${image}" \
    --file "${repo_root}/Containerfile" \
    "${repo_root}"

echo "==> built ${image}"
