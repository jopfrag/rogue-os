#!/usr/bin/env bash
# Report that a target is not implemented yet, and why.
#
# This exists so that the Makefile can expose the intended interface without
# silently pretending to succeed. It always exits non-zero.
set -euo pipefail

target="${1:?usage: not-implemented.sh <target> [missing-thing]}"
missing="${2:-}"

echo "make ${target}: not implemented yet" >&2
if [[ -n "${missing}" ]]; then
    echo "  (depends on: ${missing})" >&2
fi
echo "  see Containerfile.md for build rationale and CONTRIBUTING guidance" >&2
exit 1
