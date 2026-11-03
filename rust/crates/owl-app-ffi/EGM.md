# owl-app-ffi

## Overview
Static-library and Rust-library boundary for native access to shared application policy and storage/session orchestration.

## Subdirectories & Boundaries
- [C declarations](./include/EGM.md): borrowed bytes, owned results and session handles.
- [Implementation](./src/EGM.md): JSON dispatch, direct decisions, callbacks, and session lifecycle.

## Interface
- `Cargo.toml:lib.crate-type` builds `staticlib` and `rlib`; `Cargo.toml:dependencies.owl-app-core` supplies application behavior.

## Invariants
- `src/lib.rs:ABI` is 1. Callers must follow raw-pointer lifetimes and free each Rust-owned result/handle exactly once.

## Side Effects
- `src/lib.rs:owl_app_storage_call` invokes host callbacks; sessions retain memory across calls.

## Verification
- From `rust/`: `cargo test -p owl-app-ffi`.
