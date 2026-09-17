# Tasks

Task tracker for the CachyOS sealed bootc image. One task may be In Progress at a time.

## Completed

- [x] Task 29 — Add f2fs as the sealed composefs root filesystem.
      Result: **works, and f2fs is now the default.** Requires two small local changes
      (documented in `docs/design.md`): a `bootc-f2fs.patch` (add an `F2fs` variant to
      bootc's `Filesystem` enum + `supports_fsverity()`) and a dracut
      `add_drivers+=" f2fs "` so the loadable `f2fs.ko` lands in the UKI initramfs.
      Verified end-to-end: install, boot sealed (16/16 smoke), `bootc switch` update,
      and `bootc rollback` all pass with `/sysroot` on f2fs and fs-verity enforced.

## In Progress

## Remaining

## Blocked

## Notes

- Upstream `bootc` (pinned 1.16.13 and current `main`) hardcodes
  `Filesystem { Xfs, Ext4, Btrfs }` and `supports_fsverity() == ext4|btrfs`; f2fs is not
  known upstream. The local patch is minimal and reviewable (`bootc-f2fs.patch`).
- The kernel `f2fs.ko` already supports fs-verity (`f2fs_verityops`, etc.); ext4 is built-in
  (`=y`) while f2fs is a module, which is why the dracut driver line is required.
