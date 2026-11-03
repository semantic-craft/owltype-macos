# Backend request adapter

## Overview

Stateless JSON operation adapter retained from the MSIME cloud backend. These files implement local request processing; they do not define an HTTP server or an Owltype network endpoint.

## Interface

- [mod.rs:execute](./mod.rs) accepts a parsed request, caller-supplied resource/scratch paths and a `SimplifiedToTraditional` callback; `execute_raw` also checks byte framing. `BackendError::code` exposes stable error strings.
- [mod.rs:route](./mod.rs) dispatches Unicode/date/romaji/local modes, candidates, catalogs, dictionary checks, annotations, Japanese conversion, personal queries and validation.
- [request.rs:Request](./request.rs) is the internal typed field/batch boundary; [common.rs:Roots](./common.rs) keeps resource and mutable dictionary roots distinct.
- [input.rs:query_candidates](./input.rs) reuses the existing scheme/provider registry. [local_modes.rs](./local_modes.rs), [text_tools.rs](./text_tools.rs) and [catalogs.rs](./catalogs.rs) implement the corresponding operation families.
- [dictionary_checks.rs:listed_pinyin_batch](./dictionary_checks.rs), `listed_english_batch` and `pinyin_weight_medians` query shipped data; [validation.rs:validate_dictionary](./validation.rs) and `validate_dictionary_batch` reuse engine entry validation.
- [personal.rs:personal](./personal.rs) replays a caller-provided snapshot and returns ranking/deletion changes; `validate_snapshot` verifies normalized exported entries.

## Invariants

- `execute_raw` rejects non-object JSON and requests over `MAXIMUM_REQUEST_BYTES` (64 KiB). `Request::new` requires an operation, caps text at 8192 bytes and limits at 1–200; `Request::batch` accepts 1–50 items.
- Paths come from `execute` arguments, not request fields. `Roots::require_resources` and personal/provider setup require nonempty absolute roots where invoked. The caller owns a distinct scratch directory per request and its cleanup.
- `input.rs:candidates_for_input` restricts `cloud_candidates` to database rows whose complete key equals normalized input; it does not return prefix/generated rows as whole-input replacements.
- `catalogs.rs` chooses SQL identifiers from fixed names or engine format rules and binds request values as parameters. Catalog pagination bounds offset to 0–1000000 and limit to 1–200.
- `personal.rs:apply_action` requires an existing candidate and nonempty context, rejects deletion of single-character non-English entries, and bounds ranking step/count before mutation.

## Side Effects

- `dictionary_checks.rs:open_read_only` opens SQLite resources with read-only/no-follow flags. Catalogs, providers and text tools read dictionaries and model/helpcode files.
- `personal.rs:personal` creates scratch user/cache state; `write_snapshot` transactionally writes `user_dictionary_operations`, `fixed_candidate_positions` and `candidate_selection_state`, and runtime preparation may copy/replay dictionaries. Ranking/deletion mutate these scratch copies; the caller persists returned changes and removes scratch state.
- `text_tools.rs:convert` invokes the caller's conversion callback. No HTTP transport is implemented in this directory.

## Verification

From `rust/`: `cargo test -p msime-engine`. Tests were not executed as part of this documentation bootstrap.
