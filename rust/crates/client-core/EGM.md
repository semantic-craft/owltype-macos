# msime-client-core build and package

## Overview
A lightweight shared Rust client crate. Its build script prepares pinned OpenCC text inputs for compile-time inclusion.

## Interface
- `Cargo.toml:package.name` exports `msime-client-core`; [source contract](./src/EGM.md) describes its public Rust modules.
- `build.rs:main` honors `MSIME_PYTHON` or tries `python3` then `python`, invokes the workspace OpenCC fetch helper, and sets compile-time `MSIME_OPENCC_DIR`.

## Invariants
- `build.rs:main` requires a successful helper invocation and UTF-8 directory output; missing interpreters are tried in order, and exhausted/failed preparation panics instead of silently using unverified data.
- `build.rs:main` emits Cargo rerun dependencies for the input lock, fetch/retry scripts, license, prepared directory, and relevant environment variables.

## Side Effects
- `build.rs:main` launches Python, reads environment, and emits Cargo directives. The helper can read/write the cache and download pinned inputs unless offline; see the workspace scripts contract at `/rust/scripts/EGM.md`.

## Verification
- From `rust/`: `cargo test -p msime-client-core`; `MSIME_OPENCC_OFFLINE=1 cargo test -p msime-client-core` requires previously prepared valid inputs.
