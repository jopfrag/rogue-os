# Refactor: Two Independent Targets

Read `AGENTS.md` before doing anything else. It defines how you must work.

Your job is to refactor this repository so that it exposes **two independent targets**.
The only thing they may share is `Containerfile` (the bootc image definition, plus its
documentation `Containerfile.md` and its patch `bootc-f2fs.patch`).

You must **not** change the image architecture. The image stays a sealed CachyOS bootc
image: composefs backend, systemd-boot, unsigned UKI, fs-verity enforced, f2fs root,
Secure Boot disabled, and `bootupd` absent. This refactor is layout and entrypoint work
only.

## The two targets

### Target 1 — CI builds `Containerfile`

A GitHub Actions workflow that builds the OCI image from `Containerfile`.

- Lives in `.github/workflows/`.
- Does not depend on the VM test.
- Pull requests: build only.
- Push to the main branch: build and push the image.
- Builds `Containerfile` directly (its own build step), so that only `Containerfile` is
  shared with the other target.

### Target 2 — Make target tests the installation in a VM

The existing disposable libvirt/QEMU/KVM workflow: build/push the image, boot an installer,
install the bootc image, boot the installed system, and run the automated tests (install,
boot, smoke, update, rollback), cleaning up afterwards.

This target **consumes** an image reference and an installer ISO path. It does not build
either. It is being **migrated behind a clean entrypoint, not redesigned**, in this refactor:
move it, parameterize the hardcoded values, keep its behaviour otherwise identical.

## Structure

```
.github/workflows/     Target 1 (CI image build)
vm-test/               Target 2 (disposable VM test workflow)
Containerfile          shared by both targets
Makefile               thin dispatchers for the local targets
```

Each target owns its own scripts and configuration. Do not have one target source another
target's scripts or Makefile.

## Verified environment facts (do not re-derive)

These were established empirically. They constrain the implementation.

- libvirt is the **host's** `qemu:///system`; VM disks live under host `/var/tmp`
  (container path `/run/host/var/tmp`) owned by uid 107; test domains need
  `<cpu mode='host-passthrough'/>`.
- The local OCI registry serves plain HTTP on the libvirt bridge (`192.168.122.1:5000`).

## Decisions

These are the current decisions. Confirm or correct them before implementing a task that
depends on them, and record changes in `TASKS.md`.

1. **CI push target**: GHCR (`ghcr.io/<owner>/cachyos-bootc`), built with the runner's podman.
2. **Target 2**: migrate and parameterize only; do not redesign.

## Constraints

- One task at a time. `TASKS.md` is the source of truth.
- Do not change the sealed-image architecture (composefs + UKI + systemd-boot, f2fs,
  fs-verity enforced, no `bootupd`, no Secure Boot).
- `Containerfile.uki` is a read-only reference. Never modify it.
- Scripts use `set -euo pipefail`, quote variables, clean up with traps, and never hide
  failures (`|| true` only deliberately and documented).
- Tests and builds must be disposable and must only touch resources they created.
- Do not document functionality that does not exist.
- Verify every step before marking a task complete. "Probably works" is not done.

## Definition of done

- `.github/workflows/` builds `Containerfile`; PRs build only, main pushes.
- `make vm-test` installs and tests the image in a disposable VM, taking the image reference
  and ISO path as inputs, without building either.
- `make build` still builds the image.
- The two targets share nothing except `Containerfile`.
- README and `TASKS.md` match the resulting layout, and the intended sealed architecture is
  preserved.

## First actions

1. Read `AGENTS.md`, then `PROMPT.md`, then `TASKS.md`.
2. Confirm the decisions above (especially CI push target).
3. Implement one task at a time, verifying each before moving on.
