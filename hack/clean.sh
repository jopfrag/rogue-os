#!/usr/bin/env bash
# Remove local build and test artifacts.
#
# Only removes paths that belong to this project inside the repository. It never
# touches libvirt domains, the host's /var/tmp VM storage, or anything else owned
# by another process. VM/registry cleanup is handled by the respective scripts.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for path in \
    "${repo_root}/artifacts" \
    "${repo_root}/vm" \
    "${repo_root}/output" \
    "${repo_root}/registry-data" \
    "${repo_root}/tests/keys"; do
    if [[ -e "${path}" ]]; then
        echo "removing ${path}"
        rm -rf "${path}"
    fi
done

echo "clean: done"
