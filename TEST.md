# Testing the CachyOS bootc image with bcvk

Rootless (no host root, no installer ISO). Run from the repo root. `bcvk` boots the image
in an ephemeral VM, or installs it to a persistent libvirt VM.

The image must contain `bubblewrap` (the current `Containerfile` does) or bcvk refuses to
start with `bwrap ... is currently required`.

## 0. Build the image

```sh
podman build -t localhost:5000/cachyos-bootc:test -f Containerfile .
podman image exists localhost:5000/cachyos-bootc:test && echo ok
```

## 1. bcvk ephemeral — fast, no disk install

Boots the image directly over virtiofs. Tests userspace/kernel/services only; it does
**not** create a bootc deployment (no composefs/fs-verity/UKI boot).

```sh
# one-shot command over SSH
bcvk ephemeral run-ssh localhost:5000/cachyos-bootc:test -- sh -c \
  'uname -r; systemctl is-system-running; systemctl is-active sshd; bootc status'

# interactive shell (exit discards the VM)
bcvk ephemeral run-ssh localhost:5000/cachyos-bootc:test

# background VM you can reconnect to
bcvk ephemeral run -d --rm --ssh-keygen --name cachy-test localhost:5000/cachyos-bootc:test
bcvk ephemeral ssh cachy-test
podman stop cachy-test
```

## 2. bcvk libvirt run — real sealed install + boot

Installs to disk (composefs + f2fs + UKI + systemd-boot) and boots it. Two flags matter:

- `--composefs-backend` (otherwise the ostree backend is used),
- `--firmware uefi-insecure` (the UKI is unsigned; Secure Boot is off).

Use `-c qemu:///session` here; the system pool `/var/lib/libvirt/images` is not writable
from the container. `--disable-tpm` is needed unless `swtpm` is installed (otherwise libvirt
rejects the domain with `TPM version '2.0' is not supported`).

```sh
bcvk libvirt -c qemu:///session run \
  --composefs-backend --firmware uefi-insecure --disable-tpm \
  --name cachy-test --disk-size 24G \
  --detach --ssh-wait --replace \
  localhost:5000/cachyos-bootc:test

# shell / one-shot commands
bcvk libvirt -c qemu:///session ssh cachy-test
bcvk libvirt -c qemu:///session ssh cachy-test -- sh -c \
  'cat /proc/cmdline; findmnt -no FSTYPE,OPTIONS /sysroot; bootc status'

# lifecycle
bcvk libvirt -c qemu:///session list
bcvk libvirt -c qemu:///session stop cachy-test
bcvk libvirt -c qemu:///session start cachy-test
bcvk libvirt -c qemu:///session rm -f cachy-test
```

Expected sealed markers:

- `/proc/cmdline` contains `composefs=<digest>` with **no** `?` prefix (fs-verity enforced)
- `/sysroot` is `f2fs ro`; `/etc` and `/var` are writable
- `bootc status` shows a booted composefs deployment with `bootType: Uki` and
  `bootloader: systemd`

## Known issue

`bcvk libvirt run` / `bcvk to-disk --composefs-backend` intermittently (~1 in 7) fails at
`Finalizing filesystem root`:

```
mount: /run/bootc/mounts/rootfs: mount point is busy
```

Just re-run the command — the failed install is discarded and restarts from scratch.

## TPM

Only the libvirt path has a TPM; `bcvk ephemeral` has no TPM device.

`bcvk libvirt run` adds an **emulated** TPM 2.0 by default, but libvirt needs `swtpm`
visible to the daemon running the domain. In this Distrobox the libvirt daemon lacks it
(the host has `/usr/bin/swtpm`; the container does not), so libvirt advertises only
`passthrough` and rejects the emulated config — hence `--disable-tpm`.

To test a TPM:

```sh
# 1. Install swtpm where the session libvirtd/virtqemud runs (the Distrobox)
sudo pacman -S swtpm

# 2. Restart the session daemon so libvirt re-probes it
pkill -f virtqemud; pkill -f '/usr/bin/libvirtd'

# 3. Confirm the emulator backend is now offered (should list <value>emulator</value>)
virsh -c qemu:///session domcapabilities | sed -n '/<tpm/,/<\/tpm>/p'

# 4. Re-run without --disable-tpm
bcvk libvirt -c qemu:///session run --composefs-backend --firmware uefi-insecure \
  --name cachy-test --disk-size 24G --detach --ssh-wait --replace \
  localhost:5000/cachyos-bootc:test
```

In the guest:

```sh
systemd-creds has-tpm2              # yes
cat /sys/class/tpm/tpm0/tpm_version_major
systemd-cryptenroll --tpm2-device=list
```

The image ships systemd's TPM userspace (`systemd-creds`, `systemd-cryptenroll`) but not
`tpm2-tss`/`tpm2-tools`; add `tpm2-tss` if you need `tpm2_getcap` and friends.

The host also exposes a real TPM (`/dev/tpm0`, `/dev/tpmrm0`), which libvirt could pass
through, but the user is not in the `tss` group and it would share the physical machine's
TPM — not recommended for tests.
