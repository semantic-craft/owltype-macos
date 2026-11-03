# Engine source boundaries

## Overview

`lib.rs` exposes the core composition API and a flattened `host` facade. This directory also owns stable wire types, runtime asset/path rules, grid input, shared strings, punctuation and final candidate ordering. Scheme-specific behavior and persistence live in the linked modules.

## Interface

- `[lib.rs]` reexports `Session`, `SessionOptions`, `SessionSnapshot`, `RuntimePaths`, scheme/candidate types, dictionary maintenance and lifecycle helpers. `host` is the entry used by host-api and input-runtime.
- `[types.rs:WordItem]` distinguishes consumed input from canonical reading and retains source, scheme, correction and sentence evidence. `SchemeType`, `CandidateSource`, `Command`, `OnlineQuery` and option structs carry shared contracts.
- `[nine_key.rs:NineKeySession]` implements numeric/reduced-key spelling, locking, filtering, selection and learning. `[nine_key_shuangpin.rs]` validates and interns grid tables and derives reduced-key mappings from Shuangpin profiles.
- `[language_dictionary.rs:LanguageDictionary]` reads auxiliary language tables; `[helpcode.rs:HelpcodeKeymap]` loads bounded built-in/custom character codes. `[ordering.rs]` supplies model eligibility, context and permutation helpers.

## Subdirectories & Boundaries

- [backend](./backend/EGM.md) — Stateless JSON operation adapter for local candidate/catalog queries, validation and scratch personal-state operations.
- [cantonese](./cantonese/EGM.md) — Jyutping inventory, spelling and dictionary candidates.
- [dictionary](./dictionary/EGM.md) — Working pinyin, English and Han-reading database adapters.
- [handwriting](./handwriting/EGM.md) — Local recognition adapter and candidate ordering.
- [host](./host/EGM.md) — Validated flattened host facade, dictionary maintenance and gloss services.
- [ime](./ime/EGM.md) — Scheme/provider ownership and candidate list composition.
- [japanese](./japanese/EGM.md) — Romaji/kana, immutable Japanese models and matrix decoding.
- [korean](./korean/EGM.md) — Hangul composition and the embedded Hanja table.
- [lattice](./lattice/EGM.md) — Sentence graphs, n-gram/personal/collocation scoring and neural rerank.
- [local](./local/EGM.md) — Local command, expression, date, emoji, phrase and catalog modes.
- [multilingual](./multilingual/EGM.md) — Language span collectors for mixed-language decoding.
- [pinyin](./pinyin/EGM.md) — Shared syllables, cuts, correction/fuzzy expansion and glide geometry.
- [quanpin](./quanpin/EGM.md) — Full-pinyin dictionary, correction and sentence query pipeline.
- [session](./session/EGM.md) — Composition, caret/conversion, mode dispatch, commits and learning policy.
- [shuangpin](./shuangpin/EGM.md) — Two-key profiles, helpcode parsing and dictionary query pipeline.
- [stroke](./stroke/EGM.md) — Stroke spelling and read-only single-character lookup.
- [tibetan](./tibetan/EGM.md) — EWTS composition and raw-text restoration.
- [user_dictionary](./user_dictionary/EGM.md) — Trusted runtime generations, journal/replay, personal state and reset.
- [vietnamese](./vietnamese/EGM.md) — Telex/VNI composition and tone rendering.
- [wubi](./wubi/EGM.md) — Wubi profiles, grid/code lookup and mixed-pinyin support.
- [zhuyin](./zhuyin/EGM.md) — Zhuyin editor, conversion lattice and constrained choices.

The `nine_key/` child contains regression modules only; production grid logic remains in `nine_key.rs` and `nine_key_shuangpin.rs`.

## Invariants

- `[types.rs:CandidateSource]` and `SchemeType` ordinals are compatibility values; the retired source value remains unused. `FirstPageRows::new` normalizes zero to one. `KeyResult` may preserve a commit alongside a diagnostic; callers must not treat that diagnostic as proof that nothing committed.
- `[paths.rs:RuntimePaths]` captures explicit absolute roots. Asset resolution falls back to legacy names only when the modern leaf is absent. `open_file_no_follow` rejects redirected/nonregular files; write-side SQLite guards require trusted parent paths and a single-link leaf, with deliberately separate read-only language-resource rules.
- `[language_dictionary.rs:open_read_only]` requires supported metadata, opens read-only/no-follow with zero busy timeout and never creates data. Exact/prefix/pattern queries preserve matching and stable weight/text ordering; wildcards match one non-space character.
- `[helpcode.rs]` bounds file reads to 1 MiB and restricts custom stems. Absent built-in files can yield an empty map; invalid custom selections fail. Single codes reorder and double codes filter, using first/last character codes.
- `[cache.rs:FifoCache]` uses insertion age: reads do not promote and replacement keeps the prior age. `[shared_string.rs:SharedString]` has value equality and copy-on-write mutation; empty strings need no allocation.
- `[nine_key.rs:NineKeySession]` bounds input to 48 digits, paths to 48, queried paths to 24 and retained candidates to 128. Locks and split boundaries constrain refresh; editing the middle unlocks the affected tail. Candidate consumption uses typed code while persistent learning uses canonical readings. Failed learning can accompany a retained commit.
- `[nine_key_shuangpin.rs]` interns valid custom tables by canonical content for stable references; check-only validation does not retain edited intermediate tables. Derived 14/18-key mappings retain the profile-specific interpretation.
- `[ordering.rs:apply_order]` validates the entire permutation and keeps parallel candidate metadata aligned. Rerank eligibility excludes unsuitable sources/input; sentence runner-up adjustment moves rows without deleting them.
- `[multilingual.rs]` bounds raw input to 96 bytes and 4096 lexemes, validates UTF-8 spans and requires at least two languages. Path ordering favors fewer lexemes/switches before rank and stable textual ties; adjacent equal-language spans coalesce.
- `[punctuation.rs]` owns quote alternation and bracket/book-title state independently of display preferences. `[time.rs]` uses native monotonic time or injected browser clocks with saturating arithmetic and safe zero readings before injection.

## Side Effects

- Sessions and dictionary APIs can read/write local working stores and journals; model caches and interned tables retain process memory. Grid commits invoke the same personal-learning boundary as ordinary composition.
- `[lib.rs:flush_personal_learning]` drains delayed personal transitions before direct journal reads, generation replacement or host termination. `close_cached_databases` releases cached handles before deleting/replacing data directories.
- `[lib.rs:preload_japanese_dictionary]`, `unload_japanese_dictionary` and `release_japanese_dictionary_cache` manage shared model lifetimes; existing sessions keep their references. `[web.rs]` imports/deletes memVFS databases only on the browser target; callers must close active connections before replacement.
- Provider protocol modules return requests for the host to execute. Core local prediction and ranking do not themselves perform provider network calls.

## Verification

From `rust/`: `cargo test -p msime-engine`. Per-module contracts give focused filters. This documentation pass read production source, validated documentation structure/links and did not run Rust builds, tests, live input or database mutations.
