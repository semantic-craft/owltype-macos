# korean

## Overview

Dubeolsik and Romaja composition with explicitly opened Hanja candidates.

## Interface

- [mod.rs:KoreanLayout](./mod.rs) selects Dubeolsik (0) or Romaja (1).
- [scheme.rs:KoreanScheme](./scheme.rs) exposes key handling, raw restoration, request building, Hanja visibility and `take_committed`.
- [dubeolsik.rs:Jamo](./dubeolsik.rs), `jamo_for_key`, `compose`, `compose_into` provide layout composition; [romaja.rs:compose_into](./romaja.rs) shares the syllable fold.
- [hanja.rs:readings](./hanja.rs), `gloss`, `candidates`, `query_into` project the embedded Hanja table.

## Invariants

- `KoreanScheme::handle_key` retains mutable raw keys while moving only stable syllables into the pending commit buffer; backspace closes an open Hanja list before deleting raw input.
- `KoreanScheme::set_raw_input` retains ASCII letters and clears pending commits/Hanja; cased input wins when supplied.
- `hanja.rs:query_into` preserves table order and produces `CandidateSource::Database` / `SchemeType::Korean` rows.

## Side Effects

- Key handling mutates in-memory composition and pending output; `take_committed` drains it. `hanja.rs:index` lazily caches an index over compile-time `hanja.tsv`; no runtime file or network access in these files.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
