# Tasks

## Completed

- [x] Task 1 — Inspect the Distrobox environment and verify KVM/libvirt access
- [x] Task 2 — Research current bootc to-filesystem requirements
- [x] Task 3 — Inspect current CachyOS packaging/image capabilities
- [x] Task 4 — Inspect bootc-crew/arch-bootc as a reference
- [x] Task 5 — Establish repository structure
- [x] Task 6 — Build minimal CachyOS OCI image (ostree variant)
- [x] Task 7 — Add kernel/initramfs/systemd/bootc integration (ostree variant)
- [x] Task 8 — Validate the bootc image (ostree variant)
- [x] Task 9 — Establish local OCI registry
- [x] Task 10 — Establish CachyOS installer environment
- [x] Task 26 — Retarget the image to sealed composefs + systemd-boot + UKI (no Secure Boot)
- [x] Task 27 — Update image tests for sealed/UKI expectations
- [x] Task 11 — Implement disk partitioning/filesystem setup
- [x] Task 12 — Implement bootc install to-filesystem (composefs backend)
- [x] Task 13 — Implement installation finalization
- [x] Task 14 — Implement disposable libvirt VM creation
- [x] Task 15 — Automate installer boot
- [x] Task 16 — Automate reboot into CachyOS bootc
- [x] Task 17 — Implement SSH provisioning/readiness
- [x] Task 18 — Implement VM smoke tests
- [x] Task 19 — Implement diagnostics/artifact collection
- [x] Task 20 — Implement v1 → v2 bootc update testing
- [x] Task 21 — Implement rollback testing
- [x] Task 22 — Provide simple make/hack commands
- [x] Task 23 — Document the final workflow

## In Progress

- [ ] Task 28 — Replace password bring-up auth with durable key injection (composefs)

## Remaining


## Blocked

- (none)

## Notes

- **DIRECTION CHANGE (current):** the project target is now a **sealed** CachyOS bootc image
  using the **composefs backend + systemd-boot + an unsigned UKI**, with fs-verity enforced
  and **Secure Boot disabled**. `bootupd` is **not** used. This supersedes the earlier
  ostree-backend approach. See PROMPT.md, AGENTS.md and docs/design.md.
- **Superseded (ostree/bootupd) — kept for the record:** bootc's ostree backend on x86_64
  requires `bootupd` for bootloader install, and bootupd's EFI payload generation is
  Fedora/RPM-specific (expects a shim and Fedora's `/usr/lib/efi` layout). We built bootupd
  from source with the AUR Arch path patch (`hack/patches/bootupd-archlinux-grub-paths.patch`,
  since removed as unused), but the sealed composefs + systemd-boot + UKI path avoids bootupd
  entirely. The `bootcrew/mono` reference avoids `to-filesystem` (uses `to-disk
  --via-loopback`), consistent with `to-filesystem` + bootupd on Arch being non-trivial; the
  sealed UKI path supports `to-filesystem`.
- Installer ISO is built by hand (squashfs + GRUB EFI + El Torito) in
  `installer/iso/build-iso.sh`. It boots correctly and is the only installer packaging used.
- **Image transfer:** the installer pulls the image into containers-storage using the overlay
  driver with `fuse-overlayfs` (the live root is overlayfs), then runs
  `podman run <image> bootc install to-filesystem --source-imgref containers-storage:<ref>`.
  A `vfs` storage driver was tried first but expands the ~3.4 GiB image to ~5 GiB and
  exhausted the live environment's writable space. (An OCI-layout + `oci:` imgref approach
  was also tried; the pull works, but bootc still required bootupd, which is why the sealed
  UKI path was chosen.)
- **bootupd is required (blocking Task 12).** On x86_64, bootc's ostree backend can only
  install the bootloader via `bootupd` (`crates/lib/src/install.rs`: `Bootloader::Systemd =>
  anyhow::bail!("bootupd is required for ostree-based installs")`). `supports_bootupd()`
  needs a `bootupctl` binary on PATH **and** `usr/lib/bootupd/updates` in the target root.
  There is no bootupd package in CachyOS/Arch repos; we build it from source and adapt paths
  for Arch. An AUR package exists (`bootupd`, 0.2.34) plus a small patch
  (`0001-Modify-grub-paths-to-match-Arch-Linux.patch`) that only renames
  `grub2-install`→`grub-install` and `/boot/grub2`→`/boot/grub`. bootupd is otherwise
  RPM-centric (payload generation queries the rpm db, expects `/usr/lib/efi` or
  `/usr/lib/ostree-boot`); the Fedora base image ships pre-built
  `/usr/lib/bootupd/updates/{EFI.json,BIOS.json}` + `grub2-static/`, which the Arch AUR
  package does not. Tracked as Task 25.
- **Task 25 detail (bootloader on x86_64):** bootc selects `Bootloader::Grub` because
  `bootupctl` + `usr/lib/bootupd/updates` are present, then runs `bootupctl backend install
  --write-uuid --update-firmware --auto --filesystem /sysroot /`. bootupd then needs
  **EFI update metadata**: `bootupd generate-update-metadata` scans `/usr/lib/efi` (Fedora's
  layout) or `/usr/lib/ostree-boot`, and its EFI component requires a **`shim`**
  (`find_file_recursive(..., SHIM)`), erroring `Failed to find shim in the image` otherwise.
  Fedora ships `/usr/lib/efi/shim/<v>/EFI/{BOOT,<vendor>}/*` + `/usr/lib/efi/grub2/<v>/...`
  and pre-built `updates/{EFI,BIOS}.json`. **CachyOS/Arch do have `shim` (16.1) and
  `shim-signed` (16.1+fedora+8) packages**, so reproducing a Fedora-style `/usr/lib/efi`
  layout and running the metadata generator is a viable path. Tracked as Task 25.
- **Note (historical):** the `bootcrew/mono` Arch reference deliberately uses `bootc install
  to-disk --via-loopback` rather than `to-filesystem`, consistent with `to-filesystem` +
  bootupd on Arch being non-trivial. Our project requires `to-filesystem`; the sealed composefs
  + systemd-boot + UKI path supports it without bootupd.
- **Where the ostree workflow reached (historical):** partition → format → mount → pull image
  into containers-storage (overlay+fuse-overlayfs) → `podman run <image> bootc install
  to-filesystem` → image deploys successfully → stopped at bootloader install for lack of a
  usable bootupd payload.
- Tasks 1–4 are discovery/research. TASKS.md initial breakdown is a starting point and may
  be revised after research (per PROMPT.md §19).
- The project began with no source tree other than AGENTS.md and PROMPT.md.

### Task 1 findings (verified, see docs/development.md)

- Container is a rootless-podman Distrobox on a **Fedora 44** host (`WORKSTATION`), running
  the CachyOS v3 image. Host kernel shared.
- `/dev/kvm` present; libvirt domains run with `-accel kvm` (real hardware acceleration).
- Host libvirt reached via `virsh -c qemu:///system` (must pass `-c` explicitly; default is
  session). Host `default` NAT network active: `virbr0` 192.168.122.1/24.
- libvirt runs QEMU as host **uid 107**. VM disks must be host-visible and uid-107-owned;
  they cannot live under `/home` (0700). Use host `/var/tmp` = container
  `/run/host/var/tmp`; domain XML must use the host path.
- `/run/host` is idmapped: QEMU-created files are unreadable from the container. Capture the
  serial console via `<serial type='pty'>` + `virsh console` under `script`.
- UEFI/OVMF is auto-selected by `<os firmware='efi'>`; firmware lives on the host.
- Container has **no netns admin**: cannot modify host networking/firewall.
- VM networking verified: DHCP, ICMP to gateway, and outbound NAT work. **Inbound TCP to a
  host-bound service (registry) is blocked while host firewalld runs**; with firewalld
  stopped, a guest reached `192.168.122.1:5000` successfully. The workflow must verify and
  report this precondition.
- Disposable VM define/start/console-capture/destroy cycle exercised and cleaned up.

### Task 2 findings

- `bootc install to-filesystem <root>` installs to an externally prepared/mounted root; then
  `bootc install finalize <root>`. The bootloader (systemd-boot for our sealed image, or
  bootupd/GRUB) installs with the ESP mounted at `<root>/boot/efi`.
- `--source-imgref <imgref>` lets the installer fetch a given image reference without
  assuming podman container storage — this is the mechanism for our installer environment.
- Image needs: `LABEL containers.bootc=1`; a single kernel at `/usr/lib/modules/$kver/vmlinuz`
  plus `initramfs.img`; no `/boot` content; `/sysroot`; `/ostree -> /sysroot/ostree`;
  `prepare-root.conf` with composefs enabled; `bootc container lint` must pass.

### Task 3 findings

- Base image: `docker.io/cachyos/cachyos-v3:latest` (Arch-based, x86-64-v3), updated daily.
  Repos: `cachyos-v3`, `cachyos-core-v3`, `cachyos-extra-v3`, `cachyos`, Arch `core`,
  `extra`, `multilib`.
- The base image has systemd but **no bootc, kernel, dracut, or ostree** — our build adds them.
- All needed packages exist in the repos (base, linux, linux-firmware, dracut, ostree,
  btrfs-progs, e2fsprogs, xfsprogs, dosfstools, skopeo, podman, dbus, shadow, openssh, cpio,
  efibootmgr, grub). `systemd-boot` is provided by `systemd` (bootctl).
- No `bootc`/`bootupd` package exists → **build bootc from source** (as the reference does).
- Verified `bootc v1.16.13` builds from source inside the CachyOS image with deps:
  `base base-devel rust make git go-md2man pkgconf ostree glibc cmake jq libselinux clang
  llvm`. `make bin` + `make install DESTDIR=/output` installs the binary, dracut module,
  systemd units and baseimage config (`libselinux` headers and `clang`/`libclang` are needed
  by `selinux-sys`/`bindgen`).
- Latest bootc release at time of writing: `v1.16.13`; the container has `bootc 1.16.12`.

### Task 4 findings

- `bootc-crew/arch-bootc` (named in the prompt) **no longer exists** (404). It moved to
  `bootcrew/arch-bootc`, whose README marks it deprecated in favour of `bootcrew/mono`.
- `bootcrew/arch-bootc` and `bootcrew/mono` are **Apache-2.0** (Copyright 2025 tulilirockz).
  We may adapt ideas/code with attribution.
- `bootcrew/mono/arch/Containerfile` + `shared/{build.sh,initramfs.sh,bootc-rootfs.sh}` is
  the maintained Arch bootc build. It builds bootc from source in a builder stage and
  installs into `archlinux:latest`.
- Their boot/disk path uses `bootc install to-disk --via-loopback` (not our required
  `to-filesystem`) and `bcvk` (ephemeral QEMU + a libvirt path) for boot testing. We will
  implement our own libvirt/virsh harness per the project requirements instead.

### Task 6 findings

- `Containerfile` implements a two-stage build: builder compiles `bootc v1.16.13` from
  source; system stage installs the CachyOS base + bootc prerequisites, generates the
  initramfs, and lays out the bootc root filesystem.
- **Rootless-podman build gotcha:** the CachyOS base pacman sandboxes downloads/hooks
  (Landlock/seccomp); that fails inside a rootless podman build with `could not isolate the
  network`, silently skipping package hooks (depmod/dracut/systemd). Fix: add `DisableSandbox`
  to `[options]` in `/etc/pacman.conf` during the build. Without it `modules.dep` is missing
  and dracut fails.
- `bootc` binary needs `libselinux` at **runtime**, not just headers in the builder.
- `make build` produces `localhost:5000/cachyos-bootc:test`; verified content:
  bootc 1.16.13 at `/usr/bin/bootc`, single kernel `7.2.6-arch2-1` with `vmlinuz` +
  `initramfs.img`, `/sysroot`, `/ostree -> sysroot/ostree`, empty `/boot`,
  `prepare-root.conf` (composefs), `/usr/lib/bootc/install/00-cachyos.toml` (ext4),
  systemd units, dracut `51bootc` module, `LABEL containers.bootc=1`.
- `bootc container lint` passes (10 checks passed) with **4 warnings** to fix in Task 7:
  `runtime-deps` (missing `chcon`), `var-log` (`/var/log/pacman.log`), `var-tmpfiles`
  (`/var` entries with no tmpfiles/tmp), `nonempty-run-tmp` (`/run`/`/tmp` content), plus
  leftover pacman package cache in `/var/cache/pacman/pkg`.
- `chcon` is only provided by `coreutils-uutils` on CachyOS, which conflicts with
  `coreutils`. Since Arch/CachyOS has no SELinux and bootc only probes `chcon` in its
  SELinux install path, this is left as a lint warning for now (to revisit if install
  requires it).

### Task 7 findings

- Relocated pacman's `DBPath`/`CacheDir`/`LogFile` into `/usr/lib/sysimage/...`; `/var` is
  now effectively empty (only standard `btmp`/`lastlog`/`wtmp` remain).
- Added `/usr/lib/tmpfiles.d/bootc-cachyos-var.conf` declaring all `/var` directories and
  the `/var/lock`, `/var/mail` symlinks, and removed generated `/var` files plus `/tmp` X11
  sockets.
- `bootc container lint` now reports **13 checks passed, 1 warning** (`chcon`). Lint exits 0.
- `bootc status` runs inside the image; the `bootc-cachyos-var.conf` naming and the final
  lint step keep the build self-validating.

### Task 8 findings

- `tests/image/test-image.sh` performs 27 VM-less checks: OCI label, bootc binary/version,
  kernel + initramfs (single kernel, compressed image), filesystem layout (`/sysroot`,
  empty `/boot`, `/ostree` symlink), bootc config (composefs, ext4, dracut module),
  systemd services, required packages, `bootc status --json`, and `bootc container lint`.
- All 27 checks pass. `make image-test` runs it; `make lint` runs `bootc container lint`,
  `bash -n` and `shellcheck` over all project scripts (shellcheck installed in the dev
  container).

### Task 9 findings

- `hack/registry.sh` runs `registry:2` as container `cachyos-bootc-registry` with
  `--network host`, binding `192.168.122.1:5000`; exposes start/stop/status/push.
- `make registry-start/stop/status/push` wrap it (idempotent). Image is pushed as
  `192.168.122.1:5000/cachyos-bootc:test` over plain HTTP so the VM can pull it by IP.
- Verified: registry serves `/v2/`, `_catalog` lists `cachyos-bootc`, tag `test` present.
- VM→registry reachability was proven in Task 1 (guest fetched from `192.168.122.1:5000` with
  firewalld stopped). A hand-rolled minimal probe initramfs later failed to instantiate the
  virtio NIC reliably (PCI sysfs/driver-binding issues in a bare busybox init), so the
  definitive in-VM registry pull is exercised by the real installer workflow rather than a
  hand-rolled guest. Note the operator assumption: **firewalld is stopped**.

### Task 10 findings

- Built a minimal custom CachyOS **live ISO** (`installer/`, `hack/build-installer.sh`):
  squashfs live root + GRUB EFI + El Torito, `artifacts/cachyos-bootc-installer.iso` (~1.1 GiB).
- **Critical:** test VMs must use `<cpu mode='host-passthrough' check='none'/>`. With the
  default QEMU CPU model, the CachyOS v3 userland executes unsupported instructions and
  systemd panics (`Attempted to kill init! exitcode=0x00000004`). Host CPU has AVX2, no
  AVX-512.
- **Verified:** the ISO boots UEFI → GRUB → kernel → dracut → live squashfs root → systemd
  multi-user, brings up DHCP, and runs `install-bootc.service`. Without
  `bootc.install.imgref` the service correctly fails with a clear error.
- The install service takes `bootc.install.{imgref,device,rootfs,action,finalize}` from the
  kernel command line; partitioning/formatting/mounting and the podman-driven
  `bootc install to-filesystem` are implemented in `installer/stage/install-bootc.sh`.

### Task 26 findings (sealed composefs + systemd-boot + UKI retarget)

- `Containerfile` now builds the sealed image in five stages:
  1. `bootc-builder` — compiles `bootc` from source (no bootupd; the bootupd source build
     and Arch path patch were removed).
  2. `rootfs` — CachyOS base + kernel + `dracut` + `systemd-ukify` + filesystem tools.
     `systemd-boot` needs no extra package: the CachyOS `systemd` package already ships
     `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` and `bootctl`. `bootupd` is
     deliberately absent. Adds `/usr/lib/bootc/kargs.d/00-console.toml`,
     `/usr/lib/composefs/setup-root-conf.toml` (bind `/etc` and `/var`), and runs
     `bootc container lint`.
  3. `split` — `bootc container split-kernel-and-rootfs --rootfs / --output /kernel`
     moves `vmlinuz`/`initramfs.img` out of the rootfs.
  4. `sealed-uki` — `bootc container ukify --rootfs /target --kernel-dir /kernel/<kver>
     -- --output /out/<kver>.efi`. No `--signtool`/`--secureboot-*`, so the UKI is
     unsigned. `--allow-missing-verity` is **not** passed, so fs-verity is enforced.
  5. `final` — the split rootfs plus the UKI at `/boot/EFI/Linux/<kver>.efi`.
- **Verified (Task 26):** the full build succeeds. The resulting image has exactly one UKI
  (`/boot/EFI/Linux/7.2.6-arch2-1.efi`, ~43 MiB), no raw `vmlinuz`/`initramfs.img`, no
  `bootupctl`/`/usr/lib/bootupd`, systemd-boot + `bootctl` + `ukify` present, composefs
  configs present, and `LABEL containers.bootc=1`.
- **Verified:** the UKI cmdline is
  `console=tty0 console=ttyS0 rw composefs=<128-hex sha512>` — note the digest has **no
  `?` prefix**, i.e. fs-verity is enforced. `ukify inspect` shows only `.sbat/.osrel/
  .cmdline/.uname/.linux/.initrd` sections and **no signature section** (unsigned).
- **Verified:** `bootc container lint` passes on both the `rootfs` stage and the final
  (split) image: 13 checks passed, 1 warning (`chcon`, pre-existing). The `kernel` lint
  ignores the missing `vmlinuz` (it only errors on *multiple* kernel dirs).
- **`bootc install` UKI constraint (Task 12 input):** for a UKI install bootc rejects any
  `--karg` (`crates/lib/src/bootc_composefs/boot.rs`: `require_no_kargs_for_uki()` →
  `Cannot use externally specified kernel arguments with UKI`). `installer/stage/
  install-bootc.sh` was updated to pass **no** `--karg`; the serial-console karg comes from
  the image's `kargs.d`.
- **Upstream mirror issue (build blocker, worked around):** the base image's default
  CachyOS mirrorlist lists the cdn77 CDN first, which served a `cachyos.db`/`.sig` pair that
  does not match (`signature ... is invalid`); pacman does not fall through past a bad
  signature. The `Containerfile` pins `us.cachyos.org`/`at.cachyos.org` (tier-1 origin
  mirrors) instead. Also note the base `cachyos-keyring` (20240331-1) is older than the
  rotated CachyOS signing key; on this image the key is present, but if a future base lacks
  it the build must `pacman-key --recv-keys 882DCFE48E2051D48E2562ABF3B607488DB35A47`
  before the first sync. Remove the mirror pin once cdn77 is consistent again.

### Task 27 findings (sealed image tests)

- `tests/image/test-image.sh` now asserts the sealed/UKI layout instead of the old raw
  kernel/initramfs: exactly one UKI in `/boot/EFI/Linux`, UKI cmdline carries a
  `composefs=` digest, fs-verity enforced (no `?` prefix), UKI unsigned (no signature
  section), raw `vmlinuz`/`initramfs.img` absent, systemd-boot/`bootctl`/`ukify` present,
  bootupd absent, composefs `/etc`+`/var` bind config present, and the serial-console karg.
- **Verified:** all 35 checks pass against the freshly built image.

### Task 11–19 findings (install, boot, SSH, tests, diagnostics)

- **Install flow (verified end-to-end in a disposable VM):** installer ISO boots → partitions
  with **DPS GUIDs** (root `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`, ESP `ef00`) → mkfs →
  mounts → **self-install** `bootc install to-filesystem` from inside the sealed image →
  `Installation complete!` in ~4 min.
- **`--source-imgref` is wrong for a UKI image.** With `--source-imgref` bootc sets
  `target_rootfs=None`, never sees the UKI, and defaults to the **ostree** backend, failing
  with `Failed to find kernel in /usr/lib/modules, /usr/lib/ostree-boot or /boot`. Running as
  a **self-install** (no `--source-imgref`) makes bootc inspect its own rootfs, detect the UKI
  (`unified=true`), and auto-select the **composefs backend + systemd-boot**. We pass neither
  `--source-imgref` nor `--composefs-backend` (forcing the backend bypasses UKI-driven logic).
- **DPS root GUID is mandatory.** The sealed UKI cmdline has no `root=` (bootc rejects kargs
  with a UKI), so the initramfs finds root via `systemd-gpt-auto-generator`. A generic `8300`
  root type GUID yields emergency mode (`Dependency failed for Initrd Root Device` /
  `OSTree Prepare OS`). Using the DPS x86-64 root GUID fixes it.
- **`bootc install finalize` is ostree-only.** It loads an ostree sysroot
  (`opendir(ostree/repo): No such file or directory`) which the composefs backend does not
  have. We skip it (`bootc.install.finalize` is effectively ignored).
- **bootc's built-in finalization can hang on a bind-mounted target.** `fstrim` completes,
  but the subsequent `mount -o remount,ro` + `fsfreeze` blocked indefinitely (QEMU ~5% CPU,
  disk full). Fixed by passing **`--skip-finalize`** and doing `fstrim` + `remount,ro`
  ourselves on the installer side, where we control the mounts. Applied **after** the SSH-key
  injection so the target is still writable for that write.
- **SSH bring-up uses a password (Option B).** `--root-ssh-authorized-keys` is **not
  implemented for the composefs backend** (bootc calls `inject_root_ssh_authorized_keys` only
  in the ostree `install_container` path). We could not get key injection to stick: writing a
  tmpfiles drop-in to the target's `/etc/tmpfiles.d/` did **not** appear on the running
  system (`/etc` is composed/bind-mounted), and sshd rejected the key. For bring-up the image
  now bakes `PermitRootLogin yes` + `PasswordAuthentication yes` + `chpasswd root:bootc-test`
  and `ssh-keygen -A` (mirrors `Containerfile.uki`). This isolated the failure to key
  provisioning (not SSH): password login works, `sshd` is fine, the sealed system is correct.
  Durable key injection is tracked as **Task 28**.
- **Sealed state confirmed over SSH:** `/` is `composefs:<digest>` mounted `ro`, `/sysroot`
  ext4 `ro`, `/etc`+`/var` ext4 `rw`, cmdline `composefs=<sha512>` with **no `?`** (fs-verity
  enforced), `bootc status` shows a booted composefs deployment.
- **Console capture:** libvirt's `<log>` file is unusable from the Distrobox (idmapped
  `/run/host`; libvirt also refuses a pre-created log path), so we capture via `virsh console`
  with a retry loop (`vm_capture_console`). This reliably captured install and boot logs.
- **Harness:** `hack/lib/vm.sh` (VM lifecycle, `vm_boot_from_disk`, console), `hack/lib/ssh.sh`
  (key/password SSH, `ssh_guest_ip`), `tests/vm/{install,boot,smoke,run}.sh`. `run.sh` chains
  install → boot → smoke and cleans up; artifacts under `artifacts/<run-id>/`.
- **Verified (Tasks 14–19):** `tests/vm/run.sh` completes install → boot → **16/16 smoke
  checks** automatically and removes the VM. Diagnostics collection (`vm-diagnostics.txt` on
  smoke failure) exercised and working.

### Task 20–22 findings (update, rollback, commands)

- **Versioned images.** `Containerfile` takes `ARG IMAGE_VERSION` (default `1`), baked as
  `/usr/lib/bootc-image-version` (in `/usr`, i.e. part of the composefs image) and as the OCI
  label `org.cachyos.bootc.image-version`. So `--build-arg IMAGE_VERSION=2` yields a
  distinguishable v2 whose composefs digest differs. `make image-v1` / `make image-v2`.
- **Registry is plain HTTP.** `bootc switch`/`upgrade` on the target default to HTTPS for the
  `registry` transport and fail with `server gave HTTP response to HTTPS client`. The
  production image does **not** bake in an insecure-registry entry; the update/rollback tests
  write `/etc/containers/registries.conf.d/10-local.conf` (insecure `192.168.122.1:5000`) on
  the guest first (`/etc` is writable machine-local state).
- **Update verified (Task 20):** install v1 → boot → `bootc switch --transport registry
  ...:v2` → staged (`bootType: Uki`, `bootloader: systemd`, `missingVerityAllowed: false`) →
  reboot → booted version **2**, no staged deployment. `tests/vm/upgrade.sh` does this
  automatically and passed.
- **Rollback verified (Task 21):** from booted v2, `bootc rollback` → "Next boot: rollback
  deployment" → reboot → booted version **1**. `tests/vm/rollback.sh` passed automatically.
- **Commands (Task 22):** `make test` (install→boot→smoke), `make vm-install`,
  `make vm-update` (v1→v2), `make vm-rollback` (v1→v2→v1), `make image-v1`/`image-v2`,
  `make image-test`, registry targets. `tests/vm/run.sh` accepts `--update`, `--to REF`,
  `--rollback`, `--image`, `--keep`. `make lint` is clean (shellcheck passes).

### Task 23 findings (documentation) + final status

- Docs updated to the verified state: `README.md` (status, commands, layout),
  `docs/design.md` (install flow is a self-install; DPS GUIDs; `--skip-finalize`; update/
  rollback verified; structure), `docs/development.md` (console capture, install/boot
  findings).
- **`make test` verified end-to-end with a freshly built image:** install → boot → **16/16**
  smoke checks → VM destroyed. `make lint` is clean (shellcheck passes).
- `make vm-shell` implemented (`hack/vm-shell.sh`): interactive SSH to a running test VM.
- All tasks complete except **Task 28** (durable composefs SSH key injection; bring-up uses a
  baked-in password for now).
