# Cloud candidate orchestration

## Overview
Shared request generation, freshness checks, and translation-cache state for injected host transports.

## Interface
- `mod.rs` exports `candidates`; `candidates.rs` re-exports [provider contracts](./candidates/EGM.md).
- `candidates.rs:TranslationCache::new`, `get`, and `remember` manage positive/negative entries.
- `candidates.rs:CloudCandidateState::update` returns request generations; `apply` accepts current results.
- `candidates.rs:build_google_url`, `parse_google_response`, `CONNECT_TIMEOUT_MS`, and `REQUEST_TIMEOUT_MS` describe Google input-tools requests and 2,000 ms budgets.

## Invariants
- `candidates.rs:CloudCandidateState::update` increments generation even when disabled/invalid; at `u64::MAX` it clears input and refuses further requests instead of wrapping. `apply` rejects stale generations and empty/unbounded results.
- `candidates.rs:build_google_url` requires nonempty bounded input (256 bytes); response parsing permits at most 256 KiB and candidates at most 512 bytes.
- `candidates.rs:TranslationCache::get` expires negative entries using the supplied TTL; positive entries persist until capacity clearing. `remember` clears both maps at a combined 4,096 entries.

## Side Effects
- `candidates.rs:TranslationCache` and `CloudCandidateState` mutate memory and use monotonic time; network execution is supplied by callers.

## Verification
- From `rust/`: `cargo test -p msime-client-core`.
