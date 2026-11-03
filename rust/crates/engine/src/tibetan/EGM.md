# tibetan

## Overview

EWTS key composition and Tibetan display conversion.

## Interface

- [mod.rs:TibetanScheme](./mod.rs) reexports the scheme; `TSHEG` and `SHAD` expose session punctuation.
- [scheme.rs:TibetanScheme](./scheme.rs) exposes handling, request building, preedit, spelling-symbol claims and raw-display locking.

## Invariants

- `claims_letter` admits only EWTS letters until raw locking, after which ASCII letters pass through. `claims_symbol` never puts slash into raw composition.
- `preedit_into` rewrites kSh to k+Sh only in the conversion copy and falls back to raw input for an empty conversion.
- `restore_raw` acts once per composition; backspace removes a raw key and resets the lock when empty.

## Side Effects

- `converter` initializes a process-wide `OnceLock<EwtsConverter>`; scheme methods mutate memory and caller-provided output/request buffers. No disk/network operations occur in these files.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
