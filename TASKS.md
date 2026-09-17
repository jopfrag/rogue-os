# Tasks

Source of truth for project progress. One task may be In Progress at a time.

Scope: refactor the repository into three independent targets (CI image build, Arch
installer ISO, disposable-VM installation test) that share only `Containerfile`.
See `PROMPT.md` for the objective and `AGENTS.md` for how to work.

## Completed

- [x] Task 0.1 — Create `PROMPT.md` and `TASKS.md`.
      Evidence: `PROMPT.md` describes the three targets, the verified environment facts
      (`mkarchiso` present, mount shims required, `cow_spacesize` is the writable layer,
      releng already enables root SSH) and the current decisions. `TASKS.md` (this file)
      lists the phases. No source/build/test files changed yet.

- [x] Task 0.2 — Confirm decisions and record them.
      Evidence: decisions recorded in TASKS.md Notes section. Confirmed: base ISO = Arch
      releng + mkarchiso; root password = `root`; SSH root password auth on installer ISO
      only; cow_spacesize=16G (tmpfs-backed, cow_device deferred); CI push target =
      ghcr.io/jopfrag/cachyos-bootc; Target 3 = migrate only.

- [x] Task 1.1 — Add `.github/workflows/build-image.yaml`.
      Evidence: workflow file created at `.github/workflows/build-image.yaml`. Builds
      `Containerfile` with podman. PRs build only, main pushes build and push to
      `ghcr.io/jopfrag/cachyos-bootc`. Documents x86-64-v3 runner requirement.

## In Progress

- [ ] Task 1.2 — Verify the workflow.
      Evidence: a workflow run builds the image successfully; a main push publishes it.

## Remaining

### Phase 1 — Target 1: CI builds `Containerfile`

- [ ] Task 1.1 — Add `.github/workflows/build-image.yaml`.
      Build `Containerfile` with podman. Pull requests: build only. Push to main: build and
      push to the configured registry. Own inline build step so only `Containerfile` is
      shared. Document the x86-64-v3 runner requirement and the build time.
- [ ] Task 1.2 — Verify the workflow.
      Evidence: a workflow run builds the image successfully; a main push publishes it.

### Phase 2 — Target 2: Arch installer ISO

- [ ] Task 2.1 — Create `iso/archiso/` releng-based profile.
      `profiledef.sh`, `packages.x86_64` (add `podman`, `skopeo`, `git`, `gptfdisk`,
      `f2fs-tools`, and whatever pulling/building the image needs), `pacman.conf`, boot
      entries.
- [ ] Task 2.2 — `airootfs` customizations.
      Set root password `root` in `etc/shadow`; ship the sshd override
      (`PermitRootLogin yes`, `PasswordAuthentication yes`, `AllowUsers root`); identify the
      live environment (hostname/motd).
- [ ] Task 2.3 — Writable space for the live system.
      Set `cow_spacesize` (and decide `copytoram` / `cow_device`) in the systemd-boot, grub
      and syslinux boot entries.
- [ ] Task 2.4 — Vendor mount/umount shims and write `iso/build.sh`.
      Shims under `iso/shims/`; `iso/build.sh` prepends them to `PATH` and runs `mkarchiso`
      into `iso/out/`. Fails clearly if tooling is missing.
- [ ] Task 2.5 — `make iso` wrapper.
      Thin dispatcher; documented in `make help`.
- [ ] Task 2.6 — Verify the ISO.
      Evidence: build succeeds; boot the ISO in a VM; SSH in as `root` with password `root`;
      confirm the writable space matches `cow_spacesize`.

### Phase 3 — Target 3: migrate the VM test (no redesign)

- [ ] Task 3.1 — Move `tests/vm/*` and `hack/lib/*` into `vm-test/` and parameterize.
      Introduce a `config.env` for registry host/port/container name and the ISO path.
      Behaviour otherwise unchanged.
- [ ] Task 3.2 — `make vm-test` wrapper.
      Accept an image reference and ISO path; build neither. Documented in `make help`.
- [ ] Task 3.3 — Verify the workflow end-to-end.
      Evidence: `make build`, push, and `make vm-test` pass install, boot, smoke, update and
      rollback, and clean up the VM.

### Phase 4 — Cleanup

- [ ] Task 4.1 — Slim the `Makefile` to thin dispatchers over the three targets.
- [ ] Task 4.2 — Update `README.md` and reconcile `hack/`, `installer/` and
      `docs/to_be_deleted/` with the new layout.

## Blocked

## Notes

- Verified: `mkarchiso` (archiso 90-1) is installed in this container.
- Verified: this container cannot create fresh `devtmpfs`/`proc`/`sysfs`; `mkarchiso` needs
  the mount/umount shim (working copy at `/home/jopfrag/shim/bin/` from a previous session).
  Vendor it into `iso/shims/`.
- Verified: the stock Arch releng `airootfs` already enables `sshd` and sets
  `PermitRootLogin yes` / `PasswordAuthentication yes`. The required change is the root
  **password** (`root`), because stock Arch leaves it empty and sshd rejects empty passwords.
- Verified: a previous session already built a Target 2 ISO successfully (output and
  `mkarchiso` logs remain in `/var/tmp/`). The profile was removed from the tree; recreate it.
- Verified: the Arch live writable layer is the `cow_spacesize` boot parameter (tmpfs,
  default 256M). A disk-backed `cow_device` is the RAM-independent alternative.
- The sealed-image architecture is fixed and out of scope for change: composefs backend,
  systemd-boot, unsigned UKI, fs-verity enforced, f2fs root, Secure Boot disabled,
  `bootupd` absent. `Containerfile.uki` must not be modified.

### Confirmed decisions (Task 0.2)

1. **Base ISO**: official Arch Linux **releng** profile, built with `mkarchiso`.
2. **Root password**: literal `root`.
3. **SSH**: root login over SSH with password authentication enabled (`AllowUsers root`).
   Key auth may remain enabled. This applies only to the throwaway installer ISO, never to
   the final bootc image (which stays key-only with password auth disabled).
4. **Writable space**: `cow_spacesize=16G` on the boot entries (tmpfs-backed, 16G). This
   provides sufficient space for pulling/building container images during installation.
   Disk-backed `cow_device` is deferred — it's better for real hardware but adds complexity
   that isn't needed for the initial implementation.
5. **Mount shims**: vendor `mount`/`umount` into `iso/shims/`; `iso/build.sh` prepends them
   to `PATH` when invoking `mkarchiso`. Working shims at `/home/jopfrag/shim/bin/`.
6. **CI push target**: GHCR (`ghcr.io/jopfrag/cachyos-bootc`), built with the runner's
   podman. Owner derived from git config (`jopfrag`).
7. **Target 3**: migrate and parameterize only; do not redesign.
