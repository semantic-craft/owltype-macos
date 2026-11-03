# MSIME host adapter implementation

## Overview

Bridges native host state and JSON actions to the pinned engine/runtime, including host candidate presentation, quick phrases, configuration, reranking and staged user migration.

## Interface

- [lib.rs:OwlMsimeSession](./lib.rs) prepares roots and resources, maps action JSON to transitions and builds snapshot DTOs. Its exported `owl_msime_*` functions form the session/string ABI.
- [sessions.rs:register_session](./sessions.rs), `with_session` and `destroy_session` manage opaque tokens, thread-local sessions and the live-session registry.
- [config.rs](./config.rs) exposes YAML-backed configuration handles with slash-path patch normalization and recursive map overlay.
- [rerank.rs:RerankState](./rerank.rs) configures model loading and keyboard/settled reranking; [punctuation_menu.rs:PunctuationMenu](./punctuation_menu.rs) owns fixed symbol menus.
- [smart_punctuation.rs:dispatch](./smart_punctuation.rs) forwards the pinned client-core punctuation policy. [user_migration.rs](./user_migration.rs) validates staged imports and applies them with recovery snapshots.

## Invariants

- `sessions.rs` allocates monotonically increasing tokens with checked overflow. Wrong-thread, stale and reentrant access fails through `with_session`; the lifecycle lock coordinates creation/destruction with finalization.
- `lib.rs:prepare_explicit_roots` rejects redirected and overlapping roots before/after creation. Generation preparation separates writable state from resource content. Legacy empty user paths use a session-owned temporary directory.
- Snapshot generations distinguish runtime candidates from punctuation menus. `remove_token` requires the current generation and a visible index; `select_token` rejects an explicitly stale generation, while an omitted generation uses the current view.
- Page size defaults to five for zero and otherwise clamps to 1–10. Non-ASCII insert/punctuation input is unhandled; unknown operations return an error, while unknown `set_option` names leave state unchanged.
- Quick-phrase candidate preference changes apply only when idle. Host phrases remain a runtime table; `reconcile_quick_phrases` restores official rows and replays personal edits instead of treating host phrases as official database rows.
- Reranking validates an absolute model path, digest and regular non-symlink file bounded to 64 MiB; loading runs off the caller thread. Token/presentation checks discard stale settled results, and actions other than candidate peeks invalidate pending work.
- Migration accepts exactly the manifest, dictionary-state and prepared marker, verifies schema/mapper/request identifiers and digests, and bounds records and pins. The caller must stop sessions before applying an import; validation alone does not apply it.
- C entry points catch panics where implemented and return their documented null/error forms; callers still own pointer validity and matching string/configuration destruction.

## Side Effects

- Constructors create roots and stage dictionaries; engine actions persist learning, personal edits and candidate state. Reconfiguration may cancel input and rebuild the engine.
- Rerank workers read model files and share weak cached models; no network request is implemented here.
- Migration serializes imports with `IMPORT_LOCK`, snapshots databases and sidecars, closes caches, merges data and restores snapshots on failure. Failed recovery retains its snapshot for repair.
- YAML configuration reads files; returned ABI strings allocate owned C strings. Finalization closes engine database caches only after all sessions are destroyed.

## Verification

From `rust/`: `cargo test -p owl-msime-ffi`. Tests were not executed as part of this documentation bootstrap.
