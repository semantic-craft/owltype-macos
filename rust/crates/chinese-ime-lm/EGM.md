# chinese-ime-lm

## Overview
Character-level language-model crate used for Chinese input candidate reranking.

## Subdirectories & Boundaries
- [Source contract](./src/EGM.md): safetensors loading, transformer scoring, and per-session reranking caches.

## Interface
- `Cargo.toml:package.name` exports `chinese-ime-lm` version 0.2.0 with a Rust 1.75 minimum; public entry points are `src/lib.rs:SentenceModel` and `Reranker`.

## Invariants
- `Cargo.toml:lints.rust.unsafe_code` forbids unsafe Rust in this crate. `src/lib.rs:CandidateFacts` keeps engine evidence separate from model scores.

## Side Effects
- `src/lib.rs:Reranker` maintains memory-only caches; weight loading accepts bytes instead of choosing a filesystem location.

## Verification
- From `rust/`: `cargo test -p chinese-ime-lm`.
