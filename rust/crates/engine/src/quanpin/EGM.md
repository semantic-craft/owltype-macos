# Full-pinyin query engine

## Overview

Quanpin builds requests from typed letters, resolves corrections and alternative readings, and combines dictionary prefixes, completions, lattice sentences, fuzzy and online rows. [Dictionary page storage](./dictionary/EGM.md) preserves cached row values efficiently. `typo_edges/` and `fixture.rs` are test-only.

## Interface

- `[scheme.rs:QuanpinScheme]` preserves typed case and manual delimiters, supports host replacement, and builds correction-mode requests; `apply_literal_segmentation` implements suppression recuts.
- `[engine.rs:QuanpinEngine]` applies helpcodes, initial-page expansion, online batches, conversion queries and canonical phrase creation over `QuanpinDictionary`.
- `[dictionary.rs:QuanpinDictionary]` exposes query/filtering, read batches, fuzzy and initial queries, model/configuration updates and cache reset. `RowCacheBatch` scopes batched snapshot reads.
- `[series.rs:resolve_series_query]` separates the primary correction, equal-cost alternatives and costlier alternatives. `[typo_edges.rs:collect_span_typo_edges]` shares bounded phrase-typo planning with Shuangpin.

## Invariants

- `[engine.rs:query]` rejects invalid requests. Double helpcodes filter; a single helpcode reorders. Missing keymaps match no double-code rows and leave single-code order unchanged. Initial expansion requires no active helpcode and a one-letter first segment.
- `[series.rs:resolve_series_query]` protects manual delimiters, complete inputs and syllable-plus-initial shapes from correction. Up to nine correction cuts are retained; a failed whole correction may retry a 1–2-letter incomplete tail without neighbor substitutions. Equal-cost readings compete on frequency; costlier readings remain below that tier.
- `[series.rs:merge_alternative_rows]` stably merges by weight and deduplicates words. A sufficiently weighted alternative outside the fixed six-row first page may move to index 1; already visible alternatives keep their earned rank. This fixed promotion gate is distinct from the host-sized completion gate.
- `[dictionary.rs:query_series_with_typos]` visits longest coverage first. Up to three longer phrases, at most three syllables longer, retain typed consumption and complete canonical reading. An exact ordinary leader keeps its seat; enough exact rows to fill the configured first page push completions after that group. Lattice sentences follow full-key dictionary answers. Fuzzy full-word answers may displace a stand-in sentence only when no exact typed-reading answer exists.
- `[dictionary.rs:query_exact_projected]` publishes correction markers even on cache hits and validates database, typo-profile and personal-model generations before reuse. Hash-indexed caches also compare full keys. Resolution memoization survives row-cache resets because it depends only on spelling and static rules.
- `[dictionary.rs:validate_row_caches]` checks `PRAGMA data_version`; unavailable versions clear row caches. `row_cache_batch` rotates reads after 20 ms at the next computed query and ends the transaction in `Drop`, including unwind. Series cache capacity is 128; raw row/decode caches 512, lattice spans 4096, typo spans 512.
- `[dictionary.rs:expand_initial_candidates]` expands only a still-limited 24-row initial group and updates the originating series slot. Online batches use that same resolved slot; association switches/context distinguish relevant answers.
- `[typo_edges.rs:plan_keys_with]` tries weak single-character positions first, limits planning to 96 unique keys, spans 2–3 syllables and four rows per key, and discounts penalties with personal acceptance counts. Manual boundaries suppress sentence typo edges.
- `[dictionary.rs:create_word_from_canonical_pinyin]` normalizes umlaut aliases and checks nonempty complete segments against the word's character count without recutting supplied boundaries. Existing entries succeed without journaling.

## Side Effects

- Construction opens the working dictionary, warms prepared statements and loads shared n-gram/personal/typo models. Queries read local stores and mutate FIFO caches; keyboard/collocation option changes may load model files.
- `[dictionary.rs:insert_new_word]` inserts into the working dictionary before journaling. It clears caches even if the journal write fails, then propagates that error; the inserted working row is not rolled back. `record_personal_use` writes through the shared personal store, and callers must release `personal_model` read guards before recording.
- Online insertion changes in-memory caches only; no provider network request originates here.

## Verification

From `rust/`: `cargo test -p msime-engine quanpin`. This documentation pass did not run tests, modify databases or exercise a host session.
