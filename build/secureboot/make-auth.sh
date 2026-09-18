#!/usr/bin/env bash
# Generate the Secure Boot enrollment files (PK.auth, KEK.auth, db.auth) that
# bootc copies onto the ESP.
#
#   ./make-auth.sh <keys-dir> [output-dir]
#
# <keys-dir> must hold the private keys and their certificates:
#
#   pk.key  pk.crt   kek.key  kek.crt   db.key  db.crt
#
# If db.crt is absent there, the copy committed next to this script
# (build/secureboot/db.crt) is used.
#
# output-dir defaults to
#   <repo>/root/usr/lib/bootc/install/secureboot-keys/auto
#
# Only the resulting *.auth files (public, signed UEFI authenticated-variable
# updates) are committed; the private keys never enter git or the image.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

usage() {
    echo "usage: $(basename "$0") <keys-dir> [output-dir]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
keys_dir="$1"
out_dir="${2:-${repo_root}/root/usr/lib/bootc/install/secureboot-keys/auto}"

[[ -d "${keys_dir}" ]] || { echo "error: keys dir not found: ${keys_dir}" >&2; exit 1; }

for tool in uuidgen cert-to-efi-sig-list sig-list-to-certs sbvarsign; do
    command -v "${tool}" >/dev/null \
        || { echo "error: ${tool} not found (need efitools, sbsigntools and util-linux)" >&2; exit 1; }
done

for f in pk.key pk.crt kek.key kek.crt db.key; do
    [[ -f "${keys_dir}/${f}" ]] || { echo "error: missing ${keys_dir}/${f}" >&2; exit 1; }
done
db_crt="${keys_dir}/db.crt"
[[ -f "${db_crt}" ]] || db_crt="${script_dir}/db.crt"
[[ -f "${db_crt}" ]] || { echo "error: db.crt not found (in ${keys_dir} or ${script_dir})" >&2; exit 1; }

# Fresh SignatureOwner GUID recorded in every EFI_SIGNATURE_LIST.
guid="$(uuidgen)"
echo "SignatureOwner GUID: ${guid}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cert-to-efi-sig-list -g "${guid}" "${keys_dir}/pk.crt"  "${work}/pk.esl"
cert-to-efi-sig-list -g "${guid}" "${keys_dir}/kek.crt" "${work}/kek.esl"
cert-to-efi-sig-list -g "${guid}" "${db_crt}"           "${work}/db.esl"

# A one-cert list is 44 bytes of header plus the DER certificate (~1 KiB).
# Exactly 44 bytes means cert-to-efi-sig-list received an empty/invalid cert.
for name in pk kek db; do
    size="$(stat -c%s "${work}/${name}.esl")"
    if (( size <= 44 )); then
        echo "error: ${name}.esl is ${size} bytes: no certificate (check the ${name} cert)" >&2
        exit 1
    fi
    sig-list-to-certs "${work}/${name}.esl" "${work}/${name}-check" >/dev/null 2>&1
    [[ -s "${work}/${name}-check-0.der" ]] \
        || { echo "error: ${name}.esl carries no certificate" >&2; exit 1; }
done

# The PK signs PK and KEK; the KEK signs db.
sbvarsign --key "${keys_dir}/pk.key"  --cert "${keys_dir}/pk.crt"  PK  "${work}/pk.esl"  --output "${work}/PK.auth"
sbvarsign --key "${keys_dir}/pk.key"  --cert "${keys_dir}/pk.crt"  KEK "${work}/kek.esl" --output "${work}/KEK.auth"
sbvarsign --key "${keys_dir}/kek.key" --cert "${keys_dir}/kek.crt" db  "${work}/db.esl"  --output "${work}/db.auth"

install -d -m 0755 "${out_dir}"
install -m 0644 "${work}/PK.auth" "${work}/KEK.auth" "${work}/db.auth" "${out_dir}/"
echo "wrote PK.auth, KEK.auth, db.auth to ${out_dir}"
