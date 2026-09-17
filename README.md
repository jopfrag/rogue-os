# CachyOS bootc

Build a **sealed CachyOS bootc OCI image** (composefs backend, systemd-boot, unsigned UKI)
and test it in a disposable VM with [`bcvk`](https://github.com/bootc-dev/bcvk) — rootless,
file-based, no installer ISO and no host root.

The image is **sealed**: the composefs digest of the root filesystem is embedded in the
Unified Kernel Image and enforced via fs-verity. **Secure Boot is not used** and the UKI is
**unsigned**.

This repository contains the implementation of the image build itself; it does **not** wrap
a prebuilt CachyOS bootc image, and it does **not** use `bootc-image-builder`.

- [`TEST.md`](TEST.md) — testing the image with bcvk (`ephemeral` and `libvirt run`).
- [`INSTALL.md`](INSTALL.md) — by-hand install from a stock Arch Linux ISO.

## Prerequisites

- A Linux host with KVM, QEMU and libvirt reachable from the development environment.
- `podman`, `bcvk`, `qemu-img`, `virtiofsd`, `git`, `curl`, `ssh`.

## Usage

```sh
# Build the image
podman build -t localhost:5000/cachyos-bootc:test -f Containerfile .

# Versioned images for update/rollback testing
podman build --build-arg IMAGE_VERSION=1 -t localhost:5000/cachyos-bootc:v1 -f Containerfile .
podman build --build-arg IMAGE_VERSION=2 -t localhost:5000/cachyos-bootc:v2 -f Containerfile .

# Test (details in TEST.md)
bcvk ephemeral run-ssh localhost:5000/cachyos-bootc:test -- bootc status

bcvk libvirt -c qemu:///session run \
  --composefs-backend --firmware uefi-insecure --disable-tpm \
  --name cachy-test --disk-size 24G --detach --ssh-wait --replace \
  localhost:5000/cachyos-bootc:test

# Local OCI registry (for bootc update/switch testing)
podman run -d --name cachyos-bootc-registry --network host \
  -v "$PWD/registry-data:/var/lib/registry:z" docker.io/library/registry:2
podman tag localhost:5000/cachyos-bootc:test 192.168.122.1:5000/cachyos-bootc:test
podman push --tls-verify=false 192.168.122.1:5000/cachyos-bootc:test
```

## Layout

```
.github/workflows/   CI image build workflow
Containerfile        CachyOS bootc image build
Containerfile.md     Explanation of the Containerfile
bootc-f2fs.patch     Local bootc patch (f2fs support)
TEST.md              Testing with bcvk
INSTALL.md           Manual install from a stock Arch ISO
```

## License and attribution

This project builds on the ideas and, where noted, adapted code from third-party projects,
in particular bootcrew/mono and its predecessor bootcrew/arch-bootc (Apache-2.0).
