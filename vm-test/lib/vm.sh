#!/usr/bin/env bash
# Shared helpers for disposable libvirt/QEMU/KVM test VMs.
#
# Sourced by test/helper scripts. Every VM created here is uniquely named and tracked so
# cleanup only ever touches VMs owned by the current run.
#
# Environment facts this relies on:
#   - libvirt is reached with `qemu:///system`
#   - QEMU runs as host uid 107, so disks live under host /var/tmp (<repo>/run mapping)
#   - test domains MUST use <cpu mode='host-passthrough'> (CachyOS v3 needs AVX2)
#   - serial console is captured via a PTY + `script`

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

# Host-visible directory for VM disks. From inside the container the host /var/tmp is at
# /run/host/var/tmp; libvirt (on the host) needs the plain /var/tmp path in domain XML.
VM_HOST_DIR_BASE="${VM_HOST_DIR_BASE:-/run/host/var/tmp}"
VM_HOST_DIR_BASE_XML="${VM_HOST_DIR_BASE_XML:-/var/tmp}"

virsh_cmd() { virsh -c "${LIBVIRT_URI}" "$@"; }

# vm_domain_exists <name>
vm_domain_exists() {
    virsh_cmd dominfo "$1" >/dev/null 2>&1
}

# vm_create <name> <disk-size> <installer-iso> [vcpus] [ram-mib] [config-dir]
# Defines (but does not start) a UEFI test domain with a virtio disk, virtio network and
# a PTY serial console. If config-dir is given, a FAT volume labelled BOOTCINSTAL
# containing that directory's files is attached as a second disk. Prints the host disk
# directory on stdout.
vm_create() {
    local name="$1" disk_size="$2" iso="$3" vcpus="${4:-2}" ram="${5:-4096}" config_dir="${6:-}"
    local dir="${VM_HOST_DIR_BASE}/${name}"
    local xmldir="${VM_HOST_DIR_BASE_XML}/${name}"

    sudo mkdir -p "${dir}"
    sudo chown 107:107 "${dir}"

    sudo qemu-img create -f qcow2 "${dir}/disk.qcow2" "${disk_size}" >/dev/null
    sudo chown 107:107 "${dir}/disk.qcow2"

    if [[ -n "${iso}" ]]; then
        [[ -f "${iso}" ]] || { echo "installer ISO not found: ${iso}" >&2; return 1; }
        sudo cp "${iso}" "${dir}/installer.iso"
        sudo chown 107:107 "${dir}/installer.iso"
    fi

    # Optional FAT config volume labelled BOOTCINSTAL (read by the installer).
    # Build it in a writable temp location, then move it into the (uid 107) disk dir.
    if [[ -n "${config_dir}" ]]; then
        local cfg_tmp
        cfg_tmp="$(mktemp -d)"
        local cfg_img="${cfg_tmp}/config.img"
        dd if=/dev/zero of="${cfg_img}" bs=1M count=16 status=none
        mkfs.vfat -n BOOTCINSTAL "${cfg_img}" >/dev/null
        local f
        for f in "${config_dir}"/*; do
            [[ -e "${f}" ]] || continue
            mcopy -i "${cfg_img}" "${f}" "::$(basename "${f}")"
        done
        sudo mv "${cfg_img}" "${dir}/config.img"
        sudo chown 107:107 "${dir}/config.img"
        rm -rf "${cfg_tmp}"
    fi

    # Writable live overlay as a real disk (avoids the RAM-backed tmpfs overlay that is
    # too small to pull the OS image). An ext4 volume labelled OVERLAY, pre-seeded with
    # the overlayfs/ and ovlwork/ directories dmsquash-live expects.
    if [[ "${vm_overlay_size:-}" != "none" ]]; then
        local seed
        seed="$(mktemp -d)"
        # dmsquash-live's default persistent overlay path is
        # /LiveOS/overlay-<live-label>-<live-uuid>, with a sibling ovlwork directory.
        # The ISO label is CACHYOS_BOOTC and its UUID is fixed by the build.
        local live_label="${LIVE_LABEL:-CACHYOS_BOOTC}"
        local live_uuid="${LIVE_UUID:-2026010100000000}"
        mkdir -p "${seed}/tree/LiveOS/overlay-${live_label}-${live_uuid}" \
                 "${seed}/tree/LiveOS/ovlwork"
        local ovl_img="${seed}/overlay.img"
        dd if=/dev/zero of="${ovl_img}" bs=1M count=1 status=none
        mke2fs -q -t ext4 -L OVERLAY -d "${seed}/tree" -F "${ovl_img}" "${vm_overlay_size:-16G}"
        sudo mv "${ovl_img}" "${dir}/overlay.img"
        sudo chown 107:107 "${dir}/overlay.img"
        rm -rf "${seed}"
    fi

    local xml
    xml="$(mktemp)"
    cat >"${xml}" <<EOF
<domain type='kvm'>
  <name>${name}</name>
  <memory unit='MiB'>${ram}</memory>
  <vcpu>${vcpus}</vcpu>
  <cpu mode='host-passthrough' check='none'/>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <firmware>
      <feature enabled='no' name='enrolled-keys'/>
      <feature enabled='no' name='secure-boot'/>
    </firmware>
    <boot dev='cdrom'/>
    <boot dev='hd'/>
  </os>
  <features><acpi/></features>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${xmldir}/disk.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
EOF
    if [[ -n "${iso}" ]]; then
        cat >>"${xml}" <<EOF
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${xmldir}/installer.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
EOF
    fi
    cat >>"${xml}" <<EOF
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
EOF

    if [[ -n "${config_dir}" ]]; then
        # Insert the config disk before </devices>.
        sed -i "s#</devices>#    <disk type='file' device='disk'>\n      <driver name='qemu' type='raw'/>\n      <source file='${xmldir}/config.img'/>\n      <target dev='vdb' bus='virtio'/>\n    </disk>\n  </devices>#" "${xml}"
    fi

    if [[ "${vm_overlay_size:-}" != "none" ]]; then
        # Insert the live-overlay disk before </devices> (after any config disk).
        sed -i "s#</devices>#    <disk type='file' device='disk'>\n      <driver name='qemu' type='raw'/>\n      <source file='${xmldir}/overlay.img'/>\n      <target dev='vdc' bus='virtio'/>\n    </disk>\n  </devices>#" "${xml}"
    fi

    # Remove any stale definition with the same name (owned by a previous run).
    virsh_cmd destroy "${name}" >/dev/null 2>&1 || true
    virsh_cmd undefine "${name}" --nvram >/dev/null 2>&1 || true
    virsh_cmd define "${xml}" >/dev/null
    rm -f "${xml}"

    echo "${dir}"
}

# vm_start <name>
vm_start() { virsh_cmd start "$1" >/dev/null; }

# vm_domstate <name>
vm_domstate() { virsh_cmd domstate "$1" 2>/dev/null || echo "undefined"; }

# vm_destroy <name>: force off, undefine (with nvram), and remove its disk directory.
vm_destroy() {
    local name="$1"
    if vm_domain_exists "${name}"; then
        virsh_cmd destroy "${name}" >/dev/null 2>&1 || true
        virsh_cmd undefine "${name}" --nvram >/dev/null 2>&1 \
            || virsh_cmd undefine "${name}" >/dev/null 2>&1 || true
    fi
    sudo rm -rf "${VM_HOST_DIR_BASE}/${name}"
}

# vm_capture_console <name> <seconds> <outfile>
# Attach to the domain's serial console and capture to <outfile>. Retries the attach until
# the domain is running, so callers don't race `virsh start`. Runs until <seconds> elapse
# or the domain stops.
vm_capture_console() {
    local name="$1" seconds="$2" out="$3"
    local deadline=$(( $(date +%s) + seconds ))
    # Wait (briefly) for the domain to start.
    while [[ $(date +%s) -lt ${deadline} ]]; do
        [[ "$(vm_domstate "${name}")" == "running" ]] && break
        sleep 1
    done
    : >"${out}"
    while [[ $(date +%s) -lt ${deadline} ]]; do
        timeout $(( deadline - $(date +%s) )) \
            script -qec "virsh -c ${LIBVIRT_URI} console ${name}" "${out}" \
            >>/dev/null 2>&1 || true
        [[ "$(vm_domstate "${name}")" == "running" ]] || break
        sleep 1
    done
}

# vm_detach_installer <name>
# Detach the installer ISO and any auxiliary install-time disks (config, live overlay) so
# the VM boots the installed system from its disk. The ESP is DPS-discoverable and the
# sealed UKI has no root= karg, so disk-first boot must succeed on its own.
vm_detach_installer() {
    local name="$1"
    # Best-effort detach: only detach devices that are actually attached.
    local dev
    for dev in sda vdb vdc; do
        if virsh_cmd dumpxml "${name}" | grep -q "target dev='${dev}'"; then
            virsh_cmd detach-disk "${name}" "${dev}" --persistent >/dev/null 2>&1 || true
        fi
    done
}

# vm_boot_from_disk <name>
# Detach the installer media and start the VM from its installed disk.
vm_boot_from_disk() {
    local name="$1"
    vm_detach_installer "${name}"
    vm_start "${name}"
}
