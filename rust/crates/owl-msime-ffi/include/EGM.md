# MSIME C ABI declarations

## Overview

[owl_msime_ffi.h](./owl_msime_ffi.h) declares the opaque session/configuration interfaces consumed by native hosts. Definitions live in [the source directory](../src/EGM.md).

## Interface

- Session constructors support legacy paths, explicit roots, resource generations and separate auxiliary resources; creation errors use an optional owned string out-parameter.
- Session action/snapshot calls return JSON; rerank configuration, status, start and poll calls expose asynchronous model work.
- Configuration calls load YAML, read scalar/list values and app options, and free configuration handles.
- Stateless functions dispatch smart punctuation and simplified-to-traditional conversion. Migration exports validate and apply a staged user import.

## Invariants

- Include guards and `extern "C"` permit C and C++ consumers. The header exposes no Rust struct layout.
- Callers provide valid NUL-terminated strings for non-null input pointers and release returned strings with `owl_msime_string_free`.
- Session calls stay on their creating thread. Destroy sessions before engine finalization; finalization refuses to close caches while any session remains live.
- The declarations are not a second implementation: action validation, path checks and failure representations are defined by the corresponding Rust functions.

## Side Effects

The header itself has none. Calling declared functions can allocate strings/handles, prepare local databases, update user data or start rerank work as described in the implementation contract.

## Verification

From `rust/`: `cargo test -p owl-msime-ffi`; native consumers additionally compile against this header through the repository build. Neither was executed for this documentation bootstrap.
