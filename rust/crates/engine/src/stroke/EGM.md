# stroke

## Overview

Stroke-key composition and single-character dictionary lookup.

## Interface

- [mod.rs:STROKES](./mod.rs), `WILDCARD`, `MAX_STROKES`, `is_stroke`, `is_key`, `glyph`, `key_of_glyph` define key/glyph conversion.
- [scheme.rs:StrokeScheme](./scheme.rs) exposes editing, requests and candidates; `StrokeCandidate` retains text, weight and dictionary key.

## Invariants

- `StrokeScheme::handle_key` accepts h/s/p/n/z, permits x only after a stroke, and limits composition to 64 keys. Host edits can retain a leading wildcard.
- `scheme.rs:StrokeQueryBuffer::query` caps exact rows at 200 and completion rows at 100. Candidate projection retains first text occurrence and moves nonpositive-weight rows behind positive-weight rows.
- `StrokeScheme::candidates_into` clears destination candidates on query error.

## Side Effects

- Candidate methods query the supplied `LanguageDictionary`; editing and reusable query buffers mutate memory. No dictionary writes are issued by these files.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
