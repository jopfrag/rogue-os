# CachyOS bootc

Build a **sealed CachyOS bootc OCI image** (composefs backend, systemd-boot, unsigned UKI)
from scratch, and test it end-to-end in a disposable libvirt/QEMU/KVM virtual machine: build
the image, push it to a local OCI registry, boot a CachyOS installer environment, install with
`bootc install to-filesystem`, reboot, connect over SSH, and run automated integration tests
(including update and rollback), then destroy everything.

The image is **sealed**: the composefs digest of the root filesystem is embedded in the
Unified Kernel Image and enforced via fs-verity. **Secure Boot is not used** and the UKI is
**unsigned**.

This repository contains the implementation of the image build itself; it does **not** wrap a
prebuilt CachyOS bootc image, and it does **not** use `bootc-image-builder`.

## Status

The full workflow works end-to-end: the sealed image builds, installs into a disposable VM
via the custom installer ISO (`bootc install to-filesystem`, composefs backend + systemd-boot),
boots from disk, is reachable over SSH, and passes the automated smoke, update and rollback
tests. See `TASKS.md` for current progress and `docs/` for design and environment
documentation.

> Bring-up note: SSH currently uses a fixed password baked into the image
> (`root:bootc-test`, `PermitRootLogin yes`) so the harness can log in while durable key
> injection for the composefs backend is reworked (see TASKS.md Task 28). This is a test
> credential for the disposable VM only.

## Prerequisites

- A Linux host with KVM, QEMU and libvirt, reachable from the development environment.
- `podman`, `virsh`, `virt-install`, `qemu-img`, `xorriso`, `git`, `make`, `curl`, `ssh`.
- The host firewall must permit traffic from the libvirt bridge to the registry
  (see `docs/development.md`).

## Usage

```sh
make build       # build the CachyOS bootc OCI image
make lint        # bootc container lint + shellcheck/format checks
make image-test  # fast image-level checks (no VM)
make installer   # build the CachyOS installer live ISO
make registry-push   # build, start the local registry, and push the image

# Full disposable-VM workflows (install -> boot -> verify; clean up afterwards):
make test        # install -> boot -> smoke test
make vm-install  # install into a VM and keep it for inspection
make vm-update   # install v1 -> boot -> update to v2 -> verify
make vm-rollback # install v1 -> update to v2 -> roll back to v1 -> verify

make image-v1    # build a v1 image (for update/rollback tests)
make image-v2    # build a v2 image (for update/rollback tests)
make clean       # remove local build and test artifacts
```

Commands are safe to run repeatedly. Use `RUN_ARGS=--keep` to keep the test VM, or
`RUN_ARGS="--image REF"` to override the image under test.

## Layout

```
Containerfile        CachyOS bootc image build (sealed: composefs + UKI + systemd-boot)
Containerfile.uki    read-only reference for the UKI/composefs build (do not modify)
Makefile             agent/developer entry points
docs/                design and environment documentation
installer/           installer environment build + installation logic
tests/image/         VM-less image validation
tests/vm/            disposable-VM integration tests (install, boot, smoke, update, rollback)
hack/                helper scripts (registry, VM lifecycle, SSH, diagnostics)
contrib/             third-party reference material and attribution
```

## License and attribution

This project builds on the ideas and, where noted, adapted code from third-party projects.
See `contrib/` for attribution and license information.
