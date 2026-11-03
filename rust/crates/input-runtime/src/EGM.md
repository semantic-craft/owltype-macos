# Shared input runtime

## Overview
`Runtime` coordinates host actions, engine-owned composition, cached candidate presentation, provider results, and optional reranking. The crate re-exports its modules as a flat host-facing surface.

## Interface
- `engine.rs:InputEngine` abstracts snapshots, characters/commands, selection, punctuation, context, local tables, online candidates and touch input; its `Session` implementation delegates to `msime_engine::host::Session`. `RuntimeError` and `SegmentCommand` describe runtime failures and segment edits.
- `runtime.rs:Runtime::new`, `new_with_touch_layout`, `focus`, `dispatch`, `view`, `all_candidates`, `all_candidates_cached`, `candidate_page_len`, `is_idle`, and `has_composition` own the host session and publish views. `Action` covers characters, punctuation, engine/segment commands, selection/pinning/removal/position, grid/glide, finish and navigation.
- `runtime.rs:Runtime` exposes applied-state queries (`scheme`, `local_mode`, `generation`, composition/candidate epochs, `facts`, `selected_text`, `prefix_end`, `pending_suffix`) and settings/table methods for punctuation, keyboard grids, page size, Wubi shortcuts/commit, phrase preedit, English/mixed candidates, command/helpcode/quick-phrase/mention/plugin tables and engine replacement.
- `runtime.rs:Runtime::online_query`, `apply_online_candidate`, `apply_online_candidates`, their owned-query variants, `clear_online_candidates`, `translation_candidates`, `apply_translations`, `invalidate_translations`, `command_translation`, and `apply_command_translation` join asynchronous results to live state.
- `runtime.rs:Runtime::set_reranker`, `set_settled_reranker`, `rerank_settled`, `begin_settled_rerank`, `apply_settled_rerank`, and `discard_settled_rerank`, with `score_settled_rerank`, provide synchronous or detached scoring. `seed_context` and `clear_context` manage committed-text context.
- `types.rs` exports `CandidateId`, `NineKeySpellingId`, `Candidate`, `View`, `CandidateSnapshot`, `OutputContext`, `Transition`, selection facts/outcomes/retractions, and online/translation/handwriting/emoji/configuration DTOs.
- `providers.rs:cloud_request_url` and `cloud_candidate_from_response` adapt validated cloud descriptors. Unix-only `UnixSocketProvider` exposes online candidates, translation, credential tests, AI models/test, handwriting, emoji, voice stream/cancel/stop, cloud dictionary and clipboard exchanges. `OnlineProviderWorker` offers `spawn`, `spawn_with_debounce`, `submit`, `try_recv`, and `shutdown`.
- Desktop-only `transform.rs:CandidateTransform`, `CandidateOps`, `TransformRow`, `CommandProvider`, and `CommandOutcome` supply plugin decisions; `Runtime::set_candidate_transform`, `set_command_provider`, and `suspend_candidate_transform` install/control them.
- `multilingual.rs:Runtime::set_multilingual_output` selects segmented traditional output. `lib.rs:character_width` converts printable ASCII/fullwidth forms and re-exports shared model, punctuation and engine input types.

## Invariants
- `runtime.rs:Runtime::new_with_touch_layout` accepts page sizes 1–10 and allocates session IDs using checked atomic increment. `advance` uses checked generation increment. Candidate selection validates session, generation, visible range and (except explicit all-candidate selection) current page before engine mutation.
- `runtime.rs:apply_candidate_order`, `promote_row`, and `engine_index` keep every parallel candidate field and engine index mapping aligned, so selecting a displayed row addresses the corresponding engine candidate.
- `runtime.rs:set_page_size`, `set_key_grid`, `set_nine_key_enabled`, and engine replacement reject active composition. `is_idle` requires a valid snapshot and no held phrase/reading/preedit/nonprediction candidates.
- `runtime.rs:focus` invalidates identity, clears cross-client context and resets engine context. `remember_commit` retains at most 1,024 UTF-8 bytes on character boundaries; plugin rows do not enter that context.
- `runtime.rs:hold_phrase_progress` keeps selected partial words in `phrase_prefix` when enabled; callers must render this field. Successful engine commits survive later candidate-refresh failure; stale views are replaced with invalid empty snapshots in `refresh`.
- `runtime.rs:apply_online_candidates_snapshot` validates source, eligibility, nonempty bounded text and batch quotas; the engine validates query identity. Accepted updates advance host generation. `apply_settled_rerank` additionally checks composition generation and distinct settings/model epochs before publishing.
- `types.rs:View::caret_position` is an editing-text byte offset; conversion focus counts Unicode scalars; translation runs use UTF-8 byte ranges. These units must not be treated as native UTF-16 offsets.
- `transform.rs:run_transform` supplies the pre-plugin window of at most 20 rows. `arrange_candidates` retains all engine rows, moves hidden rows behind the visible prefix, preserves protected seats and never hides engine index 0. Dispatch may execute plugins; asynchronous/bypass paths only replay recorded operations. Mobile/web configurations use inert transform methods.
- `providers.rs:UnixSocketProvider::connect` rejects untrusted symlink ancestors, nonprivate/non-current-user parent directories and non-current-user sockets. It checks filesystem ownership, not connected peer credentials.
- `providers.rs:query_candidates` bounds serialized queries and response lines, deduplicates before source quotas (one cloud, configured AI count), and requires bounded valid candidates. `translate` returns without connecting when provider is Off. Voice events require the same nonzero generation, bounded lines/text, allowed status phases and normalized levels.
- `providers.rs:OnlineProviderWorker` keeps one latest pending query and one latest result irrespective of positive capacity; results remain inert until applied through Runtime identity checks.

## Side Effects
- `runtime.rs:Runtime` mutates engine/session state, presentation caches, retained phrase/context, and model ownership. Engine methods may perform their own persistence; this layer does not directly choose storage paths.
- `providers.rs:UnixSocketProvider` reads filesystem metadata and exchanges bounded newline-framed JSON with local Unix services, which own network/device/account effects. Voice APIs invoke caller-provided callbacks and poll cancellation while waiting.
- `providers.rs:OnlineProviderWorker` starts a named thread, uses mutexes/channels and optional debounce timing; explicit `shutdown` disconnects and joins the worker.
- `transform.rs` invokes injected host plugin callbacks during dispatch; `multilingual.rs` converts only Chinese segments after validating alignment with the selected engine candidate.

## Verification
- From `rust/`: `cargo test -p msime-input-runtime`. Build-time OpenCC preparation is inherited from `msime-client-core`; set `MSIME_OPENCC_OFFLINE=1` with valid cached inputs for offline execution. Provider/device/native-host acceptance is separate from unit coverage.
