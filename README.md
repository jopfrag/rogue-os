# rogue-os

[![Build bootc image](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml/badge.svg)](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)

A **sealed CachyOS bootc image**: a composefs root protected by fs-verity, booted from a
Unified Kernel Image via **systemd-boot**. The default root filesystem is **f2fs**. The UKI
and `systemd-boot` are always signed for **Secure Boot**, and the UKI always carries a
**TPM2 signed PCR policy** so a LUKS root can be auto-unlocked once it is bound to the TPM
and the Secure Boot policy (PCR 7). The signing keys are supplied as build secrets.

## Get the image

```sh
podman pull ghcr.io/jopfrag/rogue:latest
```

Or build it yourself. Signing is mandatory, so the four key secrets below are required:

```sh
podman build \
  --build-arg SIGNING_REV="$(date +%s)" \
  --secret id=db_key,src=./db.key \
  --secret id=db_cert,src=./db.crt \
  --secret id=pcr_key,src=./pcr.key \
  --secret id=pcr_pub,src=./pcr.pub \
  -t ghcr.io/jopfrag/rogue:latest -f Containerfile .
```

## Install

UEFI only. The image is always signed for Secure Boot and always carries a TPM2 PCR policy,
so Secure Boot must be enabled after enrolling the certificate. Boot a live Arch Linux
environment in UEFI mode, prepare the target disk (GPT with an EFI system partition and a
LUKS2-encrypted f2fs root), then install the image:

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

- x86-64-v3 (AVX2) machine, UEFI boot, Secure Boot capable, with a TPM2 device. Secure
  Boot must be enabled once the image's certificate is enrolled.
- A target disk (it will be wiped).

## Documentation

| File | |
|---|---|
| [`INSTALL.md`](INSTALL.md) | Install from a stock Arch Linux ISO |
| [`LICENSE.md`](LICENSE.md) | Apache-2.0 |

## References

The build draws on [`bootcrew/mono`](https://github.com/bootcrew/mono) (its
`arch/Containerfile` and `shared/`), the maintained successor to
`bootcrew/arch-bootc`, and on upstream
[`bootc`](https://github.com/bootc-dev/bootc).

## License

Licensed under the [Apache License 2.0](LICENSE.md).
