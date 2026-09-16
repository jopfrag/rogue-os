Build a sealed CachyOS bootc Image (composefs + UKI + systemd-boot) and Automated VM Test Environment

Read AGENT.md before doing anything else.

AGENT.md defines how you must work throughout this project.

Your job is to build a from-scratch CachyOS bootc image together with a completely automated local build, installation, boot, SSH, and integration-test workflow.

The image is a **sealed** bootc image: it uses the **composefs backend** and boots via **systemd-boot** with a **Unified Kernel Image (UKI)**, with fs-verity enforcement enabled. **Secure Boot is not used**, and the UKI is **unsigned**.

The end result must be something an autonomous coding agent can repeatedly build, boot, test, diagnose, and destroy without manual intervention.

1. Development Environment

You are running inside a Distrobox container.

The outer Linux host provides:

KVM;

QEMU;

libvirt;

virtualization networking.

The Distrobox has access to the host's KVM/libvirt infrastructure.

Before building the actual project, verify:

/dev/kvm access;

virsh connectivity;

virt-install availability;

QEMU/KVM operation;

libvirt networking;

the ability to create and destroy a disposable test VM.

Do not assume how the Distrobox is connected to libvirt.

Discover the actual environment and document it in docs/design.md or docs/development.md.

Do not install a separate virtualization stack inside the Distrobox unless there is a concrete reason.

The intended relationship is:

Outer Linux host
│
├── KVM
├── QEMU
├── libvirt
└── libvirt networking
        ▲
        │
        │ accessible from
        │
Distrobox
│
├── agent
├── source tree
├── Podman/build tools
├── virsh/virt-install
└── test harness
        │
        ▼
   disposable VM

2. Objective

Build this workflow:

CachyOS source/base
        │
        ▼
CachyOS bootc OCI image
(composefs + UKI + systemd-boot)
        │
        ▼
local OCI registry
        │
        ▼
libvirt / QEMU / KVM
        │
        ▼
temporary VM
        │
        ▼
CachyOS installer environment
        │
        ├── partition disk
        ├── format filesystems
        ├── mount target
        │
        ▼
bootc install to-filesystem
(composefs backend, systemd-boot)
        │
        ▼
bootc install finalize
        │
        ▼
reboot
        │
        ▼
actual sealed CachyOS bootc system
        │
        ▼
SSH
        │
        ▼
automated integration tests


The VM used for installation and the VM used for testing should be the same VM.

The installer environment is only temporary.

3. Build CachyOS bootc From Scratch

The resulting image must be built by this repository.

Do not use an existing CachyOS bootc image as the base.

Do not solve the problem by finding a prebuilt image and writing a thin wrapper around it.

The repository should contain the implementation necessary to construct the bootc image.

A normal CachyOS/Arch-family userspace/base may be used as the starting point if appropriate.

The project should make the image construction understandable.

The image must be a sealed composefs/UKI image. Concretely, the build must:

- include **systemd-boot** and **must NOT include bootupd** (bootc selects systemd-boot by
default when bootupd is absent; bootupd's presence would select the GRUB/bootupd path
instead);

- contain exactly one kernel, with `vmlinuz` and `initramfs.img` under
`/usr/lib/modules/<kver>/`, and must **not** ship a pre-built UKI (the build generates it);

- build a UKI at image-build time and place it at `/boot/EFI/Linux/<kver>.efi`, removing the
raw `vmlinuz`/`initramfs.img` from the final image (they are embedded in the UKI). The
typical pattern is three stages: build the rootfs, split the kernel and initramfs out with
`bootc container split-kernel-and-rootfs`, then build the UKI with `bootc container ukify`
and copy it into the final image;

- enable composefs via `/usr/lib/ostree/prepare-root.conf` (`[composefs] enabled = yes`);

- keep the UKI **unsigned** and **not** enable Secure Boot.

`Containerfile.uki` in this repository is a **read-only reference** for the composefs + UKI
+ systemd-boot build (it targets Fedora). Do not modify it; adapt its approach into
`Containerfile`, targeting CachyOS.

Starting point: the `bootcrew/mono` repository's `arch/Containerfile` (the maintained Arch
bootc build), combined with the UKI/composefs approach demonstrated by `Containerfile.uki`.

4. Reference Implementations (bootcrew)

You may use:

https://github.com/bootcrew/arch-bootc

(the historical `bootc-crew/arch-bootc` no longer exists; it moved to `bootcrew/arch-bootc`,
which is deprecated in favour of the maintained monorepo `bootcrew/mono`, whose
`arch/Containerfile` and `shared/` scripts are the relevant reference)

as a reference implementation.

The fact that this project has moved from Arch Linux to CachyOS does not prohibit using the Arch bootc implementation as a technical reference.

It is acceptable to:

inspect it;

copy implementation ideas;

copy relevant files;

substantially adapt or copy portions of its implementation.

However:

do not use bootcrew/arch-bootc or bootcrew/mono as the FROM image;

do not make the final image dependent on those repositories;

keep the relevant implementation in this repository;

preserve applicable licensing/attribution requirements.

The objective is to build the CachyOS bootc image ourselves.

5. Do Not Use bootc-image-builder

Do not use bootc-image-builder.

It is not part of the desired architecture.

The installation path must instead use:

bootc install to-filesystem


followed by the appropriate current bootc finalization operation.

Verify the current bootc CLI and semantics from upstream documentation/source before implementing them.

Do not rely on old tutorials.

6. Use bootc install to-filesystem

The installer owns:

partitioning;

filesystem creation;

filesystem mounting;

disk layout.

The CachyOS bootc image owns:

operating system contents;

kernel;

initramfs;

systemd;

bootc deployment;

userspace.

The initial disk layout should be simple:

GPT
├── EFI System Partition
└── root filesystem

Initially use a conventional filesystem such as ext4. The root filesystem must support
fs-verity (ext4 and btrfs do), because the image is sealed and the composefs digest is
enforced at boot.

Do not introduce:

LUKS;

LVM;

btrfs subvolume complexity;

RAID;

Secure Boot;

until the basic workflow works end-to-end.

Note on Secure Boot: Secure Boot is explicitly out of scope for this project. The image is
sealed in the sense that the composefs digest of the root filesystem is baked into the UKI
kernel command line and enforced via fs-verity. The UKI is not signed, and Secure Boot
remains disabled. Sealing and Secure Boot are independent.

7. CachyOS Installer Environment

Use a CachyOS installer environment for the initial implementation.

If the official CachyOS ISO is suitable, use it.

If a custom/minimal installer ISO is more appropriate, build one.

The installer environment must provide the tools needed to:

boot;

obtain the bootc image;

access the local registry;

access /dev/vda;

partition the disk;

format filesystems;

mount the target;

perform bootc install to-filesystem;

finalize the installation;

reboot.

The installer environment is not the final OS.

The agent should not require manual interaction with the installer.

7.1 Sealed / UKI Requirements

These are the bootc prerequisites for a sealed composefs + UKI + systemd-boot image, and
must be satisfied by the image build:

- the container must include a kernel and initramfs in `/usr/lib/modules/<kver>/`;
- the container must have systemd-boot available and must NOT have bootupd;
- the container must not include a pre-built UKI (the build generates one);
- the root filesystem must support fs-verity (e.g. ext4, btrfs);
- composefs must be enabled via `/usr/lib/ostree/prepare-root.conf`.

Building a sealed image follows three stages: build the rootfs; split the kernel and
initramfs out of it with `bootc container split-kernel-and-rootfs`; then generate the UKI
with `bootc container ukify` and copy it into the final image at `/boot/EFI/Linux/<kver>.efi`.

Per upstream bootc: a sealed UKI can be used without Secure Boot enabled. The fs-verity
digest of the root filesystem is still validated at runtime. That is the model used here.

Consult the current upstream documentation for exact semantics before implementing:
https://github.com/bootc-dev/bootc/blob/main/docs/src/experimental-composefs.md

8. Local OCI Registry

Use a local OCI registry.

For example:

localhost:5000/cachyos-bootc:test


The workflow should:

build the image;

tag it;

push it to the local registry;

make it available to the installer VM.

The local registry should run in the development environment in a way compatible with the Distrobox/host networking setup.

Verify that the VM can actually reach it.

Do not assume localhost inside the VM refers to the Distrobox.

This networking detail must be explicitly handled.

9. libvirt/KVM

Use:

libvirt;

virsh;

virt-install;

QEMU/KVM.

Do not make raw QEMU command lines the primary VM interface.

The VM must be disposable.

Use UEFI firmware.

An initial VM configuration around:

2–4 vCPUs
4 GiB RAM
20–40 GiB virtual disk
virtio disk
virtio network


is sufficient unless testing shows otherwise.

Use a unique VM name, such as:

cachyos-bootc-test-<random-id>


Never destroy unrelated VMs.

10. SSH

SSH into the final CachyOS bootc VM is mandatory.

The workflow must be:

create VM
    ↓
boot installer
    ↓
install bootc image
    ↓
reboot
    ↓
wait for SSH
    ↓
SSH into CachyOS
    ↓
run tests


Do not rely on passwords.

Use an ephemeral SSH key or another controlled test credential.

Prefer a dedicated test user with appropriate sudo access.

Do not enable root password SSH merely to simplify automation.

Detect SSH readiness by polling with an explicit timeout.

Do not use an arbitrary fixed sleep as the readiness mechanism.

11. Automated VM Lifecycle

The integration test should approximately perform:

build image
    ↓
start/verify local registry
    ↓
push image
    ↓
create temporary libvirt VM
    ↓
boot CachyOS installer
    ↓
partition disk
    ↓
format filesystems
    ↓
mount target
    ↓
bootc install to-filesystem
    ↓
bootc install finalize
    ↓
reboot
    ↓
wait for SSH
    ↓
run tests
    ↓
collect diagnostics
    ↓
destroy VM
    ↓
remove VM definition
    ↓
remove disk


Cleanup must happen even if installation or testing fails.

12. Image Tests

Implement fast tests that do not require a VM wherever possible.

Test:

OCI image builds;

bootc metadata;

expected filesystem structure;

kernel;

initramfs;

kernel modules;

systemd;

required packages;

required files;

required services;

bootc functionality.

Use the current bootc validation facilities where appropriate.

13. VM Tests

The VM test suite must verify:

UEFI boot;

kernel boot;

initramfs;

systemd;

networking;

SSH;

bootc;

bootc status;

expected users;

expected services;

expected mounts;

expected CachyOS state;

application state where applicable;

sealed-image state: `bootc status` reports the composefs backend and a sealed deployment;

the UKI is present on the EFI System Partition (`/boot/EFI/Linux/<kver>.efi`);

systemd-boot is the bootloader (`bootctl status` reports it);

the kernel command line embeds the `composefs=` digest and it matches the mounted root.

The fact that the OCI image builds successfully is not sufficient.

The resulting installed system must actually boot.

14. bootc Update Test

After initial installation works, test the actual update mechanism.

Because the image is a sealed composefs/UKI image, each image version carries its own UKI
(with its own embedded composefs digest). Updates therefore stage a new deployment/UKI and
switch to it on reboot.

Use two image versions:

v1
v2


The workflow should be:

build v1
    ↓
install v1
    ↓
boot
    ↓
verify v1
    ↓
build/push v2
    ↓
perform current supported bootc update/upgrade
    ↓
reboot
    ↓
verify v2


Do not simply reinstall v2.

The objective is to verify the bootc deployment/update workflow.

15. Rollback Test

After update testing works, implement rollback.

On the composefs backend, rollback switches back to the previous deployment (and its UKI).

Conceptually:

v1
 ↓
v2
 ↓
reboot
 ↓
verify v2
 ↓
rollback
 ↓
reboot
 ↓
verify v1


Use the current bootc-supported rollback mechanism.

Verify the actual booted deployment after reboot.

16. Agent-Friendly Interface

Provide a simple command interface.

Prefer something similar to:

make build
make lint
make test
make vm-shell
make clean


The exact implementation is up to you.

make test should perform the complete disposable VM workflow.

make vm-shell should make debugging the resulting VM convenient.

All commands should be safe to run repeatedly.

17. Repository Structure

A reasonable initial structure is:

.
├── AGENT.md
├── TASKS.md
├── README.md
├── Containerfile
├── Makefile
├── docs/
│   ├── design.md
│   └── development.md
├── installer/
├── tests/
└── hack/


Adjust the structure when implementation experience justifies it.

Do not create unnecessary abstractions simply to match this example.

18. Documentation

Document:

Distrobox development environment;

host/libvirt relationship;

KVM access;

image build;

local registry;

installer environment;

bootc install to-filesystem;

filesystem layout;

libvirt VM lifecycle;

SSH;

integration tests;

update testing;

rollback testing;

debugging.

Keep documentation synchronized with actual behaviour.

19. Initial Task Breakdown

Create TASKS.md and start with a sequence similar to:

1. Inspect the Distrobox environment and verify KVM/libvirt access
2. Research current bootc to-filesystem requirements
3. Inspect current CachyOS packaging/image capabilities
4. Inspect bootcrew/mono (arch/Containerfile) and Containerfile.uki as references
5. Establish repository structure
6. Build minimal CachyOS OCI image (sealed: composefs + UKI + systemd-boot)
7. Add kernel/initramfs/systemd/UKI/bootc integration
8. Validate the bootc image
9. Establish local OCI registry
10. Establish CachyOS installer environment
11. Implement disk partitioning/filesystem setup
12. Implement bootc install to-filesystem
13. Implement installation finalization
14. Implement disposable libvirt VM creation
15. Automate installer boot
16. Automate reboot into CachyOS bootc
17. Implement SSH provisioning/readiness
18. Implement VM smoke tests
19. Implement diagnostics/artifact collection
20. Implement v1 → v2 bootc update testing
21. Implement rollback testing
22. Provide simple make/hack commands
23. Document the final workflow


This is only a starting point.

You may modify the breakdown after research.

Keep only one task in progress at any time.

20. First Action

Do not start by implementing the entire project.

Your first actions must be:

Read AGENT.md.

Create TASKS.md.

Put only Task 1 in In Progress.

Inspect the Distrobox environment.

Verify KVM access.

Verify virsh can communicate with the host libvirt instance.

Verify that a disposable VM can be created and destroyed.

Verify the networking path that the eventual VM will use to reach the local registry.

Record the findings.

Only then move to the next task.

Do not assume the Distrobox-to-host virtualization setup.

Verify it.

21. Definition of Done

The project is complete when an agent can run something equivalent to:

make test


and automatically:

build CachyOS bootc image (sealed, composefs + UKI)
        ↓
push to local registry
        ↓
create libvirt VM
        ↓
boot CachyOS installer
        ↓
partition/format/mount disk
        ↓
bootc install to-filesystem (composefs backend, systemd-boot)
        ↓
finalize
        ↓
reboot
        ↓
boot actual sealed CachyOS bootc system
        ↓
wait for SSH
        ↓
run automated tests
        ↓
test update
        ↓
test rollback
        ↓
collect results
        ↓
destroy everything


with no manual interaction.

The final image must be constructed by this repository.

It must not be an existing CachyOS bootc image pulled from elsewhere.

The test must exercise the real installed system, not merely inspect the container image.

Final Instruction

Read and follow AGENT.md.

Maintain TASKS.md.

Work on exactly one task at a time.

Do not lose focus.

Do not silently skip tasks.

Do not use bootc-image-builder.

Do not use a prebuilt CachyOS bootc image as the base.

Use bootcrew/mono (arch/Containerfile) and Containerfile.uki as reference material where useful; do not modify Containerfile.uki.

Build the CachyOS bootc image yourself.

Build a sealed image: composefs backend, systemd-boot, and an unsigned UKI. Do not enable Secure Boot and do not include bootupd.

Use bootc install to-filesystem.

Use libvirt/QEMU/KVM for the disposable VM.

SSH into the resulting system and test it automatically.

Keep all documentation (README.md, TASKS.md, docs/, contrib/) consistent with the sealed composefs + UKI + systemd-boot architecture.

Verify every step before moving to the next task.
