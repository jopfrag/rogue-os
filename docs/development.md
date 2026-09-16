# Development Environment

This document records the **verified** development/test environment for this project.
Everything here was established empirically during Task 1. Do not treat it as assumptions.

## Summary

The agent runs inside a **Distrobox** container on a Fedora host. The container shares the
host's network and PID namespaces and has direct access to the host's libvirt/KVM
infrastructure. The host's libvirt is used to run disposable test VMs.

The image under test is a **sealed** CachyOS bootc image (composefs backend + systemd-boot +
unsigned UKI; fs-verity enforced, Secure Boot disabled). The VM therefore boots via
systemd-boot/UKI on UEFI firmware, and the root filesystem uses ext4 (fs-verity capable).

```
Fedora 44 host (hostname: WORKSTATION, user: jopfrag)
│
├── KVM (/dev/kvm)
├── QEMU 11.1.1
├── libvirt 12.7.0  (socket: qemu:///system)
└── libvirt default NAT network (virbr0, 192.168.122.0/24)
        ▲
        │ socket + shared netns
        │
Distrobox container "DEV"  (rootless podman, image cachyos/cachyos-v3:latest)
```

## Container / host identity

| Property | Value |
|---|---|
| Container runtime | rootless podman 5.8.4, Distrobox `DEV` |
| Container image | `docker.io/cachyos/cachyos-v3:latest` |
| Container user | uid 1000 (`jopfrag`), gid 1000, supplementary gid 65534 |
| Host OS | Fedora Linux 44 (Workstation) |
| Host kernel | `7.2.5-200.fc44.x86_64` (shared with container) |
| Host hostname | `WORKSTATION` |
| Host user | `jopfrag` uid 1000, member of host `libvirt` group (gid 985) |
| SELinux (host) | **Disabled** (`getenforce` → Disabled) |

The container's uid 1000 is the **same numeric uid as the host user** `jopfrag`
(`/run/host/home/jopfrag` is owned by `1000:1000`, and files this agent creates in host-shared
paths appear with the expected ownership). Container root (`sudo`) maps to host root for
ordinary writes, but **not** for host system paths (see idmap caveat below).

Passwordless `sudo` is available inside the container.

## KVM / QEMU

- `/dev/kvm` exists: `crw-rw-rw- root root` (world read/write). Available.
- `qemu-system-x86_64` 11.1.1 is installed in the container.
- A KVM domain started via libvirt runs with `-accel kvm` (verified from the QEMU command
  line), i.e. **hardware acceleration is real**, not TCG.

## libvirt

- `virsh -c qemu:///system` connects to the **host's** libvirt (reports host hostname
  `WORKSTATION`). There is no libvirtd inside the container.
- The host libvirt socket directory `/run/libvirt` is bind-mounted into the container
  (identical contents under `/run/host/var/run/libvirt`), and `libvirt-sock` is
  world read/write, so the connection works because host `jopfrag` is in the `libvirt` group.
- **Always connect explicitly with `-c qemu:///system`.** The default URI inside the
  container is `qemu:///session`.
- The host `default` NAT network is active: bridge `virbr0`, gateway `192.168.122.1/24`,
  DHCP range `192.168.122.2–254`, `forward mode='nat'`.
- No storage pools are defined; disks are referenced by absolute path.
- `virbr0` is visible inside the container (shared network namespace).
- No netns admin in the container: `ip addr add`, `ip link add`, etc. fail with
  `Operation not permitted`. The container **cannot** modify host networking or firewall.

## UEFI

- libvirt auto-selects OVMF when the domain uses `<os firmware='efi'>`:
  loader `/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2`,
  nvram template `/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2`.
- Firmware files live on the host (`/usr/share/edk2/ovmf/`); the container does not need them.
- NVRAM is written to host `/var/lib/libvirt/qemu/nvram/<domain>_VARS.qcow2`.
- Secure Boot is disabled in the initial test domains.

## CPU model (important)

The host CPU is an AMD Ryzen 5 5500U with **AVX2 but no AVX-512**. The CachyOS `-v3`
packages are built for x86-64-v3 and, more importantly, the default libvirt/QEMU CPU model
(`qemu64`) does **not** expose AVX2. Booting a CachyOS v3 userland under the default CPU
model causes `Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000004`
from an invalid opcode (systemd executes an instruction the emulated CPU lacks).

**Always set `<cpu mode='host-passthrough' check='none'/>` in test domains.** `host-model`
resolves to `EPYC-Rome` on this host and is also acceptable, but `host-passthrough` is the
simplest way to guarantee the guest sees the same instruction set as the host.

## Storage for VM disks (important)

libvirt on the host runs the QEMU process as the **host `qemu` user, uid 107, gid 107**
(confirmed from a libvirt error: `Cannot access storage file '...' (as uid:107, gid:107)`).

Consequences:

- VM disk images **cannot** live under `/home/jopfrag/...`: the home directory is mode
  `0700`, so uid 107 cannot traverse it.
- Use a location that is (a) on the host filesystem, (b) reachable/writable by uid 107.

**Chosen location:** the host's `/var/tmp`, which from inside the container is visible at
**`/run/host/var/tmp`** (474 GiB xfs root, 368 GiB free).

There is a path-translation rule:

| Purpose | Path to use |
|---|---|
| Read/write from the container | `/run/host/var/tmp/<name>` |
| Reference inside the libvirt domain XML | `/var/tmp/<name>` (host path) |

Disks created for a VM must be `chown 107:107` (and the parent directory too), otherwise
libvirt refuses to start the domain.

### `/run/host` idmap caveat

`/run/host` is an idmapped view of the host root. Files created by host uid 107 (QEMU)
appear in the container as `nobody:nobody` and are **not readable by any container uid**,
including container root — `cap_dac_override` does not help across the mapping. Practical
consequence: **do not rely on files written by the QEMU process (e.g. `type='file'` serial
logs) for diagnostics.** Read the serial console through a PTY instead (see below).

## Console capture

`<serial type='file'>` logs are unreadable from the container (idmap caveat above).
Use a PTY serial console and capture it through an allocated pseudo-terminal:

```xml
<serial type='pty'><target port='0'/></serial>
<console type='pty'><target type='serial' port='0'/></console>
```

```sh
timeout <N> script -qec "virsh -c qemu:///system console <domain>" /tmp/console.log
```

`virsh console` alone fails non-interactively (`Cannot run interactive console without a
controlling TTY`); wrapping it in `script` provides the needed PTY. The host has no `socat`
or `expect`; `script` is available.

Notes (verified):
- libvirt's `<serial><log file=.../></serial>` output is **also** unreadable from the
  Distrobox: it is created mode 0600 by the QEMU uid, and the idmapped `/run/host` maps the
  host uid to container `nobody`. libvirt additionally refuses to start a domain whose log
  path is a pre-created file (`Unable to open file ... Permission denied`). So we do not use
  `<log>`; `hack/lib/vm.sh:vm_capture_console` attaches via `virsh console` with a retry loop
  until the domain is running, which reliably captured the full install/boot console.
- The host's QEMU now runs as the login user (changed `user=`/`group=` in
  `/etc/libvirt/qemu.conf` during bring-up); this did not change console readability but is
  harmless.

## Verified install / boot findings (Tasks 11–21)

- **Self-install is required for the sealed/UKI image.** `bootc install to-filesystem`
  without `--source-imgref`, run from inside the target image (privileged, `--pid=host`),
  makes bootc inspect its own rootfs, find the UKI, and auto-select the composefs backend +
  systemd-boot. With `--source-imgref` it selects the ostree backend and fails.
- **Root partition needs the DPS type GUID** (`4f68bce3-e8cd-4db1-96e7-fbcaf984b709`) because
  the UKI cmdline has no `root=` and root is found via `systemd-gpt-auto-generator`.
- **`--skip-finalize` is used**: bootc's built-in `fsfreeze` on the container-bind-mounted
  target hangs; the installer does `fstrim` + `remount,ro` itself afterwards.
- **`bootc install finalize` is ostree-only** and is skipped for the composefs backend.
- **SSH is key-only.** `--root-ssh-authorized-keys` is ostree-only, so the installer
  replicates it: it writes a `d`+"f~" tmpfiles drop-in into the composefs deployment's
  per-deployment `/etc` (`state/deploy/<digest>/etc/tmpfiles.d/`, where `<digest>` is the
  `composefs=` value), not the plain `/target/etc` (which is never mounted at boot). `/etc`
  is carried across updates via the three-way merge, so the key survives `bootc switch` and
  rollback. The image has no password and `PasswordAuthentication no`.
- **Update/rollback work**: `bootc switch` to a v2 image stages a composefs/UKI deployment
  (`bootType: Uki`, `missingVerityAllowed: false`); reboot boots v2; `bootc rollback` returns
  to v1. The plain-HTTP test registry requires an `insecure = true` entry on the guest.

## VM networking and the local registry path

Inside the container, the VM-facing gateway is `192.168.122.1` (`virbr0`).

Verified behaviour of a guest VM on the `default` network:

- DHCP from libvirt's dnsmasq succeeds (guest receives e.g. `192.168.122.147`).
- ICMP to `192.168.122.1` succeeds.
- Outbound NAT to the internet succeeds (ICMP + TCP + DNS via the gateway).
- Inbound **TCP to services bound on a host address** (both `192.168.122.1` and the host's
  LAN address `192.168.128.162`) is **blocked while the host firewall (firewalld) is
  running** — the guest gets connection refusal/drop. ICMP and (forwarded) outbound traffic
  are allowed.
- With **firewalld stopped**, a guest at `192.168.122.200` successfully fetches
  `http://192.168.122.1:5000/` from a listener bound to the bridge address (request observed
  server-side: `REQUEST /... FROM 192.168.122.200`).

**Architectural consequence:** the container cannot manage the host firewall (no netns
admin). The local OCI registry is intended to be served from the container on
`192.168.122.1:5000`, reachable from the VM. This requires the host firewall to permit
inbound TCP on the libvirt bridge. The automated workflow must **detect and report** this
precondition rather than assume it. Options to keep in mind for later tasks:

1. Require/verify that the host firewall allows traffic from `virbr0`
   (e.g. firewalld `libvirt` zone / `trusted` zone for `virbr0`).
2. Or expose the registry on a network path that is not subject to host inbound filtering.

`qemu:///session` was also explored: it has no `default` network, does not grant the same
bridge, and the probe guest could not reach the host that way. `qemu:///system` is used.

## Host firewall note

`firewalld` normally runs on the host (Fedora Workstation default). During Task 1 the
operator stopped it to validate the registry path. The project must not silently depend on
this; the harness should check the registry path and fail with a clear diagnostic if the
guest cannot reach it.

## Disposable VM lifecycle (verified)

The following cycle was exercised end-to-end during Task 1:

1. Create a disk under `/run/host/var/tmp/cachyos-bootc-test-<id>/`, `chown 107:107`.
2. Define a libvirt domain (`qemu:///system`) referencing the disk by its host path.
3. `virsh start`, confirm `-accel kvm`, boot a minimal guest, capture the console.
4. `virsh destroy` + `virsh undefine --nvram`, remove the disk directory.

All probe domains, disks, and listeners were removed after the task; only the host's own
libvirt `default` network (dnsmasq on :53) was left in place.

## Tool availability in the container

Present: `virsh`, `virt-install` 5.1.0, `qemu-system-x86_64`, `qemu-img`, `podman`,
`bootc` 1.16.12, `make`, `git`, `curl`, `ssh`, `ssh-keygen`, `xorriso`, `script`,
`python3`, `nft`/`iptables` (but no netns admin), `setpriv`, passwordless `sudo`.

Absent: `docker`, `buildah`, `skopeo`, `genisoimage`, `mkisofs`, `busybox`, `dracut`,
`socat`, `expect`, `firewall-cmd` (the host binary exists but its Python module is not
available in the container).
