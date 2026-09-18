# rogue-os

[![Build bootc image](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml/badge.svg)](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A **sealed CachyOS bootc image**: a composefs root protected by fs-verity, booted from a
Unified Kernel Image via **systemd-boot**. The default root filesystem is **f2fs**. The UKI
and `systemd-boot` can be signed for **Secure Boot**, and a LUKS root can be auto-unlocked
with a **TPM2 signed PCR policy** that is also bound to the Secure Boot policy (PCR 7); both
are opt-in at build time.

## Get the image

```sh
podman pull ghcr.io/jopfrag/rogue:latest
```

Or build it yourself:

```sh
podman build -t ghcr.io/jopfrag/rogue:latest -f Containerfile .
```

## Install

UEFI only. **Secure Boot is optional**: an unsigned build requires it to be disabled; a
build signed with the `secureboot_key`/`secureboot_cert` secrets works with Secure Boot
once the certificate is enrolled. Boot a live Arch Linux environment in UEFI mode, prepare
the target disk (GPT with an EFI system partition and an f2fs root), then install the image:

```sh
podman run --rm --privileged --pid=host --ipc=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /mnt/target:/target \
    ghcr.io/jopfrag/rogue:latest \
    bootc install to-filesystem \
        --target-imgref ghcr.io/jopfrag/rogue:latest \
        --skip-finalize \
        /target
```

Partitioning, formatting, root SSH key injection and finalization are covered step by step
in [`INSTALL.md`](INSTALL.md).

## Verify

After booting the installed system:

```sh
grep -o 'composefs=[0-9a-f]*' /proc/cmdline   # no '?' -> fs-verity is enforced
bootc status                                   # bootType: Uki, bootloader: systemd
```

## Requirements

- x86-64-v3 (AVX2) machine, UEFI boot. Secure Boot is optional (it must be disabled for an
  unsigned build).
- A target disk (it will be wiped).

## Documentation

| File | |
|---|---|
| [`INSTALL.md`](INSTALL.md) | Install from a stock Arch Linux ISO |
| [`Containerfile.md`](Containerfile.md) | How the image is built |
| [`LICENSE`](LICENSE) | Apache-2.0 |

## License

Licensed under the [Apache License 2.0](LICENSE). The build draws on
[`bootcrew/mono`](https://github.com/bootcrew/mono) and its predecessor
`bootcrew/arch-bootc`, and on upstream [`bootc`](https://github.com/bootc-dev/bootc).
