# Tasks

Source of truth for project progress. One task may be In Progress at a time.

Scope: refactor the repository into two independent targets (CI image build,
disposable-VM installation test) that share only `Containerfile`.
See `PROMPT.md` for the objective and `AGENTS.md` for how to work.

## Completed

- [x] Task 0.1 — Create `PROMPT.md` and `TASKS.md`.
      Evidence: `PROMPT.md` describes the two targets and the verified environment facts.
      `TASKS.md` (this file) lists the phases. No source/build/test files changed yet.

- [x] Task 0.2 — Confirm decisions and record them.
      Evidence: decisions recorded in TASKS.md Notes section. Confirmed: CI push target =
      ghcr.io/jopfrag/cachyos-bootc; Target 2 = migrate only.

- [x] Task 1.1 — Add `.github/workflows/build-image.yaml`.
      Evidence: workflow file created at `.github/workflows/build-image.yaml`. Builds
      `Containerfile` with podman. PRs build only, main pushes build and push to
      `ghcr.io/jopfrag/cachyos-bootc`. Documents x86-64-v3 runner requirement.

## In Progress

- [ ] Task 1.2 — Verify the workflow.
      Evidence: a workflow run builds the image successfully; a main push publishes it.
      Run 35214464035 in progress (Containerfile heredoc fix pushed).

### Phase 2 — Target 2: migrate the VM test (no redesign)

- [x] Task 2.1 — Move `tests/vm/*` and `hack/lib/*` into `vm-test/` and parameterize.
      Evidence: `vm-test/` created with `config.env`, `lib/vm.sh`, `lib/ssh.sh`,
      `run.sh`, `install.sh`, `boot.sh`, `smoke.sh`, `upgrade.sh`, `rollback.sh`.
      All scripts source `config.env` for defaults, use `vmtest_dir` relative paths.
      Behaviour unchanged from originals.
- [x] Task 2.2 — `make vm-test` wrapper.
      Evidence: `make vm-test` documented in `make help`, delegates to `vm-test/run.sh`
      with `--image` and `--iso` flags. Does not build either.

## Remaining

- [x] Task 2.3 — Verify the workflow end-to-end.
      Evidence: `make build` succeeded, `make registry-push` pushed to local registry,
      `make vm-test` passed install, boot, 16/16 smoke tests, and cleaned up the VM.
      Run: `t1789645365-1672311`.

### Phase 3 — Cleanup

- [x] Task 3.1 — Slim the `Makefile` to thin dispatchers over the two targets.
      Evidence: `make test` removed, replaced by `make vm-test`. All VM targets
      delegate to `vm-test/` scripts. `make build` and `make image-test` unchanged.
- [x] Task 3.2 — Update `README.md` and reconcile `hack/`, `installer/` and
      `docs/to_be_deleted/` with the new layout.
      Evidence: README documents two-target layout and vm-test/ structure.
      `tests/vm/` removed (migrated to vm-test/). `docs/to_be_deleted/` removed.
      `tests/image/` retained (used by `make image-test`). `hack/lib/` retained
      (used by `hack/vm-shell.sh`).

## Blocked

## Notes

- The sealed-image architecture is fixed and out of scope for change: composefs backend,
  systemd-boot, unsigned UKI, fs-verity enforced, f2fs root, Secure Boot disabled,
  `bootupd` absent. `Containerfile.uki` must not be modified.

### Confirmed decisions (Task 0.2)

1. **CI push target**: GHCR (`ghcr.io/jopfrag/cachyos-bootc`), built with the runner's
   podman. Owner derived from git config (`jopfrag`).
2. **Target 2**: migrate and parameterize only; do not redesign.

### Notes from implementation

- The GitHub Actions ubuntu-latest runner ships podman < 5.0 which does not support
  heredoc syntax (`RUN <<'EOF'`) in Containerfiles. Fixed by replacing the heredoc
  in the `sealed-uki` stage with `sh -c`. Verified locally, pushed, CI re-triggered.
