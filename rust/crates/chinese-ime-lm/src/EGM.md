# Character language model and reranker

## Overview
Loads in-memory safetensors weights and scores Chinese candidate strings with a character-level transformer. The engine supplies comparability/trust facts; the model does not infer them from text.

## Interface
- `lib.rs:SentenceModel::load`, `score`, `next_log_probabilities`, `token`, `context_length`, `attribution`, and `license` expose loading, scoring, vocabulary lookup, and weight provenance.
- `lib.rs:Reranker::new`, `model`, `best`, `best_where`, and `log_probabilities` add per-session prefix/candidate-state reuse around shared `Arc<SentenceModel>` weights.
- `lib.rs:CandidateFacts` carries `answers_key` and `trusted_dictionary_hit`; `DICTIONARY_SOURCES` and `should_rerank` provide the legacy source-code heuristic. `ModelError` reports truncated/header/metadata/tensor/geometry failures.
- `weights.rs:Weights` and `Tensor` are internal to the private `weights` module, not exported crate APIs.

## Invariants
- `lib.rs:comparable` declines reranking if the leader does not answer the key, is a trusted dictionary hit, or fewer than two comparable candidates exist; it considers at most nine candidates answering the key.
- `lib.rs:Reranker::best_where` compares mean log probability per scored token and returns the original candidate index only when a later candidate wins strictly. `best` uses character count and source codes as proxies; correcting engines must supply explicit facts via `best_where`.
- `lib.rs:Reranker::score_indices_into` keys cached prefixes on encoded/truncated context and clears prior tail reuse when that prefix changes. Reuse state belongs to the reranker, not shared model weights.
- `weights.rs:Weights::parse` uses checked header-size/shape arithmetic, validates tensor lengths, supports F32/F16/I8, and requires row scales for I8. Quantized matrices retain i8 storage; `Matrix::dot_row` applies a scale per output row.
- `lib.rs:SentenceModel::load` checks bounded dimensions, nonzero embedding/head counts, head divisibility, vocabulary count and expected matrix geometry. `license` may be empty when weights omit metadata; it does not imply a weights license.

## Side Effects
- `lib.rs:Reranker` mutates in-memory prefix, tail and scratch caches; internal `OnceLock` values cache hidden-state normalization and terminal continuation. `SentenceModel::load` consumes supplied bytes and performs no disk or network I/O.

## Verification
- From `rust/`: `cargo test -p chinese-ime-lm`. Model quality and host latency need their own evaluation inputs; unit tests alone do not establish them.
