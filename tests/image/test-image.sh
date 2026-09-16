#!/usr/bin/env bash
# Fast, VM-less validation of the CachyOS bootc OCI image.
#
# Checks the image the same way bootc and the installed system will use it: metadata,
# kernel/initramfs, filesystem layout, required packages/files/services and bootc
# functionality. Runs entirely with podman; no VM required.
#
# Usage: tests/image/test-image.sh [IMAGE]
# Exits non-zero if any check fails.
set -euo pipefail

image="${1:-${IMAGE:-localhost:5000/cachyos-bootc:test}}"

command -v podman >/dev/null 2>&1 || { echo "podman not found" >&2; exit 1; }
podman image exists "${image}" || { echo "image not found: ${image}" >&2; exit 1; }

failures=0
checks=0

# pass/show a successful check
ok() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
# record a failure and show why
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf 'FAIL %s\n' "$1"; }

# check <description> <command...>: run a command inside the image; success == pass.
check() {
    local desc="$1"; shift
    if podman run --rm "${image}" "$@" >/dev/null 2>&1; then
        ok "${desc}"
    else
        fail "${desc}"
    fi
}

# check_contains <description> <path> <expected-substring>
check_contains() {
    local desc="$1" path="$2" needle="$3" out
    if out="$(podman run --rm "${image}" cat "${path}" 2>/dev/null)" && grep -qF -- "${needle}" <<<"${out}"; then
        ok "${desc}"
    else
        fail "${desc}"
    fi
}

echo "==> validating image ${image}"

# --- OCI / bootc metadata ---------------------------------------------------
label="$(podman inspect "${image}" --format '{{ index .Config.Labels "containers.bootc" }}' 2>/dev/null || true)"
if [[ "${label}" == "1" ]]; then
    ok "label containers.bootc=1"
else
    fail "label containers.bootc=1 (got '${label}')"
fi

check "bootc binary is installed" test -x /usr/bin/bootc
if ver="$(podman run --rm "${image}" bootc --version 2>/dev/null)" && [[ "${ver}" == bootc* ]]; then
    ok "bootc --version works (${ver})"
else
    fail "bootc --version works"
fi

# --- kernel and UKI (sealed image) ------------------------------------------
# The sealed image ships the kernel inside an unsigned Unified Kernel Image at
# /boot/EFI/Linux/<kver>.efi; the raw vmlinuz/initramfs.img must NOT be present.
uki_count="$(podman run --rm "${image}" sh -c 'ls /boot/EFI/Linux/*.efi 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
if [[ "${uki_count}" == "1" ]]; then
    ok "exactly one UKI in /boot/EFI/Linux"
else
    fail "exactly one UKI in /boot/EFI/Linux (found ${uki_count})"
fi
# The UKI must carry a .cmdline with a `composefs=` digest (sealing).
if podman run --rm "${image}" sh -c 'ukify inspect /boot/EFI/Linux/*.efi 2>/dev/null | grep -q "composefs="'; then
    ok "UKI cmdline carries a composefs= digest"
else
    fail "UKI cmdline carries a composefs= digest"
fi
# fs-verity must be enforced: the digest must NOT be prefixed with `?` (which would
# mean --allow-missing-verity was used).
if podman run --rm "${image}" sh -c 'ukify inspect /boot/EFI/Linux/*.efi 2>/dev/null | grep "composefs=" | grep -qv "composefs=?"'; then
    ok "fs-verity is enforced (no allow-missing-verity '?' prefix)"
else
    fail "fs-verity is enforced (no allow-missing-verity '?' prefix)"
fi
# The UKI must be unsigned: no PKCS7/.sig section.
if podman run --rm "${image}" sh -c 'ukify inspect /boot/EFI/Linux/*.efi 2>/dev/null | grep -q "^.sbat" && ! ukify inspect /boot/EFI/Linux/*.efi 2>/dev/null | grep -qE "^.sig|PKCS7"'; then
    ok "UKI is unsigned (no signature section)"
else
    fail "UKI is unsigned (no signature section)"
fi
# Raw kernel/initramfs must be gone (they live inside the UKI).
if podman run --rm "${image}" sh -c 'ls /usr/lib/modules/*/vmlinuz /usr/lib/modules/*/initramfs.img >/dev/null 2>&1'; then
    fail "raw vmlinuz/initramfs.img removed (embedded in the UKI)"
else
    ok "raw vmlinuz/initramfs.img removed (embedded in the UKI)"
fi
# exactly one kernel directory
kcount="$(podman run --rm "${image}" sh -c 'ls -d /usr/lib/modules/*/ | wc -l' 2>/dev/null || echo 0)"
if [[ "${kcount}" == "1" ]]; then
    ok "exactly one kernel in /usr/lib/modules"
else
    fail "exactly one kernel in /usr/lib/modules (found ${kcount})"
fi

# --- sealed boot chain ------------------------------------------------------
check "systemd-boot EFI binary is present" test -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi
check "bootctl is present" test -x /usr/sbin/bootctl
check "ukify is present" sh -c 'command -v ukify'
# bootupd must be absent: its presence would select the ostree/GRUB path instead of
# the composefs + systemd-boot path.
if podman run --rm "${image}" sh -c 'command -v bootupctl >/dev/null 2>&1 || test -d /usr/lib/bootupd'; then
    fail "bootupd is absent (composefs/systemd-boot path)"
else
    ok "bootupd is absent (composefs/systemd-boot path)"
fi
check_contains "kargs include the serial console" /usr/lib/bootc/kargs.d/00-console.toml "console=ttyS0"

# --- filesystem layout ------------------------------------------------------
check "has /sysroot directory" test -d /sysroot
if [ "$(podman run --rm "${image}" readlink /ostree 2>/dev/null)" = "sysroot/ostree" ]; then
    ok "/ostree -> sysroot/ostree"
else
    fail "/ostree -> sysroot/ostree"
fi
check_contains "composefs setup binds /etc" /usr/lib/composefs/setup-root-conf.toml '[etc]'
check_contains "composefs setup binds /var" /usr/lib/composefs/setup-root-conf.toml '[var]'

# --- bootc configuration ----------------------------------------------------
check_contains "prepare-root.conf enables composefs" /usr/lib/ostree/prepare-root.conf "enabled = yes"
check "has install config 00-cachyos.toml" test -f /usr/lib/bootc/install/00-cachyos.toml
check_contains "root filesystem type is ext4" /usr/lib/bootc/install/00-cachyos.toml 'type = "ext4"'
check "has dracut bootc module" test -f /usr/lib/dracut/modules.d/51bootc/module-setup.sh

# --- systemd ----------------------------------------------------------------
check "systemd is installed" test -x /usr/lib/systemd/systemd
check "systemd-networkd enabled" test -e /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
check "sshd enabled" test -e /etc/systemd/system/multi-user.target.wants/sshd.service
check "bootc-fetch-apply-updates.timer present" test -f /usr/lib/systemd/system/bootc-fetch-apply-updates.timer

# --- required packages (bootc runtime deps) ---------------------------------
for pkg in ostree skopeo podman dracut shadow openssh systemd-ukify; do
    check "package installed: ${pkg}" pacman -Q "${pkg}"
done

# --- bootc functionality (non-destructive in-container operations) ----------
if podman run --rm "${image}" bootc status --json >/dev/null 2>&1; then
    ok "bootc status --json runs"
else
    fail "bootc status --json runs"
fi

if podman run --rm "${image}" bootc container lint >/dev/null 2>&1; then
    ok "bootc container lint passes (no fatal errors)"
else
    fail "bootc container lint passes"
fi

echo
echo "==> ${checks} checks, ${failures} failure(s)"
if [[ "${failures}" -ne 0 ]]; then
    exit 1
fi
