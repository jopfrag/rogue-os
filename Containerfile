# CachyOS bootc image — sealed (composefs + UKI + systemd-boot)
#
# Built from the CachyOS/Arch base image. This repository constructs the bootc image
# itself; it does not derive from another bootc image.
#
# The image is "sealed": the bootc composefs backend is used, the kernel is packaged as
# a Unified Kernel Image (UKI) that carries the composefs digest on its kernel command
# line, and fs-verity enforcement is enabled. The UKI is deliberately UNSIGNED and
# Secure Boot is NOT used.
#
# The bootloader is systemd-boot. bootupd is deliberately NOT installed: bootc selects
# systemd-boot when bootupd is absent, and the composefs backend installs it via
# `bootctl install`. (Installing bootupd would instead select the ostree/GRUB path,
# which is not what this project targets.)
#
# Build stages:
#   1. bootc-builder — compile the `bootc` binary from source.
#   2. rootfs        — CachyOS base + kernel/initramfs/systemd, laid out per bootc.
#   3. split         — `bootc container split-kernel-and-rootfs` (kernel out of rootfs).
#   4. sealed-uki    — `bootc container ukify` builds the unsigned UKI.
#   5. final         — split rootfs + the UKI at /boot/EFI/Linux/<kver>.efi.
#
# References: bootc image requirements (docs/src/bootc-images.md) and the sealed
# composefs + UKI pattern in Containerfile.uki (read-only reference in this repo).
# Attribution: see contrib/ATTRIBUTION.md.

# Pin the bootc version to an exact commit so builds are reproducible and immune to
# tag moves. This is the dereferenced commit for the v1.16.13 annotated tag. When bumping,
# update both BOOTC_VERSION (descriptive) and BOOTC_COMMIT (the immutable ref).
ARG BOOTC_VERSION=v1.16.13
ARG BOOTC_COMMIT=fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60

# CachyOS mirror(s) to use. Empty (default) means "use the base image's own mirrorlist",
# which carries ~40 mirrors and fallback. Set this to space-separated `Server = ` URLs to
# pin a specific mirror, e.g. to work around a transient mismatch (upstream mirror
# flakiness is recurring). Each entry may use the pacman `$arch`/`$repo` placeholders.
ARG CACHYOS_MIRROR=""

# Kernel + firmware package set. Defaults to the CachyOS kernel plus firmware for this
# development laptop (AMD 5500U 'Green Sardine' iGPU + Intel AX200). Override with a space
# separated package list to build a portable image (e.g. use the monolithic linux-firmware).
ARG KERNEL_PKGS="linux-cachyos"
ARG FIRMWARE_PKGS="linux-firmware-amdgpu linux-firmware-intel amd-ucode"

FROM docker.io/cachyos/cachyos-v3:latest AS bootc-builder

ARG BOOTC_VERSION
ARG BOOTC_COMMIT
ARG CACHYOS_MIRROR

# The base image's pacman sandboxes downloads and package hooks (Landlock/seccomp).
# That sandbox cannot isolate the network inside a rootless podman build, which makes
# package hooks (depmod, dracut, systemd) fail. Disable it for the image build.
#
# Mirror workaround: optionally pin specific CachyOS mirrors (see CACHYOS_MIRROR). When
# CACHYOS_MIRROR is empty, the base image's default mirrorlist (with fallback) is used;
# this is the robust default given recurring upstream mirror flakiness.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && if [[ -n "${CACHYOS_MIRROR}" ]]; then \
         : > /etc/pacman.d/cachyos-mirrorlist; \
         for m in ${CACHYOS_MIRROR}; do printf 'Server = %s\n' "$m" >> /etc/pacman.d/cachyos-mirrorlist; done; \
       fi

# Build dependencies for bootc. libselinux headers and clang/libclang are required by
# selinux-sys/bindgen; pkgconf, ostree and glibc complete the native dependency set.
RUN pacman -Sy --noconfirm --needed \
        base base-devel rust make git go-md2man pkgconf ostree glibc \
        cmake jq libselinux clang llvm patch \
    && pacman -S --clean --noconfirm

# Build bootc from source. The upstream Makefile builds the `release` profile, which keeps
# debug info and yields a ~330 MiB binary. Override the release profile through cargo's env
# vars to strip it and optimise for size (~10 MiB) without changing the Makefile.
ENV CARGO_PROFILE_RELEASE_DEBUG=false \
    CARGO_PROFILE_RELEASE_STRIP=true \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_OPT_LEVEL=s \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_PANIC=abort

# Local patch: allow f2fs as a (fs-verity capable) install filesystem. Simple, reviewable;
# applies cleanly to the pinned bootc commit. See docs/design.md for the f2fs investigation.
COPY bootc-f2fs.patch /tmp/bootc-f2fs.patch

RUN git clone --depth 1 --branch "${BOOTC_VERSION}" \
        https://github.com/bootc-dev/bootc.git /tmp/bootc \
    && git -C /tmp/bootc checkout "${BOOTC_COMMIT}" \
    && git -C /tmp/bootc apply /tmp/bootc-f2fs.patch \
    && make -C /tmp/bootc bin DESTDIR=/output \
    && make -C /tmp/bootc install DESTDIR=/output \
    && rm -rf /tmp/bootc

# ---------------------------------------------------------------------------

FROM docker.io/cachyos/cachyos-v3:latest AS rootfs

ARG CACHYOS_MIRROR
ARG KERNEL_PKGS
ARG FIRMWARE_PKGS

# See note in the builder stage: pacman's sandbox cannot work inside a rootless podman
# build, and its failure skips package hooks (depmod, dracut, systemd). The optional
# CACHYOS_MIRROR pin is also repeated here (see the builder stage comment).
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && if [[ -n "${CACHYOS_MIRROR}" ]]; then \
         : > /etc/pacman.d/cachyos-mirrorlist; \
         for m in ${CACHYOS_MIRROR}; do printf 'Server = %s\n' "$m" >> /etc/pacman.d/cachyos-mirrorlist; done; \
       fi

# Base system plus the packages bootc needs at runtime and for installation:
#   - KERNEL_PKGS: kernel package(s); defaults to linux-cachyos (the CachyOS BORE kernel).
#   - FIRMWARE_PKGS: firmware packages; defaults to a trimmed set for this development
#     laptop (AMD 5500U "Green Sardine" iGPU + Intel AX200). Override via --build-arg to
#     build a portable image (e.g. FIRMWARE_PKGS="linux-firmware").
#   - dracut + cpio: initramfs generation
#   - ostree/libselinux: bootc dependencies (ostree also provides the bootc backend data)
#   - filesystem tools: e2fsprogs, xfsprogs, btrfs-progs, f2fs-tools, dosfstools
#   - systemd-ukify: builds the UKI (pulls binutils, python-pefile, ...)
#   - skopeo/podman: image transport and pulling
#   - systemd (base) also ships systemd-boot (bootctl + systemd-bootx64.efi), so no
#     separate systemd-boot package is required. bootupd is deliberately NOT installed.
#   - systemd/dbus/shadow/openssh: userspace
#   - efibootmgr: used by bootctl to manage EFI boot variables during install
RUN pacman -Syu --noconfirm --needed \
        base \
        ${KERNEL_PKGS} \
        ${FIRMWARE_PKGS} \
        dracut cpio \
        ostree libselinux \
        btrfs-progs e2fsprogs xfsprogs f2fs-tools dosfstools \
        systemd-ukify \
        skopeo podman fuse-overlayfs \
        dbus dbus-glib glib2 shadow \
        openssh \
        efibootmgr \
        cachyos-rate-mirrors \
    && pacman -Scc --noconfirm

# Move pacman's mutable state out of /var so the image's /var is (nearly) empty, as
# required by bootc's `var-tmpfiles` lint. On a bootc system /var is machine-local
# state and only the image's initial /var content is provisioned; keeping the package
# database and cache there would interfere. Adapted from bootcrew/arch-bootc and
# bootcrew/mono (Apache-2.0). See contrib/ATTRIBUTION.md.
#
# The three standard writable locations (DBPath, CacheDir, LogFile) are relocated
# explicitly rather than parsed out of pacman.conf, so this does not drift with the base.
# Content is moved out of /var (not copied) so the image's /var stays empty as bootc
# requires; any populated dir is re-created empty under /usr/lib/sysimage.
RUN install -d /usr/lib/sysimage/pacman \
    && if [[ -d /var/lib/pacman ]]; then mv /var/lib/pacman /usr/lib/sysimage/pacman/lib; else install -d /usr/lib/sysimage/pacman/lib; fi \
    && install -d /usr/lib/sysimage/cache/pacman \
    && if [[ -d /var/cache/pacman/pkg ]]; then mv /var/cache/pacman/pkg /usr/lib/sysimage/cache/pacman/pkg; else install -d /usr/lib/sysimage/cache/pacman/pkg; fi \
    && install -d /usr/lib/sysimage/log \
    && if [[ -f /var/log/pacman.log ]]; then mv /var/log/pacman.log /usr/lib/sysimage/log/pacman.log; fi \
    && sed -i \
        -e 's@^\(#\)\?DBPath.*@DBPath = /usr/lib/sysimage/pacman/lib/@' \
        -e 's@^\(#\)\?CacheDir.*@CacheDir = /usr/lib/sysimage/cache/pacman/pkg/@' \
        -e 's@^\(#\)\?LogFile.*@LogFile = /usr/lib/sysimage/log/pacman.log@' \
        -e '/DownloadUser/d' \
        /etc/pacman.conf

# Install bootc (binary, systemd units, dracut module, baseimage reference content).
COPY --from=bootc-builder /output /

# Provide a default root filesystem type for `bootc install` and for external installers
# that consult `bootc install print-configuration`. The composefs backend enforces
# fs-verity on a sealed UKI, so the root filesystem must support it. f2fs is used (not
# ext4): it supports fs-verity, and the sealed install on f2fs is verified end-to-end
# (see docs/design.md). f2fs is a loadable module, so it is forced into the initramfs via
# the dracut add_drivers below.
RUN install -d /usr/lib/bootc/install \
    && printf '[install.filesystem.root]\ntype = "f2fs"\n' \
        > /usr/lib/bootc/install/00-cachyos.toml

# Kernel command line defaults, baked into the UKI by `bootc container ukify`. `rw` makes
# /sysroot writable so /etc and /var bind mounts work without a workaround. Serial console
# is included so the VM test harness can capture early boot.
RUN install -d /usr/lib/bootc/kargs.d \
    && printf 'kargs = ["console=tty0", "console=ttyS0", "rw"]\n' \
        > /usr/lib/bootc/kargs.d/00-console.toml

# Enable the services a bootable system needs and avoid first-boot interactive prompts.
# systemd-boot-update copies the current systemd-bootx64.efi onto the ESP on each boot,
# keeping the boot *loader* in sync with the image across updates (bootc only manages the
# UKI, not the loader binary). Enabling it mirrors the Fedora reference Containerfile.uki.
# cachyos-rate-mirrors.timer periodically re-ranks mirrors so the installed system keeps a
# fast, working mirrorlist without manual intervention (see cachyos-rate-mirrors.service).
RUN systemctl enable systemd-networkd systemd-resolved systemd-timesyncd sshd \
        systemd-boot-update.service \
        cachyos-rate-mirrors.timer \
    && systemctl mask systemd-firstboot.service

# Machine identity: generated on first boot; UTC timezone so nothing prompts.
RUN echo "uninitialized" > /etc/machine-id \
    && ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# SSH: allow root login via key only. The test harness injects an ephemeral public key at
# install time (see installer/stage/install-bootc.sh), so no password is needed and password
# auth is disabled.
#
# Host keys are NOT baked into the image: every install of a shared image would otherwise
# share the same host keys (MITM-able). We remove any pre-generated keys and rely on
# sshdgenkeys.service (Arch's host-key generator) to create machine-unique keys on first
# boot. sshd refuses to start until its host keys exist, so this also acts as a
# first-boot gate.
RUN install -d /etc/ssh/sshd_config.d \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' \
        > /etc/ssh/sshd_config.d/10-bootc.conf \
    && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub \
    && systemctl enable sshdgenkeys.service

# Bring up wired ethernet via DHCP. systemd-networkd ignores interfaces without a
# .network file; match by Type=ether to catch eth0/ens3/etc. (QEMU virtio NIC included).
RUN printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' \
        > /usr/lib/systemd/network/20-wired.network

# resolv.conf points at systemd-resolved's stub, created via tmpfiles at boot
# (resolv.conf is bind-mounted by the container runtime during build).
RUN printf 'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' \
        > /usr/lib/tmpfiles.d/resolv-conf.conf

# Bind /etc and /var onto the writable /sysroot. This is the composefs-native layout
# recommended by bootc and shown in Containerfile.uki; it keeps /etc and /var writable
# under an otherwise read-only composefs root.
RUN install -d /usr/lib/composefs \
    && printf '[etc]\nmount = "bind"\n\n[var]\nmount = "bind"\n' \
        > /usr/lib/composefs/setup-root-conf.toml

# Generate the initramfs with the ostree + bootc dracut modules. hostonly=no keeps the
# image generic. dracut must be told the kernel version explicitly (its default targets
# the running kernel, which is not the image's kernel).
#
# There must be exactly one kernel: bootc's split-kernel-and-rootfs/ukify assume a single
# kernel, and `head -n1` would otherwise silently pick an arbitrary one and produce a UKI
# that does not match the modules that were loaded. Fail loudly instead.
RUN printf 'hostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "\nadd_drivers+=" f2fs "\n' \
        > /usr/lib/dracut/dracut.conf.d/10-bootc.conf \
    && test "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 \
    && kver="$(ls /usr/lib/modules)" \
    && dracut --force "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

# Base image root filesystem layout required by bootc (ostree symlink, /var as the
# writable tree, tmpfiles for /var subdirectories, composefs prepare-root config).
# Adapted from bootcrew/mono shared/bootc-rootfs.sh (Apache-2.0). See contrib/ATTRIBUTION.md.
RUN rm -rf /boot /home /root /usr/local /srv /opt /mnt \
    && mkdir -p /sysroot /boot /usr/lib/ostree /var \
    && ln -sT sysroot/ostree /ostree \
    && ln -sT var/roothome /root \
    && ln -sT var/srv /srv \
    && ln -sT var/opt /opt \
    && ln -sT var/mnt /mnt \
    && ln -sT var/home /home \
    && ln -sT ../var/usrlocal /usr/local \
    && printf 'd /var/opt 0755 root root -\nd /var/home 0755 root root -\nd /var/srv 0755 root root -\nd /var/mnt 0755 root root -\nd /var/usrlocal 0755 root root -\nd /var/roothome 0700 root root -\nd /run/media 0755 root root -\n' \
        > /usr/lib/tmpfiles.d/bootc-base-dirs.conf \
    && printf '[composefs]\nenabled = yes\n' \
        > /usr/lib/ostree/prepare-root.conf

# Normalize /var and /tmp as bootc expects:
#   - every directory in /var should have a matching systemd tmpfiles.d entry, so it is
#     recreated on each boot instead of only being provisioned from the image;
#   - /var must not contain generated files (build artifacts on a bootc system);
#   - the relocated pacman cache and log are build artifacts and are removed;
#   - /run and /tmp must be empty (they are tmpfs at runtime).
# See bootc lint `var-tmpfiles`, `var-log` and `nonempty-run-tmp`.
RUN printf '%s\n' \
        'd /var/cache 0755 root root -' \
        'd /var/cache/ldconfig 0700 root root -' \
        'd /var/cache/pacman 0755 root root -' \
        'd /var/cache/pacman/pkg 0755 root root -' \
        'd /var/db 0755 root root -' \
        'd /var/db/sudo 0711 root root -' \
        'd /var/db/sudo/lectured 0700 root root -' \
        'd /var/empty 0755 root root -' \
        'd /var/games 0775 root games -' \
        'd /var/lib 0755 root root -' \
        'd /var/lib/containers 0755 root root -' \
        'd /var/lib/containers/sigstore 0755 root root -' \
        'd /var/lib/krb5kdc 0755 root root -' \
        'd /var/lib/misc 0755 root root -' \
        'd /var/lib/systemd/catalog 0755 root root -' \
        'd /var/lib/tpm2-tss 0755 root root -' \
        'd /var/lib/tpm2-tss/system 0755 root root -' \
        'd /var/lib/xfsprogs 0755 root root -' \
        'd /var/local 0755 root root -' \
        'd /var/log 0755 root root -' \
        'd /var/log/old 0755 root root -' \
        'd /var/spool 0755 root root -' \
        'd /var/spool/mail 0755 root root -' \
        'd /var/tmp 1777 root root -' \
        'L /var/lock - - - - ../run/lock' \
        'L /var/mail - - - - spool/mail' \
        > /usr/lib/tmpfiles.d/bootc-cachyos-var.conf \
    && pacman -Scc --noconfirm >/dev/null \
    && rm -rf /usr/lib/sysimage/log/* \
    && rm -rf /usr/lib/sysimage/cache/pacman/pkg/* \
    && rm -f /var/cache/ldconfig/aux-cache \
             /var/db/Makefile \
             /var/lib/krb5kdc/kdc.conf \
             /var/lib/systemd/catalog/database \
    && find /run -mindepth 1 -maxdepth 1 \
         ! -name secrets ! -name '.containerenv' -exec rm -rf {} + \
    && find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + \
    && install -d -m 0755 /var/cache /var/log

# Version marker. `IMAGE_VERSION` lets us build distinguishable vN images from this same
# Containerfile for update/rollback testing (Task 20/21). The marker lives in /usr (part of
# the immutable composefs image), so a v1->v2 update changes the composefs digest and the
# deployment visibly. Defaults to "1" so a plain `podman build` is a valid v1.
ARG IMAGE_VERSION=1
RUN printf '%s\n' "${IMAGE_VERSION}" > /usr/lib/bootc-image-version \
    && ln -sfn /usr/lib/bootc-image-version /etc/bootc-image-version

# Validate the rootfs against bootc's own invariants before sealing it. lint only makes
# sense here, on the state that carries a kernel; the split/sealed stages remove it.
#
# --fatal-warnings turns every warning into a build error, so regressions in the /var
# layout (var-tmpfiles/var-log) or other lints cannot silently pass again. The one warning
# we deliberately allow is runtime-deps (missing `chcon`): Arch/CachyOS has no SELinux and
# `chcon` is only provided by the conflicting coreutils-uutils, so it is intentionally absent.
RUN bootc container lint --fatal-warnings --skip runtime-deps

# ---------------------------------------------------------------------------

# Split the kernel/initramfs out of the rootfs. The UKI embeds them, so the sealed image
# must not also carry a raw vmlinuz/initramfs.img (bootc reads the UKI from
# /boot/EFI/Linux and treats it as the single kernel).
FROM rootfs AS split
RUN install -d /kernel \
    && bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# Build the UKI. `bootc container ukify` computes the composefs digest of the rootfs and
# bakes it (plus kargs.d) into the UKI cmdline. fs-verity enforcement is left on: we do
# NOT pass --allow-missing-verity. No --signtool/--secureboot-* is passed: the UKI stays
# unsigned and Secure Boot is not used.
FROM docker.io/cachyos/cachyos-v3:latest AS sealed-uki

ARG CACHYOS_MIRROR

# ukify is required. bootc is copied from the builder so the same pinned version is used;
# the bootc binary links libselinux at runtime, so it must be installed here as well.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && if [[ -n "${CACHYOS_MIRROR}" ]]; then \
         : > /etc/pacman.d/cachyos-mirrorlist; \
         for m in ${CACHYOS_MIRROR}; do printf 'Server = %s\n' "$m" >> /etc/pacman.d/cachyos-mirrorlist; done; \
       fi \
    && pacman -Sy --noconfirm --needed systemd-ukify ostree libselinux \
    && pacman -Scc --noconfirm
COPY --from=bootc-builder /output/usr/bin/bootc /usr/bin/bootc

RUN --mount=type=bind,from=split,target=/target \
    --mount=type=bind,from=split,source=/kernel,target=/kernel \
    <<'EORUN'
set -euo pipefail
kver="$(ls /kernel)"
install -d /out
bootc container ukify \
    --rootfs /target \
    --kernel-dir "/kernel/${kver}" \
    -- --output "/out/${kver}.efi"
EORUN

# ---------------------------------------------------------------------------

# The final sealed image: the split rootfs plus the UKI on the boot tree.
FROM split AS final
COPY --from=sealed-uki /out/*.efi /boot/EFI/Linux/
LABEL containers.bootc=1
ARG IMAGE_VERSION=1
LABEL org.cachyos.bootc.image-version="${IMAGE_VERSION}"

# Re-validate the final (split) image: the kernel was removed and the UKI added by the
# split/ukify steps, so this guards against those steps introducing drift. Same
# --fatal-warnings --skip runtime-deps rationale as the rootfs-stage lint above.
RUN bootc container lint --fatal-warnings --skip runtime-deps
