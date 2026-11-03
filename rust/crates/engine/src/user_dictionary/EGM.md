# User dictionary and learned state

## Overview

Owns the SQLite user journal, working dictionary generations, learned ranking/context and personal dictionary administration. Immutable resources and mutable working copies have separate lifetimes.

## Interface

- [journal.rs:open_journal](./journal.rs), `ensure_schema`, `close_cached_journals` and `quarantine_corrupt_journal` manage connections and the version-4 schema.
- [generation.rs:prepare_runtime_paths_for](./generation.rs) stages or reopens a resource generation; `merge_downloaded_wubi` adds separately delivered Wubi tables. [replay.rs:replay](./replay.rs) and `replay_english` apply journal operations.
- [personal.rs](./personal.rs) validates, lists, exports and edits personal entries, including bounded batch and collection-import APIs. [bundled.rs:dictionary_table_entries](./bundled.rs) and `edit_bundled_dictionary_entry_with` browse and reweight/delete other dictionary rows.
- [ranking.rs:RankingRequest](./ranking.rs) drives frequency and quick-phrase slot learning. [positions.rs](./positions.rs), [removal.rs](./removal.rs), [picks.rs](./picks.rs) and [wubi_learning.rs](./wubi_learning.rs) implement fixed positions, pins, deletion, pick-pair evidence and generated Wubi entries.
- [ngram_store.rs:PersonalNgramStore](./ngram_store.rs) shares context per journal; [typo_profile.rs:PersonalTypoProfile](./typo_profile.rs) shares spelling habits.
- [state.rs](./state.rs) streams/revisions/stages/merges dictionary state; [habits.rs](./habits.rs) separately streams and merges six learning-habit tables. [reset.rs:reset_learned_data_with](./reset.rs) replaces working dictionaries and clears learned state.

## Invariants

- `prepare_runtime_paths_for` requires disjoint absolute roots and content IDs of 1–128 ASCII letters, digits, underscores or hyphens. It uses exclusive staging, SQLite backup, journal replay and a ready marker before publishing; a ready generation is replayed again when reopened (`generation.rs`).
- Every new journal connection applies the complete schema; `user_version=4` is informational. One journal connection is cached per thread/path, and abandoning a transaction rolls it back; callers must not nest journal handles inside an active transaction (`journal.rs`).
- The schema includes `user_dictionary_operations`, `personal_dictionary_receipts`, `candidate_selection_state`, `fixed_candidate_positions`, `pick_transitions`, `pinyin_typo_counts`, `pinyin_autocorrect_suppressions`, `pinned_candidates`, `personal_bigram`, `personal_trigram` and `quick_phrase_slots` (`journal.rs:SCHEMA_SQL`).
- Personal edits normalize and validate codes and values; new weights are 1–100000000. Previous entries must match the current journal row. A nonempty request ID makes identical retries idempotent and rejects different payload reuse. Ordinary batches allow 128 items; collection batches allow 4096, with per-item savepoints and one outer transaction (`personal.rs`).
- Dictionary pages allow limits 1–1000 and offsets through 1000000; bundled queries cap input at 256 bytes. User-inserted rows must use the personal editor rather than the bundled editor (`personal.rs`, `bundled.rs`).
- Replay rolls back on failed operations or an incomplete read. English-only generations skip other dictionary kinds; absent Wubi tables defer Wubi journal rows until resources arrive (`replay.rs`).
- Ranking writes journal changes before committing working-dictionary changes so replay can recover a journal ahead of its working copy; this is not one atomic transaction across both connections (`ranking.rs`). Fixed slots are 1–5 (`positions.rs`).
- State revision hashes ordered entries/positions/selections with the `msime-local-dictionary-state-v1` framing; habit records are separate. Replacement staging rejects duplicate identities/slots; merges preserve existing local entries and take maximum selection counts (`state.rs`, `habits.rs`).
- Maintenance callers must quiesce sessions before reset or hold exclusive dictionary maintenance ownership for merges. Reset restoration is best-effort on failure (`reset.rs`, `state.rs`, `habits.rs`).

## Side Effects

- Creates/updates SQLite journals, working dictionaries, schema/indexes, staging/ready files and optional n-gram copies. Corrupt journals are renamed with sidecars only for SQLite corruption/not-a-database errors (`journal.rs`, `generation.rs`).
- Personal context updates memory immediately and schedules a background flush after about 2 seconds or 64 pending transitions; failed writes remain queued, while release drops transitions that cannot be flushed before the journal is replaced (`ngram_store.rs`).
- State/habit export uses `query_only` transactions but SQLite may create WAL coordination files. Missing journals are not created by export (`state.rs`, `habits.rs`).
- Reset swaps backups and replacements, removes obsolete sidecars after publication and attempts rollback on failure (`reset.rs`). These are API effects, not operations performed by this bootstrap.

## Verification

From `rust/`: `cargo test -p msime-engine`. Tests were not executed as part of this documentation bootstrap.
