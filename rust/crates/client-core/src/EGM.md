# Shared client core

## Overview
Platform-independent preferences, text validation, punctuation decisions, conversion, and cloud protocol helpers used by the input runtime.

## Interface
- `lib.rs` exports `cloud`, `endpoint`, `preferences`, `punctuation`, `text`, `translation`, and `chinese_conversion`, and re-exports text helpers. [Cloud contract](./cloud/EGM.md).
- `endpoint.rs:valid_endpoint_shape` checks scheme, explicit authority/host, absent credentials, and absent fragment; callers own field-specific bounds.
- `preferences.rs` exports keyboard layout, bracket/punctuation preferences, candidate-selection preferences and `MAX_CANDIDATE_PAGE_SIZE`; `slot` maps enabled selection keys.
- `punctuation.rs:route`, `arm_repeat`, `should_replace_repeat`, `arm_space_convert`, and `decide_space_convert` return host decisions from explicit context/snapshots. `ascii_for_chinese_mark` and `enumeration_comma_ascii` map punctuation twins.
- `text.rs` provides whitespace trimming, control-character policies, byte/character/UTF-16 bounds, ASCII/hex/identifier predicates and `safe_id`.
- `translation.rs:source_gets_no_gloss`, `translation_runs`, `TranslationRun`, and `TranslationRunRole` describe gloss display runs.
- `chinese_conversion.rs:TraditionalVariant`, `simplified_to_traditional`, `convert_to_traditional`, and `traditional_to_simplified_characters` expose standard/Taiwan conversion and character-only inverse lookup.

## Invariants
- `punctuation.rs:route` leaves composition or unavailable host context to the engine; Chinese/English locks override ordinary smart routing. `should_replace_repeat` requires matching editor generation/key/preceding commit, no composition/candidates, and a nonnegative age at most `REPEAT_WINDOW_MS` (2,000 ms).
- `punctuation.rs:arm_space_convert` rejects multi-scalar commits and auto-closed pairs; `decide_space_convert` requires the same editor generation and preceding mark.
- `preferences.rs:WubiCandidateSelectionPreferences::validate` requires two distinct one-byte ASCII punctuation keys.
- `translation.rs:translation_runs` returns UTF-8 byte offsets/lengths, identifies configured part-of-speech prefixes and separators, and merges adjacent same-role runs.
- `chinese_conversion.rs:Table::parse` keeps the first duplicate-key source and first listed value. Conversion uses maximum-prefix matching; Taiwan second-pass matching stays inside first-pass phrase segments. Complete bounded ideographic-description sequences pass through unmatched as a unit.
- `chinese_conversion.rs:traditional_to_simplified_characters` is a character inverse for dictionary lookup, not the OpenCC phrase-based `t2s` transformation.

## Side Effects
- `chinese_conversion.rs:tables`, `taiwan_tables`, and `traditional_to_simplified_characters` initialize process-local `OnceLock` maps from compile-time embedded data; conversions do not fetch files at runtime.
- Cloud cache/state effects are described in the [cloud contract](./cloud/EGM.md); other exposed text and punctuation helpers calculate values without external I/O.

## Verification
- From `rust/`: `cargo test -p msime-client-core`. The build script may prepare/download pinned OpenCC data; set `MSIME_OPENCC_OFFLINE=1` when the inputs are already available and network access is unwanted.
