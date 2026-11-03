# Host-facing engine facade

## Overview

The safe Rust facade validates host options, maps flattened snapshots and commands, and provides bounded dictionary and gloss operations. The parent core session owns composition; this layer keeps host-specific ordinals and Enter learning policy. The `session/` child contains regression tests only.

## Interface

- `[mod.rs]` reexports `EngineOptions`, `Session`, `EngineSnapshot`, `EngineResult`, `Command`, dictionary maintenance, lookup, gloss and text helpers.
- `[options.rs:prepare_options_for]` stages dictionary generations for requested schemes; `session_options` validates host values and translates them into core options.
- `[session.rs:Session]` exposes input/command/selection, grid and glide input, live settings, snapshots, online/plugin/translation request application and candidate editing. It is thread-confined through `PhantomData<Rc<()>>`.
- `[dictionary.rs:stage_dictionary_state]` and maintenance wrappers expose isolated browsing, edits, state staging and merging. `[dictionary_lookup.rs:dictionary_resource_entries]` supports the installed auxiliary language dictionaries.
- `[glosses.rs:candidate_glosses_with_user]`, `english_completions`, `english_corrections`, and `save_candidate_gloss` provide bounded display data and explicit learned-gloss writes. `[text.rs]` wraps reading/code lookup, normalization, hints, emoji and handwriting ordering.

## Invariants

- `[session.rs:Command]` preserves host ordinals, including `CommitRawWithoutLearning`; `command` maps the later conversion commands explicitly. `result_for` preserves an empty commit with `has_commit = true` and a diagnostic alongside a successful commit.
- `[session.rs:snapshot]` keeps candidate text, keys, annotations, sources, answer flags and optional evidence aligned. Code annotations use candidate identity, not a reused seat index. Japanese display completion does not commit a pending final `n`.
- `[session.rs:online_request]` rejects unavailable requests, unknown schemes and sources other than cloud/AI as stale. Core generation/session identity remains part of the request. ASCII input boundaries and fixed positions 1–5 are validated before delegation.
- `[session.rs:commit_raw_with_policy]` learns eligible Enter-committed English only when enabled; grid composition, conversions, generated local text, URLs and complete pure pinyin are excluded. Learning failure keeps the commit and adds a diagnostic. `commit_raw_without_learning` cancels dedicated-English composition after capturing its raw preedit.
- `[options.rs:session_options]` validates schemes/profiles and supported numeric values. Sidecar preparation checks absolute roots and regular files, bounds reads to 1 MiB and atomically persists the selected custom translation file.
- `[dictionary.rs:released]` releases the current thread journal after pooled maintenance operations, including failures. `stage_dictionary_state` rejects a zero record limit and does not treat snapshot errors as EOF.
- `[dictionary_lookup.rs:dictionary_resource_entries]` bounds limits to 1–1000, offsets to one million and queries to 256 bytes. A missing dictionary reports unavailable; an invalid installed dictionary reports an error.
- `[glosses.rs:candidate_glosses_with_user]` resolves custom, learned, then packaged glosses; display keeps at most two senses and rejects controls. English completions require ASCII and limits 1–32; corrections retain raw input first. Read-only gloss/phonetic databases require their metadata version and language/kind.

## Side Effects

- `[options.rs:prepare_options_for]` stages local database generations. `session_options` may copy/delete the translation sidecar and attempt a downloaded Wubi merge before opening a session.
- `[session.rs:Session]` owns a `LocalDatabaseLease`; input can invoke core learning and dictionary mutation. `Drop` flushes that journal and releases its thread-local handle. Hosts that exit without dropping sessions must invoke the exported `flush_personal_learning` lifecycle hook.
- Dictionary maintenance and `save_candidate_gloss` explicitly write local state; lookups and snapshots read databases and update in-memory caches. Online/plugin/translation requests are data handed to the host, not network calls from this module.

## Verification

From `rust/`: `cargo test -p msime-engine host`. This documentation pass read production source and did not execute builds, dictionary maintenance or live host input.
