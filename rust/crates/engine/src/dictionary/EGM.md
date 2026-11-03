# Working dictionary access

## Overview

SQLite adapters serve pinyin, English completion/glosses, and Han-to-pinyin lookup. They preserve reference query ordering and missing-resource behavior while sharing table naming and path guards with the engine root. [English correction](./english/EGM.md) owns mobile spelling correction. The `pinyin/` child contains only regression modules.

## Interface

- `[mod.rs:DictRow]` carries key/value/64-bit weight. `column_text`, `column_i64`, and `sql_limit` preserve SQLite conversion and bounded-limit semantics.
- `[pinyin.rs:PinyinDatabase]` exposes `open`, `database_changed`, `begin_read`/`end_read`, `warm_up`, segmented/exact/initial/jianpin/lattice/next-word queries, `find_weight`, and `insert_word`.
- `[english.rs:EnglishDictionary]` exposes read-only `open`, readiness, prefix completion and bilingual gloss lookup. `ensure_english_schema`, `upsert_gloss`, and `load_custom_translations` are explicit mutation/loading boundaries.
- `[hanzi.rs:hanzi_to_pinyin]` supplies validated reading lookup for imports.

## Invariants

- `[pinyin.rs:open_connection]` opens existing working databases read/write without CREATE, rejects redirected paths, uses a 250 ms busy timeout and 512 prepared statements. Missing files/tables answer empty. `database_changed` polls `PRAGMA data_version`; `begin_read`/`end_read` delimit one snapshot for query batches.
- `[pinyin.rs:query_single_cut_keyed]` tries exact, prefix, mixed-jianpin, then pure-jianpin in order. `query_segments_keyed_flat` keeps first value occurrence before stable weight sorting and truncation; exact batch lookup intentionally does not deduplicate values. `visit_rows_until` preserves successfully read rows when subsequent reads fail.
- `[pinyin.rs:query_lattice_span]` normalizes and validates complete syllables and uses exact keys. `query_next_words` requires aligned Han characters and complete readings, caps output at 32, and returns only uncommitted suffixes.
- `[english.rs:open]` never creates or migrates on read. Prefix reads use a zero busy timeout; `read_prefix_rows_at` discards an incomplete failing page. `query_gloss` prefers the custom sidecar, then packaged glosses, then the learned cache, reopening an unavailable cache on a later request.
- `[english.rs:load_custom_translations]` limits regular-file input to 1 MiB, strips BOM/line endings and comments, accepts tab-separated rows and lets later keys win. `ensure_english_schema` rebuilds legacy word tables in an immediate transaction and sets schema version 3.
- `[hanzi.rs:hanzi_to_pinyin]` accepts 1–128 characters in the bridge's Han ranges, searches exact table readings before per-character fallback, and returns empty on unavailable data. `cached_single_hanzi_map` caches at most eight paths and does not retain scans interrupted by a busy database.

## Side Effects

- `[pinyin.rs:insert_word]` writes the working dictionary with `INSERTED_WEIGHT`; the caller owns validation and journaling policy. Connection initialization adjusts mmap and prepared-statement settings.
- `[english.rs:ensure_english_schema]` can create/migrate a database; `upsert_gloss` creates the learned schema and writes one gloss. Other query paths read files and maintain connection/page caches.
- `[hanzi.rs:HANZI_CACHE]` retains shared per-path readings in process memory.

## Verification

From `rust/`: `cargo test -p msime-engine dictionary`. Tests use isolated dictionaries; this documentation pass did not execute them or modify dictionary data.
