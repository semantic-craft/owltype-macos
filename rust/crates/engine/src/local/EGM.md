# Local candidate sources

## Overview

Local special modes, mixed expressive rows and host-supplied short tables. These modules generate or read candidates; the session owns mode entry, placement, selection, learning policy and input-length enforcement. Embedded TSV data is compiled into the engine; this contract covers the Rust consumers rather than auditing every data row.

## Interface

- [mod.rs](mod.rs) exports `LocalQueryResult` (candidates plus an optional diagnostic) and `GENERATED_MODE_INPUT_LIMIT` (64). [database.rs](database.rs) provides `open_local_database`, `close_cached_local_databases` and the session-scoped `LocalDatabaseLease`.
- [catalog.rs](catalog.rs): `read_emoji_catalog_slice`, `emoji_catalog_groups` and `emoji_symbol_groups` serve paged emoji/kaomoji/symbol catalogs. [emoji.rs](emoji.rs) supplies mode queries and mixed/readings queries; [jianpin.rs](jianpin.rs) supplies initial-letter lookup and its ranking context; [quick_phrase.rs](quick_phrase.rs) reads packaged phrases and merges a validated host table.
- [command.rs](command.rs): `usable_command_table`, `query_command`, `translation_source`, `usable_plugin_commands` and `plugin_command_source` validate and resolve commands. They return text/source descriptors; they do not execute a plugin or translation request.
- [date_time.rs](date_time.rs) generates date, time, weekday, lunar and relative-date rows from `LocalDateTime`; `current_local_date_time` supplies the local wall clock, and `insert_inline_date_time` adds rows/menu entries beside an existing anchor.
- [expression.rs](expression.rs): `query_expression` handles units, dotted dates, numbers and arithmetic. [units.rs](units.rs): `query_units`, `warm_up`, `warm_up_in_background` manage closed-table conversions. [unicode.rs](unicode.rs): `query_unicode` accepts an optional `+` and up to six hex digits representing a Unicode scalar.
- [mention.rs](mention.rs): `usable_mentions`, `query_mentions`, `mention_annotation` combine host entries with the embedded [places.rs](places.rs) index. [chaizi.rs](chaizi.rs): `query_chaizi` and `reading` search embedded component spellings and character readings. [url.rs](url.rs) recognizes URL/email entry and supplies static scheme, suffix and TLD completions without navigating.
- [symbol_candidates.rs](symbol_candidates.rs): `query_mixed_symbols` and `query_symbol_readings` return `SymbolRow` values with anchors and ambiguity/placement flags. [symbol_groups.rs](symbol_groups.rs): `groups` and `query_symbol_mode` combine exact Latin/LaTeX names, exact-or-prefix groups, then other exact symbol names.

## Invariants

- `database.rs` opens SQLite read-only with no-follow flags and a one-second busy timeout. Its process cache keeps one path per filename; leases count users by directory and remove that directory's cached connections when its last lease drops. Lock ordering is users before cache. Catalog API calls open their own read-only connection.
- `read_emoji_catalog_slice` clamps pages to 1–4096 and reports offsets in scanned SQL rows, including rows discarded or deduplicated. Search values are bound but SQL `LIKE` wildcards retain their meaning. Catalog failures use fixed diagnostics rather than exposing SQL or paths.
- Emoji mixed fetches cap each reading at 16 and the total at 48; mode default limit is 10. Missing mixed data yields no rows, while explicit mode failures can carry a diagnostic. Jianpin accepts letters, expands double-pinyin initials, and verifies full initial matches after its bounded SQL scan.
- `usable_command_table` accepts at most 256 entries with 1–32 lowercase-letter triggers and validated `{date}`, `{time}`, `{weekday}` templates. Expanded text is control-free and at most 199 UTF-16 units. The first occurrence of a valid trigger claims it even if its template is unusable. Plugin triggers have 2–16 lowercase letters, titles 1–8 characters, and cannot overlap prefixes of built-ins, user commands or earlier plugins. Exact command matches precede prefixes; user rows precede built-ins within each pass.
- `usable_quick_phrase_table` retains at most 8192 enabled, valid rows, with 1–32 lowercase-letter keys and nonblank/control-free text of at most 199 UTF-16 units; it sorts by key. Database failure does not prevent host phrase rows from being merged. `usable_mentions` caps entries at 1000 and keys at 64 letters/apostrophes; mention text must be nonblank and fit 199 UTF-16 units. Mention validation does not apply the phrase table's control-character prohibition. Host mentions precede place fallback, exact matches precede prefixes and the total is capped at 18.
- Expression output has at most nine rows, rejects nonfinite values, variables and disputed power syntax, formats 15 significant digits and restricts exact-integer/Chinese-number conversions. Unit expressions are built only from a checked signed decimal (at most 16 magnitude bytes) and table-owned unit names; incompatible or identical explicit units are rejected. Temperatures use offsets directly; other conversions use Rink.
- Mixed symbols match complete names, not prefixes, and deduplicate to at most eight rows. Quanpin accepts nonnumeric multi-syllable initials; shuangpin normalizes full spelling and does not use initials. Nine-key queries use accepted whole readings. Merged anchors use the less restrictive ambiguity/unanchored flags. Symbol rows use `CandidateSource::Emoji`; session code determines their final placement and commit behavior.
- Chaizi prefix matching requires at least two complete components, returns at most 36 distinct characters and ranks exact decompositions first. Its embedded tables are empty on wasm. Place and symbol indexes initialize once. Date/time inline generation requires its anchor; `menu:` rows represent navigation rather than literal text to commit.

## Side Effects

Read-only SQLite opens, process-wide connection/index caches and local wall-clock reads occur here. `warm_up_in_background` attempts one named background thread to build a process-wide Rink context; failed initialization is cached as unavailable, and failed thread spawn leaves lazy initialization to a later query. Embedded-table queries and URL completions perform no network I/O. Host contacts, command execution, persistence and candidate-learning decisions belong to callers.

## Verification

From `rust/`: `cargo test -p msime-engine local::`. This bootstrap read all production bodies, including `mention_annotation` after a test module; inline test bodies and the test-only `mention/` and `places/` directories were excluded. No tests or resource probes were executed.
