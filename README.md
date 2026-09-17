# CachyOS bootc

Build a **sealed CachyOS bootc OCI image** (composefs backend, systemd-boot, unsigned UKI)
from scratch, and test it end-to-end in a disposable libvirt/QEMU/KVM virtual machine.

The image is **sealed**: the composefs digest of the root filesystem is embedded in the
Unified Kernel Image and enforced via fs-verity. **Secure Boot is not used** and the UKI is
**unsigned**.

This repository contains the implementation of the image build itself; it does **not** wrap a
prebuilt CachyOS bootc image, and it does **not** use `bootc-image-builder`.

To install the image by hand from a stock Arch Linux ISO (no custom installer ISO), see
[`INSTALL.md`](INSTALL.md).

## Two targets

This repository exposes two independent targets that share only `Containerfile`:

1. **CI image build** — a GitHub Actions workflow (`.github/workflows/build-image.yaml`)
   that builds the OCI image. PRs build only; main pushes build and push to GHCR.
2. **VM test** — a `make vm-test` workflow that installs the image into a disposable
   libvirt/QEMU/KVM VM and runs automated tests (install, boot, smoke, update, rollback).
   Consumes an image reference and installer ISO; builds neither.

## Prerequisites

- A Linux host with KVM, QEMU and libvirt, reachable from the development environment.
- `podman`, `virsh`, `qemu-img`, `xorriso`, `git`, `make`, `curl`, `ssh`.
- The host firewall must permit traffic from the libvirt bridge to the registry.

## Usage

```sh
# Image build (Target 1)
make build          # build the CachyOS bootc OCI image
make lint           # bootc container lint + shellcheck checks
make image-test     # fast image-level checks (no VM)

# Installer / registry (supporting tools)
make installer      # build the CachyOS installer live ISO
make registry-push  # start registry and push the image

# VM test (Target 2) — consumes image + ISO, builds neither
make vm-test        # install -> boot -> smoke test
make vm-install     # install into a VM and keep it for inspection
make vm-update      # install v1 -> boot -> update to v2 -> verify
make vm-rollback    # install v1 -> update to v2 -> roll back to v1 -> verify

# Versioned images for update/rollback tests
make image-v1       # build a v1 image
make image-v2       # build a v2 image

make clean          # remove local build and test artifacts
```

Commands are safe to run repeatedly. Use `RUN_ARGS=--keep` to keep the test VM, or
`RUN_ARGS="--image REF"` to override the image under test.

## Layout

```
.github/workflows/   CI image build workflow (Target 1)
vm-test/             Disposable VM test workflow (Target 2)
  config.env           Registry/image/ISO defaults
  run.sh               End-to-end: install -> boot -> smoke
  install.sh           Boot installer, install to disk
  boot.sh              Boot installed system, wait for SSH
  smoke.sh             Verify sealed deployment, bootc, systemd
  upgrade.sh           v1 -> v2 update test
  rollback.sh          Rollback after update test
  lib/vm.sh            Libvirt/QEMU/KVM helpers
  lib/ssh.sh           SSH helpers for test VMs
Containerfile        CachyOS bootc image build (shared by both targets)
Containerfile.md     Explanation of the Containerfile
Containerfile.uki    Read-only reference for the UKI/composefs build (do not modify)
Makefile             Thin dispatchers for both targets
installer/           Installer environment build + installation logic
tests/image/         VM-less image validation
hack/                Helper scripts (registry, build, lint, shell)
contrib/             Third-party reference material and attribution
```

## License and attribution

This project builds on the ideas and, where noted, adapted code from third-party projects.
See `contrib/` for attribution and license information.
