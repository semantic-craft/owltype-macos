# cantonese

## Overview

Toneless Jyutping segmentation and read-only Cantonese dictionary candidates.

## Interface

- [mod.rs:CantoneseDictionary](./mod.rs) opens the dictionary and shares its syllable `Inventory`.
- [scheme.rs:CantoneseScheme](./scheme.rs) owns keys, requests, candidates and prefix selection; `CantoneseCandidate` carries text, weight, key, syllable count and consumed byte end.
- [syllable.rs:Inventory](./syllable.rs), `Syllable`, `Segmentation`, `segment` and `best` expose dictionary-derived segmentation.

## Invariants

- `CantoneseScheme::handle_key` accepts lowercase letters, non-leading/non-repeated apostrophes and backspace; host edits normalize letters and boundaries.
- `syllable.rs:walk` respects apostrophe boundaries and caps alternative segmentations at `MAX_SEGMENTATIONS = 16`. Inventory and segmentation inputs must be lowercase ASCII.
- `scheme.rs:deduplicate_candidates` retains first rows per text and span length; `select_end` consumes a valid candidate byte prefix, then leading boundaries.

## Side Effects

- `CantoneseDictionary::open` opens `LanguageDictionary` read-only and loads its syllable inventory; candidate queries read it. Scheme editing mutates in-memory composition.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
