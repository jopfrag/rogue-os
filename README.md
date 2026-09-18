# rogue-os

[![Build bootc image](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml/badge.svg)](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)

A **sealed CachyOS bootc image**: a composefs root protected by fs-verity, booted from a
Unified Kernel Image via **systemd-boot**. The default root filesystem is **f2fs**. The UKI
and `systemd-boot` are always signed for **Secure Boot**, and the UKI always carries a
**TPM2 signed PCR policy** so a LUKS root can be auto-unlocked once it is bound to the TPM
and the Secure Boot policy (PCR 7). The signing keys are supplied as build secrets.

## Features

- ✅ Sealed: composefs root with fs-verity enforced
- ✅ Unified Kernel Image (UKI) booted by systemd-boot
- ✅ Secure Boot: signed UKI and `systemd-boot`
- ✅ Encrypted LUKS2 root with TPM2 signed-PCR auto-unlock
- ✅ f2fs default root filesystem
- ✅ Unattended bootc updates and maintenance-window reboots

## Get the image

```sh
podman pull ghcr.io/jopfrag/rogue:latest
```

## Documentation

| File | |
|---|---|
| [`INSTALL.md`](INSTALL.md) | Install from a stock Arch Linux ISO |
| [`LICENSE.md`](LICENSE.md) | Apache-2.0 |

## References

- [`bootcrew/mono`](https://github.com/bootcrew/mono)
- [`bootc`](https://github.com/bootc-dev/bootc)

## License

Licensed under the [Apache License 2.0](LICENSE.md).
