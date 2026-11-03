# App ABI declarations

## Overview
C-compatible declarations for the Rust application-rules and owned-session ABI.

## Interface
- `owl_app_ffi.h` declares `owl_app_abi_version`, `owl_app_call`, `owl_app_storage_call`, `owl_app_host_callback`, keyboard/marked-text decisions, `OwlAppSession`, its create/call/free functions, and `owl_app_string_free` under C linkage.
- [Implementation contract](../src/EGM.md) records actual dispatcher bounds and return values.

## Invariants
- `owl_app_ffi.h:owl_app_call` input bytes are borrowed for the synchronous call; response JSON is Rust-owned, NUL-terminated, and freed once.
- `owl_app_ffi.h:OwlAppSession` requires caller-serialized live handles, a distinct optional borrowed index, and no use after free; null frees are accepted.
- Header prose and implementation differ on some numeric details: `owl_app_keyboard_can_apply` actually returns 0/1; session/storage bounds vary by entry point/session kind. Use `../src/lib.rs` and its contract for those current implementation details.
- The header's blanket I/O-free description of `owl_app_call` is stale: its resource-contract dispatch can perform direct filesystem/SQLite work. See the implementation contract before scheduling such calls.

## Side Effects
- Declarations themselves perform none. `owl_app_host_callback` defines a synchronous external-effect callback; owned sessions and response buffers require explicit destruction.

## Verification
- From `rust/`: `cargo test -p owl-app-ffi`; header compilation and native ABI integration belong to the native build/tests.
