# Japanese romaji conversion

## Overview

Japanese input scheme, romaji/kana conversion, binary lemma dictionary, bounded matrix search, and candidate provider. Model lookups use `msime-japanese.dat`; this module does not query a Japanese lexicon table in the Pinyin SQLite database. The physical `decoder`, `matrix`, `provider`, and `romaji` subdirectories contain test-only modules and are excluded from the production contract tree. [mod.rs] [decoder.rs:JapaneseDictionary] [provider.rs:JapaneseProvider]

## Interface

- `JapaneseRomajiScheme` accepts letters, apostrophe, minus, and backspace; builds/reuses `QueryRequest`; restores raw input; and cycles the final kana variant. [scheme.rs:JapaneseRomajiScheme]
- `RomajiConversion`, `convert_romaji`, `hiragana_to_katakana`, `hiragana_to_romaji`, `next_kana_variant`, and `kana_for_romaji_prefix_view` expose conversion values and fixed-table lookup. Internal reusable-output functions share the scanner. [romaji.rs:RomajiConversion] [romaji.rs:scan_romaji_with]
- `JapaneseDictionary::shared`, `from_bytes`, `preload`, `unload`, `release_shared`, and `warm_up_in_background` manage immutable MSJPDT1 models. Borrowed lemma callbacks provide exact, prefix, and continuing-prefix queries; `connection_cost` supplies matrix costs. [decoder.rs:JapaneseDictionary]
- `search_converted_into` produces bounded unique text candidates; `best_path` also reports unknown-kana usage for mixed-language admission. [matrix.rs:search_converted_into] [matrix.rs:best_path]
- `JapaneseProvider::query`/`query_into`, `cache_dynamic_candidate`, `clear_online_candidates`, and `reset_cache` manage candidates. `prepare_if_cached`, `whole_reading_lemma`, and `whole_reading_best_path` support mixed-language consumers. [provider.rs:JapaneseProvider]

## Invariants

- Scheme raw text retains case; query conversion lowercases ASCII. Final single `n` remains pending in display-only reading but resolves to `ん` for lookup/commit; `nn` consumes one `ん`. Variant cycling refuses a pending tail. [scheme.rs:build_request_into] [scheme.rs:cycle_last_kana_variant] [romaji.rs:romaji_display_reading_into] [romaji.rs:scan_romaji_with]
- Models require valid magic/version, bounded token/connection/string ranges, valid UTF-8 boundaries, valid connection IDs, sorted readings, and nonempty token/readings. Exact and prefix ranking use `(cost, token_id)`; continuing-prefix callbacks can retain repeated IDs from overlapping suffixes, with output text deduplication performed above them. [decoder.rs:parse] [decoder.rs:build_short_prefix_index] [decoder.rs:prefix_lemmas_continuing_with]
- Read-only mmap safety depends on immutable model bytes replaced by rename, never in-place writes. Files must be regular and opened without following symlinks. Shared cache hits revalidate file identity; at most two strong filesystem models remain in production, and released live models can be reused through weak references. Preloaded bytes take precedence and remain until explicit unload. [decoder.rs:load_with_identity] [decoder.rs:SharedModels] [decoder.rs:shared]
- Global loading is serialized without holding the shared-cache mutex across file parsing. Release generations prevent an in-flight load from repinning strong ownership. Shared failures are not cached; each provider's normal lazy dictionary slot does retain its first failure, while `prepare_if_cached` can later receive a ready shared model. [decoder.rs:shared] [decoder.rs:release_shared] [provider.rs:dictionary] [provider.rs:prepare_if_cached]
- Matrix rows retain at most eight paths, spans cover at most 16 reading characters, and unknown kana cost 12,000 keeps paths reachable. Connection costs include sentence-end transition. Returned candidate texts are nonempty and unique within the bounded result list; the list itself may be empty. Tie order is preserved by the row policy. [matrix.rs:Row] [matrix.rs:search_with_output] [matrix.rs:PathRow]
- Candidate order is insertion order, not weight order. Missing models still allow kana. Complete readings promote hiragana to at most the second slot before dynamic insertion; cloud rows are inserted before exact homophone tails. Dynamic cache accepts only nonempty `CloudSuggestion` rows and has capacity 128; no network request occurs here. [provider.rs:query_into] [provider.rs:cache_dynamic_candidate]

## Side Effects

Reads/maps model files, checks metadata, acquires process-wide cache/loading locks, and may spawn one warm-up thread per path. Preload/unload/release mutate caches; active Arc holders preserve models. Query/scheme operations mutate owned reusable buffers and in-memory dynamic candidates. This module does not persist learning or call a network provider. [decoder.rs:JapaneseDictionary] [provider.rs:JapaneseProvider] [scheme.rs:JapaneseRomajiScheme]

## Verification

From `rust`, run `cargo test -p msime-engine japanese::`. This documentation bootstrap did not run tests. Fixtures can verify conversion and model/cache contracts; shipped-model and platform memory behavior require the corresponding resource/platform acceptance.
