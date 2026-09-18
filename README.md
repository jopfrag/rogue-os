# rogue-os

[![Build bootc image](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml/badge.svg)](https://github.com/jopfrag/rogue-os/actions/workflows/build-image.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)

> **A sealed CachyOS bootc image for machines that should boot clean, stay encrypted, and update themselves.**

`rogue-os` combines **CachyOS**, **bootc**, **composefs**, **fs-verity**, **Secure Boot**, and **TPM2-backed disk encryption** into a reproducible, unattended OS image.

The goal is simple: **make the thing you boot the thing you intended to build.**

---

## ⚡ Highlights

| | |
|---|---|
| 🔒 **Sealed root** | composefs root protected by `fs-verity` |
| 🥾 **Modern boot** | Unified Kernel Image (UKI) + `systemd-boot` |
| 🛡️ **Secure Boot** | Signed UKI and `systemd-boot` |
| 🔐 **Encrypted root** | LUKS2 with TPM2 signed-PCR auto-unlock |
| 💾 **f2fs** | Default root filesystem |
| 🔄 **Self-maintaining** | Unattended bootc updates + maintenance-window reboots |

---

## 📦 Get the image

Pull the published image with Podman:

```
podman pull ghcr.io/jopfrag/rogue-server:v1
```

---

## 🚀 Installation

Installation from a stock Arch Linux ISO is documented in:

**→ `INSTALL.md`**

The installation guide covers the disk layout, encryption, TPM enrollment, Secure Boot, and first boot.

---

## 🔗 References

- `bootcrew/mono`

---

## 📜 License

Licensed under the Apache License 2.0.
