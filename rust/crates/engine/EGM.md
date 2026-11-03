# Input engine crate

## Overview

`msime-engine` owns composition algorithms, input schemes, dictionary access, ranking and personal learning. It replaces the former C++ engine; host orchestration calls its core session API or flattened host facade.

## Interface

- `[Cargo.toml]` defines the `msime-engine` library with workspace Rust/version/lint policy. The public Rust surface is reexported from `src/lib.rs`.
- [Source contract](./src/EGM.md) maps scheme, session, dictionary, model and persistence responsibilities.
- [Examples](./examples/EGM.md) documents diagnostic/evaluation programs and their resource and temporary-state requirements.

## Invariants

- `[Cargo.toml]` uses bundled SQLite and adds `ffi-sqlite-wasm-rs` only for the browser target. Windows adds link-count inspection for sidecar writes.
- The Vietnamese transform dependency is pinned to `vi =0.8.0`; its adapter's uppercase behavior depends on that version. Rink uses embedded unit definitions with default features disabled; the local expression path does not load live currency data.
- Algorithm and data-format contracts belong to `src`; host/network execution and platform input delivery remain caller responsibilities. Integration tests under `tests/` are verification-only and are not separate production components.

## Side Effects

- Library calls can open local resources, create runtime dictionary generations and persist learned data as documented below `src`. Example programs may create temporary work directories and perform measurements; merely building the library does not exercise a host input session.

## Verification

From `rust/`: `cargo test -p msime-engine`. This bootstrap changed documentation only; no builds, tests, example programs or live input were executed.
