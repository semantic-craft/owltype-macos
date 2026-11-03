# Rust crates

## Overview

Nine workspace packages separate input algorithms, runtime orchestration, client rules, application business state and native/process boundaries. Membership and shared dependency versions are defined in `../Cargo.toml`.

## Interface

| Directory | Boundary |
| --- | --- |
| [engine/EGM.md](engine/EGM.md) | `msime-engine`: dictionaries, composition, candidate generation/ranking and persistent user state. |
| [input-runtime/EGM.md](input-runtime/EGM.md) | `msime-input-runtime`: session lifecycle, key actions, transforms, providers and candidate-view coordination. |
| [client-core/EGM.md](client-core/EGM.md) | `msime-client-core`: extracted client types, OpenCC conversion, punctuation and cloud descriptor rules. |
| [path-trust/EGM.md](path-trust/EGM.md) | `msime-path-trust`: trusted path and file-opening checks. |
| [chinese-ime-lm/EGM.md](chinese-ime-lm/EGM.md) | Model parsing and candidate scoring with reusable inference caches. |
| [owl-msime-ffi/EGM.md](owl-msime-ffi/EGM.md) | C ABI exposing the input engine/runtime to Swift. |
| [owl-app-core/EGM.md](owl-app-core/EGM.md) | Application business rules, template transactions, AI/provider policy and resource lifecycle. |
| [owl-app-ffi/EGM.md](owl-app-ffi/EGM.md) | C ABI and native-effect callback boundary for app-core. |
| [owl-agent-mcp/EGM.md](owl-agent-mcp/EGM.md) | stdio MCP helper translating tools into the local Agent bridge protocol. |

## Invariants

The two FFI packages own unsafe C pointer adaptation; business rules and input runtime remain behind their Rust APIs. MCP is a separate process client of the application socket, not an in-process input engine. Package-specific contracts and manifests define the exact dependencies and exported surfaces; workspace membership does not imply a single deployment unit.

## Side Effects

Engine user journals, runtime provider workers, OpenCC build fetching, application storage effects and MCP socket I/O have distinct owners. Consult the relevant child contract before invoking a mutating or network-backed entry point.

## Verification

Run package-scoped Cargo tests from `rust/` when changing a package. `client-core/build.rs` can fetch pinned OpenCC inputs at build time; its contract documents offline cache configuration. ABI, installed application and live provider acceptance are separate from Rust unit tests.
