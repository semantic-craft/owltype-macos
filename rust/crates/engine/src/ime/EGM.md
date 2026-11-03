# Scheme and candidate orchestration

## Overview

This layer owns the active scheme and provider set, rebuilds requests and candidate lists, and composes local/English/expressive/online rows. The outer session owns commits and persistent learning. The `personal_rerank/` child is test-only.

## Interface

- `[mod.rs:ImeSession]` exposes activation/switching, key handling, raw-prefix queries, candidate refresh, live options and dynamic row application; `CompositionState` holds preedit, request, candidates and aligned Wubi codes.
- `[scheme.rs:Scheme]` dispatches ten concrete editors with an enum. `[registry.rs:ProviderRegistry]` owns configured providers and activated language dictionaries.
- `[queries.rs:CandidateQueries]` dispatches local modes and merges quick phrases, contacts, English, Japanese, symbols, emoji and kaomoji. `[online_batch.rs:replace_online_candidate_batch]` replaces one validated provider batch atomically.
- `[personal_rerank.rs:personal_context_rerank_order]` returns a bounded permutation for the leading dictionary group.

## Invariants

- `[mod.rs:switch_scheme]` activates resources before replacing the editor, preserving current composition on activation failure. Disabled schemes are rejected. Zhuyin lends/returns its connection through the registry; its candidate list belongs to its editor.
- `[registry.rs:ProviderRegistry::new]` constructs only needed providers; Wubi enables a Quanpin fallback provider. `wubi_database` tries generation Wubi, generation main, resource Wubi, then resource main. Cantonese/Zhuyin/Stroke open on activation; Japanese warm-up is asynchronous and unavailable models do not fail activation.
- `[mod.rs:decode]` keeps exact Wubi matches ahead of pinyin, but pinyin ahead of Wubi prefix completions; rows retain their producing scheme. Grid codes do not enter mixed pinyin. `keep_pinyin_tail` makes the remainder Quanpin until reset/empty/switch or disabling mixed input. `z` reverse lookup requires mixed pinyin and wildcard both off.
- `[mod.rs:apply_autocorrect_suppression]` refreshes the personal typo profile and disables correction plus recuts literally for a suppressed spelling. Manual-tab helpcode mode disables the competing triggers. Raw-prefix queries reuse scratch storage without replacing live composition.
- `[mod.rs:mixed_japanese_conversion]` requires lower-case complete romaji in pinyin schemes and a cached Japanese provider: exact readings require three morae; the alternative requires incomplete pinyin, no unknown kana, and path cost at most 1800 per kana.
- `[online_batch.rs:replace_online_candidate_batch]` rejects empty/control-bearing/over-4096-byte words and non-online sources before mutation. Distinct-word quotas are cloud 1 and AI 10. AI replaces its old/pending rows at the tail; cloud replaces its seat or uses index 1, preserving an existing pending seat when its answer duplicates local text.
- `[queries.rs:mixed]` requires enabled mixing, a supported scheme and ordinary composition. English leads only for an exact surviving spelling that is not complete pinyin; weights from the two dictionaries are never compared. Expressive rows use word anchors and remain off the lead after the final repair step. Symbols use bounded ambiguous/unanchored slots; emoji variant selectors do not duplicate an identical symbol.
- `[queries.rs:default_quick_phrase_slot]` preserves at least the first half of ordinary first-page seats. Contacts match exact before prefix, occupy paired name/phone rows and cap at 18. User command-table entries override conflicting plugin commands.
- `[personal_rerank.rs:personal_context_rerank_order]` considers at most 16 contiguous dictionary rows of equal character count, blends positive-weight shares with personal probability, keeps stable ties and a pinned leader, and returns no permutation for an unchanged order.

## Side Effects

- Provider construction/activation and local queries read dictionaries and models; caches, request buffers and candidate vectors mutate in memory. Japanese warm-up schedules model loading.
- Online rows are cached data only; this layer sends no network request. The registry deliberately has no persistent candidate writer: the outer session routes learning by producing scheme and resets provider caches afterward. Personal reranking may read pin state through its callback.

## Verification

From `rust/`: `cargo test -p msime-engine ime`. This documentation pass did not execute tests or live input.
