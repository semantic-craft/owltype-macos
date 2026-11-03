# App C ABI implementation

## Overview
Synchronous C entry points bridge native code to `owl-app-core` decisions, host-mediated storage transactions, and owned ephemeral sessions.

## Interface
- `lib.rs:owl_app_abi_version` returns ABI 1; `owl_app_call` dispatches the tagged `Request` JSON enum into client capability, resource/user/provider/agent/AI/pure rules, template, quick-send, prompt, backup, keyboard, and UTF-16 operations.
- `lib.rs:owl_app_storage_call` routes operation prefixes into storage modules through `NativeHost` and a synchronous `HostCallback`.
- `lib.rs:owl_app_session_new`, `owl_app_session_call`, and `owl_app_session_free` own and operate `owl_app_core::template_session::Session` handles. `owl_app_string_free` releases returned JSON buffers.
- `lib.rs:owl_app_keyboard_can_apply`, `owl_app_keyboard_schema_idle_action`, `owl_app_keyboard_refresh`, and `owl_app_marked_text_should_send` expose direct small decisions.

## Invariants
- `lib.rs:owl_app_call` validates ABI, non-null/nonempty request and a 32 MiB bound before reading bytes; caught Rust panics produce `internal_error`. JSON errors contain error codes rather than input payloads.
- `lib.rs:owl_app_storage_call` and `owl_app_session_new` validate nonempty input up to `isize::MAX`, not the pure call's 32 MiB bound. `owl_app_session_call` allows Runtime snapshots up to the pointer-size bound, Invocation requests up to 4 MiB, and other session requests up to 32 MiB.
- `lib.rs:owl_app_session_call` rejects identical session/index pointers. The caller must supply distinct live handles and serialize their use/destruction; the implementation cannot validate arbitrary raw pointer ownership.
- `lib.rs:NativeHost::effect` borrows callback output only until parsing finishes, never frees it, and requires an `ok`/`value` or `error` envelope. Returned `CString` pointers are Rust-owned and must be freed exactly once; null frees are allowed.
- `lib.rs:owl_app_keyboard_can_apply` returns `u8::from(bool)` (0 or 1). The header's 0/1/2 comment does not describe this implementation's return mapping.

## Side Effects
- `lib.rs:StatelessHost` and template duplication read wall-clock time for generated identifiers; the pure dispatcher has no native I/O callback.
- `lib.rs:Request::ResourceContract` delegates directly to app-core resource checks: configuration can create directories, and file/generation checks read files and SQLite. The absence of a host callback does not make every `owl_app_call` operation I/O-free.
- `lib.rs:owl_app_storage_call` synchronously invokes the supplied native service on the caller's thread; those host callbacks execute external storage/system effects.
- `lib.rs:owl_app_session_new`, `owl_app_session_call`, and free functions allocate, mutate, and release owned session state/response buffers.

## Verification
- From `rust/`: `cargo test -p owl-app-ffi`. Native ownership, callback and host-effect integration needs the Swift ABI suites as well.
