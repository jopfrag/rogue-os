#!/usr/bin/env bash
# Static checks: shell syntax for all project scripts, and (if available) shellcheck.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0

mapfile -t scripts < <(find "${repo_root}/hack" "${repo_root}/tests" -type f -name '*.sh' | sort)

echo "==> bash -n"
for f in "${scripts[@]}"; do
    if bash -n "${f}"; then
        echo "ok   ${f#"${repo_root}/"}"
    else
        echo "FAIL ${f#"${repo_root}/"}"
        fail=1
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "==> shellcheck"
    if shellcheck "${scripts[@]}"; then
        echo "ok   shellcheck"
    else
        fail=1
    fi
else
    echo "==> shellcheck not installed; skipping"
fi

exit "${fail}"
