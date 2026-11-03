# Storage path trust

## Overview
Centralizes the platform exceptions allowed during storage-path traversal and the checks for read-only hard-linked files.

## Interface
- `lib.rs:trusted_system_alias_target`, `is_trusted_system_alias`, and `is_root_only_link` classify permitted system symlinks.
- `lib.rs:reject_symlinked_components` validates an existing or prospective storage path.
- `lib.rs:multi_link_is_trusted`, `multi_link_in_directory_is_trusted`, and `multi_link_path_is_trusted` provide handle-based and path-based read-only hard-link checks.
- The Unix `test-support` feature exposes `untrusted_symlink`, `open_to_other_users`, and `close_to_other_users` for rejection/permission fixtures.

## Invariants
- `lib.rs:reject_symlinked_components` rejects final-component symlinks and permits at most one trusted ancestor alias, only on an absolute path. Missing components are accepted; other I/O errors propagate.
- `lib.rs:SYSTEM_ALIASES` fixes macOS/iOS aliases to `/tmp` and `/var` with exact `/private` destinations, and Android's primary-user alias to `/data/data`. Linux instead checks root ownership and non-group/non-other-writable parent permissions in `is_root_only_link`.
- `lib.rs:multi_link_is_trusted` requires a root/current-user-owned directory without group/other write permissions and verifies the named regular file's device/inode against the open handle. These checks do not authorize writes to hard-linked files.

## Side Effects
- `lib.rs:reject_symlinked_components` and trust functions read filesystem metadata; hard-link checks open directory handles and use `fstatat` without following the final symlink.
- Feature-gated fixture helpers create symlinks and change ownership or permissions; normal validation APIs do not mutate files.

## Verification
- From `rust/`: `cargo test -p msime-path-trust`.
