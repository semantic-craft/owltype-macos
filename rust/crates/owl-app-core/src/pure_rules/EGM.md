# Native application decision rules

## Overview
Pure decisions over host-supplied facts for input, shortcuts, onboarding and installation diagnostics. JSON dispatch lives beside typed rule functions.

## Interface
- `mod.rs:dispatch` selects named rules and returns JSON values or `unknown_pure_rule:<name>`.
- `auto_pair.rs:PAIRS`, `AutoPairAction`, `decide`, `single_closer`; `commit_transform.rs:apply_commit_transform`; `forced_finalize.rs:commit_text`, `ForcedFinalizePlan`, `plan_forced_finalize`; and `marked_text_resend.rs:should_resend_marked_text`, `should_resend_lengths` describe text effects for hosts to execute.
- `user_action.rs:RawKeyEvent`, `UserAction`, `classify_user_action`, `classify_user_action_with`, `classify_user_action_value`, `osx_keycode_to_engine`, `osx_modifiers_to_engine`, `infer_modifier_keycode`, and `resolve_key_chars` translate native key facts.
- `hotkey.rs:RecordedHotKey`, letter/keycode helpers, `validate_hotkey`, `hotkey_label`, `encode_hotkey`, `decode_hotkey`, and `hotkey_matches` handle recorded shortcut representations.
- `app_input_memory.rs:initial_mode`, `should_remember`; `onboarding_practice.rs:PracticeProof`; and `emoji.rs:Glyph`, `emoji_catalog`, `emoji_search`, `recents_seed`, `recents_push` implement per-app decisions and small presentation data.
- `input_source_diag.rs:TisSourceState`, `TisDiagnosis`, `LsBundleClaim`, `LsClaimReport`, `classify_tis_diagnosis`, and `classify_ls_claims` classify supplied TIS/Launch Services facts.
- `session_restart.rs:RestartRequest`, `RestartObservation`, `RestartServer`, `UnmetCondition`, `maps_lsof`, `unmet_server_conditions`, and `unmet_conditions` compare observed installed-server/source state with a request.
- `logout_prompt.rs:should_suggest`, `RecheckDecision`, `recheck_decision`, `SafeVerdict`, `evaluate_safe_verdict`, and `classify_logout_error`; `engine_runtime_rule.rs:ENGINE_OPTIONS`, `is_valid_engine_option`, and `refresh_decision` describe update/runtime policies.

## Invariants
- `auto_pair.rs:decide` acts only on a single scalar when enabled; it skips an existing closer only when the right-neighbor fact matches. `marked_text_resend.rs:should_resend_marked_text` suppresses only empty-to-empty updates, including resending equal nonempty text.
- `hotkey.rs:validate_hotkey` requires a listed letter keycode and at least two permitted modifier bits. `decode_hotkey` returns supplied legacy presets directly; its general text path validates the parsed shortcut.
- `user_action.rs:classify_user_action_with` passes Command-modified key-down through, distinguishes unchanged modifiers, and orders generated releases before presses.
- `onboarding_practice.rs:PracticeProof::is_complete` requires exact target text, an Owl composition commit, no other-source content and no marked text.
- `session_restart.rs:maps_lsof` requires both executable path and inode in one `ftxt` record; `unmet_server_conditions` separately checks server count, installed path, nonempty version mismatch and executable mapping.
- `input_source_diag.rs:classify_tis_diagnosis` leaves menu visibility/client attachment unverified (`ok: None`); these cannot be inferred from successful TIS registration checks.
- `logout_prompt.rs:evaluate_safe_verdict` and the JSON `mod.rs:dispatch` logout safety branch are distinct implementations: the JSON branch checks input-idle time even during a stale-composition override and accepts thresholds as arguments. Callers must use the intended entry point.

## Side Effects
- `onboarding_practice.rs:PracticeProof::inserted` mutates only its in-memory proof. Other rules return decisions/data; they do not send keys, inspect TIS/Launch Services, run `lsof`, log out, write preferences or touch host documents themselves.

## Verification
- From `rust/`: `cargo test -p owl-app-core`. Native evidence collection and execution require their host integration tests.
