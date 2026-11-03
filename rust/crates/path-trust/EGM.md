# msime-path-trust

## Overview
Workspace crate supplying shared storage-path trust checks.

## Subdirectories & Boundaries
- [Source contract](./src/EGM.md): platform symlink exceptions and read-only hard-link trust.

## Interface
- `Cargo.toml:package.name` exports crate `msime-path-trust`; `Cargo.toml:features.test-support` enables Unix fixture helpers.

## Invariants
- Storage consumers share the policy in `src/lib.rs:reject_symlinked_components` rather than adding independent alias lists.

## Side Effects
- `src/lib.rs:multi_link_is_trusted` opens and inspects filesystem handles; feature-gated test helpers may mutate fixture permissions.

## Verification
- From `rust/`: `cargo test -p msime-path-trust`.
