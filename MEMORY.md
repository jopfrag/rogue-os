# Memory

Project context retained after the task tracker (`TASKS.md`) was closed out. The authoritative
documentation lives in `docs/` and `README.md`; **this file deliberately does not restate it.**
It indexes where things live and records only the few facts that are not already captured
elsewhere in the repository.

## Where to look

| Topic | Location |
|---|---|
| Architecture, decisions, install flow | `docs/design.md` |
| Verified environment facts (uid 107, idmap, CPU model, console, registry path) | `docs/development.md` |
| Usage, status, commands, repo layout | `README.md` |
| Image build (5 stages), installer packaging | `Containerfile`, `installer/`, `docs/design.md` |
| Third-party attribution / licenses | `contrib/ATTRIBUTION.md` |

## Facts not documented elsewhere

- **Versioned image mechanism.** `Containerfile` takes `ARG IMAGE_VERSION` (default `1`);
  it is baked both as `/usr/lib/bootc-image-version` (in the sealed `/usr`, so part of the
  composefs image) and as the OCI label `org.cachyos.bootc.image-version`. Distinct versions
  therefore get distinct composefs digests. `make image-v1` / `make image-v2`.

- **Why the installer pulls with `fuse-overlayfs`.** The live installer root is overlayfs, so
  containers-storage must use the overlay driver with `fuse-overlayfs`. A `vfs` storage driver
  was tried first but expands the ~3.4 GiB image to ~5 GiB, exhausting the live writable space.

- **bootc source-build dependency detail.** Building `bootc` from source additionally needs
  `clang`/`libclang` (for `selinux-sys`/`bindgen`) as *build* deps, and `libselinux` at
  *runtime* (the copied binary links it), not merely its headers. The `chcon` lint warning is
  expected: Arch/CachyOS has no SELinux and `chcon` only comes from the conflicting
  `coreutils-uutils`, so it is intentionally absent and `runtime-deps` is skipped in
  `bootc container lint --fatal-warnings --skip runtime-deps`.
