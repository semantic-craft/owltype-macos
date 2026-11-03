# zhuyin

## Overview

Dachen and nine-key Zhuyin editing with dictionary conversion and pinned spans.

## Interface

- [scheme.rs:ZhuyinScheme](./scheme.rs), `ZhuyinKey`, `ListCandidate` own editing, candidate-list selection, spelling locks, request snapshots and committed-text extraction.
- [conversion.rs:Span](./conversion.rs), `convert`, `MAX_SYLLABLES` define span conversion.
- [layout.rs:DACHEN](./layout.rs), `symbol`, `tone_mark` define the physical layout; [nine_key.rs:NineKeyIndex](./nine_key.rs), `KEYPAD`, `digit`, `tone_mark` define numeric spelling.
- [syllable.rs:PendingSyllable](./syllable.rs) maintains one symbol per initial/medial/rime slot.

## Invariants

- `ZhuyinScheme::select` pins a valid open-list row without committing; `choose_spelling` locks an allowed target reading without committing.
- `handle_char` / `handle_nine_key_char` admit completed syllables from the dictionary inventory and auto-shift the leftmost word at 20 completed syllables.
- `conversion.rs:convert_filtered` excludes overlaps with pins, ranks squared span lengths before weights, and falls back for missing single syllables; callers supply valid nonoverlapping pins.
- `NineKeyIndex::new` limits codes to three digits and sorts/deduplicates readings; `PendingSyllable::pop` removes rime, then medial, then initial.

## Side Effects

- The scheme queries its supplied `LanguageDictionary`, lazily builds a nine-key inventory and caches best entries. Editing mutates composition and pending commit buffers; `take_committed` drains pending text. No dictionary writes occur in this directory.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
