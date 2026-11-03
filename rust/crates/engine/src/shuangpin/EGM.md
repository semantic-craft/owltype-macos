# Shuangpin profiles and query engine

## Overview

The two-key input path supports five built-in profiles and validated custom layouts, helpcode modes, pinyin dictionary lookup, fuzzy rows and sentence decoding. It shares pinyin/lattice/personal resources with Quanpin while retaining Shuangpin consumption and correction rules. The `dictionary/` child is test-only.

## Interface

- `[profile.rs:ShuangpinProfile]` supplies initials, finals and zero-initial mappings; `profile` resolves built-ins and `accepted_syllables` fixes the accepted inventory.
- `[custom.rs:custom_profile]`, `session_profile`, `validate_custom_profile`, `check_custom_profile` and `builtin_table` validate/use/edit custom layouts. `[hints.rs:shuangpin_key_hints]` and `shuangpin_zero_initials` derive built-in keyboard hints.
- `[scheme.rs:ShuangpinScheme]` handles keys and request construction. `[query.rs]` and `[utils.rs]` define code conversion, segmentation, raw/effective boundaries and helpcode recognition.
- `[mid_sentence.rs:parse_mid_sentence_helpcodes]` returns stripped input, original source offsets, per-syllable constraints, decorations and terminal codes.
- `[engine.rs:ShuangpinEngine]` selects normal/helpcode/direct/fuzzy paths; `[dictionary.rs:ShuangpinDictionary]` owns row/series/helpcode caches, lattice construction, dynamic insertion and initial expansion.

## Invariants

- `[custom.rs:canonicalize]` requires exactly the known three multi-letter initials, 33 finals and 12 zero-initial units. Keys normalize to lowercase; semicolon is only a final or second zero-initial key. Initial collisions and ambiguous accepted two-key readings are rejected. `check_custom_profile` retains nothing; `validate_custom_profile` interns through `custom_profile`. Invalid custom settings only fall back when Shuangpin is disabled.
- `[utils.rs:encode_pinyin]` succeeds only when every encoded syllable decodes back through the same profile. Segmentation greedily takes a valid two-key code before one-key initials; explicit apostrophes preserve boundaries. `[query.rs:is_complete_input]` rejects leading/trailing/doubled delimiters and incomplete pairs.
- `[scheme.rs:handle_key]` accepts semicolon as a final only for a profile using it and at the appropriate odd chunk length. Request construction keeps original helpcode-marked input for display and separately records normalized spelling/constraints/source offsets.
- `[mid_sentence.rs:UppercaseTriggers::new]` gives mid-sentence precedence over end triggers. Backtick blocks constrain the preceding syllable; terminal blocks filter only at the input end, otherwise acting as boundaries. A later constraint on the same syllable replaces an earlier one. Source offsets include a terminal original-length entry.
- `[engine.rs:query]` ignores mid-sentence constraints without a nonempty keymap. Terminal and traditional direct helpcodes keep their separate filtering/reordering semantics. `direct_helpcode_paths` caps output at 64 paths and traversal at 512 nodes, supports slash/uppercase endings only when enabled, and restores original consumed-code spans after filtering.
- `[engine.rs:query_standard]` preserves complete ordinary readings ahead of ambiguous direct-helpcode paths. Fuzzy merges rank by consumed-key coverage; dictionary weights are compared only among dictionary rows within equal coverage. `keep_typo_sentence_off_first_seat` moves a literal row to the lead or clears a typo-only list.
- `[dictionary.rs:generate_series]` queries longest prefixes first and deduplicates words. Row, series and each helpcode FIFO have capacity 128; typo spans have capacity 512. Cache keys include manual delimiters, constraint signature and active neural context. Cache hits check database changes; personal model revisions invalidate tracked personal-scored series answers.
- `[dictionary.rs:generate_constrained_sentences]` filters before the lattice span cap; candidate filtering applies only to wholly Han pinyin-answer sources, preserving non-pinyin catalog rows. Initial expansion requires a still-limited 24-row group and actual growth.
- `[dictionary.rs:insert_word_to_active_helpcode_cache]` updates existing helpcode slots only; series insertion can create a slot. Double codes select the double cache; a single-code update reaches both case-direction caches. Clearing a source preserves other rows.
- `[typo_edges.rs:collect_shuangpin_typo_edges]` admits only complete two-key spans without manual apostrophes, with neighbor/transposition edits only. Its profile-specific table is keyed by profile address and shares Quanpin span budgets without Quanpin's learned typo discount. A typo sentence cannot become the only/first answer.

## Side Effects

- Dictionary construction opens/warm-ups the existing working database and loads n-gram/personal resources. Queries read versions and models and mutate caches. Association changes may load keyboard/collocation models; fuzzy lookup lazily opens a Quanpin dictionary.
- Valid custom profiles and per-profile typo tables are interned for process lifetime behind mutexes. Check-only custom validation avoids this retention.
- Dynamic candidate insertion affects memory only. Persistent pins, deletions and frequency learning belong to the outer session/user dictionary; this module does not perform provider network requests.

## Verification

From `rust/`: `cargo test -p msime-engine shuangpin`. Production source was read directly, with the dictionary and typo-edge files covered by the delegated read-only scout. No tests, live input or persistent dictionary operations were executed in this documentation pass.
