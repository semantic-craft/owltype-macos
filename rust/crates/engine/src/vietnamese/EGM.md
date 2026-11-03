# vietnamese

## Overview

Telex/VNI composition through the pinned vi crate.

## Interface

- [mod.rs:InputMethod](./mod.rs) maps 0/1 to Telex/Vni; `ToneStyle` maps 0/1 to Modern/Classic.
- [scheme.rs:VietnameseScheme](./scheme.rs) exposes raw keys, editing, preedit, request building and raw-display locking.

## Invariants

- `VietnameseScheme::handle_key` accepts ASCII letters; VNI digits are spelling only while composing. Backspace removes one raw key.
- `restore_raw` locks nonempty unlocked composition; `set_raw_input` resets that lock and prefers case-preserving input.
- `preedit_into` applies the explicit uppercase workaround for vi 0.8.0; `transform_into` selects the configured method and tone style.

## Side Effects

- Scheme operations mutate in-memory raw keys, lock state and caller-provided output/request buffers. No file or network operations occur in these files.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
