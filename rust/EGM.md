# Rust workspace

## Overview

Owltype's Rust input engine/runtime extraction and application business core. `Cargo.toml` declares nine packages; `msime-source.json` records the pinned MSIME upstream revision, extraction boundaries, product adaptations and resource provenance. The human READMEs remain separate documentation.

## Interface

- [crates/EGM.md](crates/EGM.md) routes to engine/runtime, client rules, language models, path trust, two C ABIs, application core and the MCP helper.
- [scripts/EGM.md](scripts/EGM.md) covers pinned OpenCC fetching and download retry behavior used by builds.
- [shared/EGM.md](shared/EGM.md) covers retained cross-language contract inputs.
- `rust-toolchain.toml` selects stable Rust, rustfmt/clippy and both Apple Darwin targets. Workspace package defaults are Rust 2021, minimum 1.89 and GPL-3.0-only; individual package manifests and dependency/data notices may differ (`Cargo.toml`).

## Invariants

- `msime-source.json` pins MSIME `macos-v0.55.0` at `208c10e848bbed99373ca8b609fd2142b6b0b4e2`; the checkout includes declared local adaptations. This is provenance metadata, not a claim that all workspace code is unmodified upstream.
- Input composition and user journals remain engine responsibilities; input runtime coordinates sessions/providers; app-core owns application decisions; native unsafe adaptation belongs to FFI packages. Follow child contracts for exact ownership.
- Workspace lints deny unsafe Rust by default; FFI crates explicitly define their boundary policy. Build profiles disable dev incremental/debug info, optimize the language model/JSON dependencies and retain package-specific EWTS overflow behavior (`Cargo.toml`).
- Generated build artifacts, test-only directories, binary resources, bundled third-party data and noncode-only fixture directories are outside this bootstrap's retained implementation tree. Their exclusion is not deletion or a claim that they are irrelevant to shipping.

## Side Effects

Cargo builds can execute `client-core/build.rs`, fetching pinned OpenCC data unless an offline cache is configured. Runtime side effects include engine persistence, provider workers/socket I/O, application storage/resource operations and MCP transport; those are documented at their owners. Reading this navigation adds none.

## Verification

Run relevant package tests from this directory; use project native acceptance for ABI wiring, installed IME behavior and external providers. This bootstrap creates documentation only and does not establish build, test, installation or live-provider acceptance.
