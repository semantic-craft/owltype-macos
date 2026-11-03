# MSIME host FFI

## Overview

Native host adapter for the pinned MSIME engine and input runtime. This crate builds a static library and Rust library; it translates host JSON actions into runtime transitions and exposes owned JSON strings through C ABI functions.

## Interface

- [include contract](./include/EGM.md) describes the C declarations and caller ownership boundary.
- [implementation contract](./src/EGM.md) covers session state, configuration, reranking and user migration.
- [Cargo.toml](./Cargo.toml) declares the `owl-msime-ffi` library and dependencies on engine, input runtime, client core and path trust.

## Invariants

- Session handles are opaque, non-reused tokens owned by the creating thread; callers must not dereference them. Configuration handles have separate allocation and destruction rules.
- Returned owned strings must be released using the matching ABI free function. Panic conversion does not make arbitrary caller pointers valid.
- Mutable user/cache roots and immutable generation resources have distinct roles; the implementation validates supported root layouts before preparation.

## Side Effects

Session creation prepares dictionary and user state; actions may persist learning or rebuild the runtime. Model loading and settled reranking use workers. Migration validates and imports staged data with rollback snapshots. These facilities do not implement network transport.

## Verification

From `rust/`: `cargo test -p owl-msime-ffi`. Tests were not executed as part of this documentation bootstrap.
