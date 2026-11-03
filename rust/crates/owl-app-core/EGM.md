# owl-app-core

## Overview

Rust business rules for the native application: keyboard preferences, templates and delivery, provider requests and credential transaction policy, resource lifecycle, user-data migration, and Agent access. This crate shares decisions across Swift callers through `owl-app-ffi`; it is separate from the input engine and `msime-input-runtime` (`Cargo.toml`, `src/lib.rs`).

## Interface

- [src/EGM.md](src/EGM.md) owns the exported Rust modules, JSON operation dispatchers and ephemeral session types.
- [src/pure_rules/EGM.md](src/pure_rules/EGM.md) details small host-independent input and application decisions.
- `Cargo.toml` depends on serde/JSON, Unicode segmentation and normalization, regex/URL parsing, SHA-256/base64 and SQLite; it does not depend on the engine or a network client.

## Invariants

- Business decisions consume supplied facts. Native storage, Keychain, GUI, accessibility, calendar and transport operations normally cross `storage::Host`; the resource contract/catalog modules also perform direct filesystem and read-only SQLite work. Do not describe the entire crate as I/O-free (`src/storage.rs:Host`, `src/resource_contract.rs`, `src/resource_catalog.rs`).
- Template content, invocation state, host delivery and persistence have separate owners. An evaluated preview is not a delivery receipt or a committed library (`src/template.rs:render`, `src/template_session.rs:Invocation`, `src/host_delivery.rs:Delivery`, `src/template_transaction.rs`).
- Provider catalogs and prompts are compiled inputs. Their presence describes this binary's behavior, not live provider availability (`src/provider_wire.rs:rule`, `src/ai_business.rs:prompt`).

## Side Effects

Host-backed dispatchers request filesystem, lock, secret-reference, collation and runtime effects. Resource setup/build functions create directories and files directly; resource verification opens files and SQLite read-only. The crate itself does not contact AI endpoints or insert text through AppKit (`src/storage.rs:effect`, `src/resource_contract.rs:configuration`, `src/resource_catalog.rs:build`).

## Verification

From `rust/`, `cargo test -p owl-app-core` checks this package. Native storage effects, host observations, delivery receipts and credential transport need their adapter-level verification as well. Documentation bootstrap read the production modules; it did not run tests or live effects.
