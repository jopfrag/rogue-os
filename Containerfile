ARG BOOTC_VERSION=v1.16.13
ARG BOOTC_COMMIT=fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60
ARG CACHYOS_MIRROR=""
ARG KERNEL_PKGS="linux-cachyos"
ARG FIRMWARE_PKGS="linux-firmware-amdgpu linux-firmware-intel amd-ucode"

FROM docker.io/cachyos/cachyos-v3:latest AS bootc-builder

ARG BOOTC_VERSION
ARG BOOTC_COMMIT
ARG CACHYOS_MIRROR

RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && if [[ -n "${CACHYOS_MIRROR}" ]]; then \
         : > /etc/pacman.d/cachyos-mirrorlist; \
         for m in ${CACHYOS_MIRROR}; do printf 'Server = %s\n' "$m" >> /etc/pacman.d/cachyos-mirrorlist; done; \
       fi

RUN pacman -Sy --noconfirm --needed \
        base base-devel rust make git go-md2man pkgconf ostree glibc \
        cmake jq libselinux clang llvm patch \
    && pacman -S --clean --noconfirm

ENV CARGO_PROFILE_RELEASE_DEBUG=false \
    CARGO_PROFILE_RELEASE_STRIP=true \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_OPT_LEVEL=s \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_PANIC=abort

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

RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && if [[ -n "${CACHYOS_MIRROR}" ]]; then \
         : > /etc/pacman.d/cachyos-mirrorlist; \
         for m in ${CACHYOS_MIRROR}; do printf 'Server = %s\n' "$m" >> /etc/pacman.d/cachyos-mirrorlist; done; \
       fi

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

COPY --from=bootc-builder /output /

RUN install -d /usr/lib/bootc/install \
    && printf '[install.filesystem.root]\ntype = "f2fs"\n' \
        > /usr/lib/bootc/install/00-cachyos.toml

RUN install -d /usr/lib/bootc/kargs.d \
    && printf 'kargs = ["console=tty0", "console=ttyS0", "rw"]\n' \
        > /usr/lib/bootc/kargs.d/00-console.toml

RUN systemctl enable systemd-networkd systemd-resolved systemd-timesyncd sshd \
        systemd-boot-update.service \
        cachyos-rate-mirrors.timer \
    && systemctl mask systemd-firstboot.service

RUN echo "uninitialized" > /etc/machine-id \
    && ln -sf /usr/share/zoneinfo/UTC /etc/localtime

RUN install -d /etc/ssh/sshd_config.d \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' \
        > /etc/ssh/sshd_config.d/10-bootc.conf \
    && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub \
    && systemctl enable sshdgenkeys.service

RUN printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' \
        > /usr/lib/systemd/network/20-wired.network

RUN printf 'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' \
        > /usr/lib/tmpfiles.d/resolv-conf.conf

RUN install -d /usr/lib/composefs \
    && printf '[etc]\nmount = "bind"\n\n[var]\nmount = "bind"\n' \
        > /usr/lib/composefs/setup-root-conf.toml

RUN printf 'hostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "\nadd_drivers+=" f2fs "\n' \
        > /usr/lib/dracut/dracut.conf.d/10-bootc.conf \
    && test "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 \
    && kver="$(ls /usr/lib/modules)" \
    && dracut --force "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

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

ARG IMAGE_VERSION=1
RUN printf '%s\n' "${IMAGE_VERSION}" > /usr/lib/bootc-image-version \
    && ln -sfn /usr/lib/bootc-image-version /etc/bootc-image-version

RUN bootc container lint --fatal-warnings --skip runtime-deps

# ---------------------------------------------------------------------------

FROM rootfs AS split
RUN install -d /kernel \
    && bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# ---------------------------------------------------------------------------

FROM docker.io/cachyos/cachyos-v3:latest AS sealed-uki

ARG CACHYOS_MIRROR

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

FROM split AS final
COPY --from=sealed-uki /out/*.efi /boot/EFI/Linux/
LABEL containers.bootc=1
ARG IMAGE_VERSION=1
LABEL org.cachyos.bootc.image-version="${IMAGE_VERSION}"

RUN bootc container lint --fatal-warnings --skip runtime-deps
