# msime-input-runtime

## Overview
Shared Rust orchestration between input hosts, the engine, candidate presentation and asynchronous provider results.

## Subdirectories & Boundaries
- [Source contract](./src/EGM.md): engine trait, owned runtime, DTOs, provider adapters and desktop plugin transforms.

## Interface
- `Cargo.toml:package.name` exports `msime-input-runtime`; local dependencies provide `msime-engine`, `msime-client-core`, `msime-path-trust` and `chinese-ime-lm`.

## Invariants
- `src/runtime.rs:Runtime` owns host session/view identity while `src/engine.rs:InputEngine` owns composition operations. Asynchronous results must re-enter through runtime/engine freshness checks.

## Side Effects
- `src/providers.rs:UnixSocketProvider` performs local socket I/O; `OnlineProviderWorker` owns a background thread. Engine calls and injected plugin callbacks may have their own effects.

## Verification
- From `rust/`: `cargo test -p msime-input-runtime`.
