# multilingual

## Overview

Dictionary-backed adapter for the parent multilingual decoder.

## Interface

- [dictionaries.rs:DictionaryComposer](./dictionaries.rs) exposes `new`, `with_japanese_model`, `warm_up_in_background`, `convert` and `clear`. Parent decoder types live in [../multilingual.rs](../multilingual.rs).

## Invariants

- `convert` requires at least two selected languages, nonempty lowercase ASCII input and the parent input budget; failures discard cached input rather than returning partial paths.
- `MAX_SPAN_QUERIES` bounds each update to 4096 span queries; `MAX_SURFACE_BYTES` limits provider surfaces to 256 bytes and `MAX_CHINESE_SYLLABLES` to seven.
- `clear` invalidates confirmed and missing spans; model/language changes require reconstruction.

## Side Effects

- Construction initializes only selected Chinese/English/Japanese providers when at least two languages are active. `warm_up_in_background` forwards to the selected Japanese provider; dictionary queries and provider cache resets occur during conversion/clear. No resource download is issued here.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
