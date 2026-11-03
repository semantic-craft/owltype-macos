# Real-dictionary probes

## Overview

Twenty-one executable examples exercise engine behavior against caller-provided staged dictionaries. They are command-line verification tools, not shipped host entry points. Each opens isolated temporary user/cache state through `host::prepare_options` and `Session`; assertions and returned errors make failed assumptions visible.

## Interface

Run from `rust/` with `cargo run -p msime-engine --example <name> -- <verified-resources>`. Each source defines its own `main` and required resource argument.

| Examples | Observed contract |
| --- | --- |
| `query_dictionary`, `schemes_dictionary` | Phrase commits, Han-edge selection, four double-pinyin profiles, Wubi/Japanese lookups, ü spellings, visible reading and initial-list expansion. |
| `learning_dictionary`, `phrase_creation_dictionary` | Learning survives session reopen, disabled learning writes nothing, reset restores order, partial/generated/injected-online sentences persist under discoverable canonical readings. |
| `frequency_dictionary`, `frequency_modes_dictionary`, `frequency_comparison_set_dictionary` | Trigger threshold, persistent rank changes, distinct disabled/pin/halve/linear/promote policies, weight-order comparison across segmentation groups. |
| `alternative_segmentation_dictionary`, `quanpin_autocorrect_dictionary`, `google_umlaut_dictionary`, `lattice_reading_dictionary` | Alternative reading visibility, correction-cost ordering, ü decoder spelling and rejection of incorrect rare-reading sentences. |
| `mixed_dictionary`, `mixed_input_dictionary`, `mixed_ordering_dictionary` | Independent English/emoji/kaomoji switches, positive/negative prefix thresholds and relative source ordering. |
| `local_modes_dictionary`, `helpcode_dictionary`, `word_to_character_dictionary` | Local-mode entry gates and commits, one/two-code help filtering, first/last Han extraction and declined-selection state. |
| `ninekey_dictionary`, `ninekey_latency` | Ngram presence and changed sentence ranking; per-digit `character` plus `snapshot` latency distribution by position. |
| `symbol_candidates_dictionary`, `number_symbols_dictionary` | Symbol discovery/anchoring, absence from first place, numeric-symbol commit and toggle behavior across quanpin/double-pinyin/nine-key. |

## Invariants

- The resource argument is canonicalized but these executables do not independently verify a release lock/checksum. “Verified resources” is a caller precondition; exact ranks, words and counts intentionally depend on that dictionary generation.
- Mutable user/cache paths are always inside `tempfile::TempDir`. Reopening a session against the same temporary store is deliberate in learning/frequency probes; separate temporary stores isolate negative cases.
- `helpcode_dictionary` accepts an optional second helpcode-directory argument, otherwise derives a repository-relative default. It requires tables in either location and builds a temporary resource view; dictionary-only staging may lack these assets.
- `ninekey_dictionary` requires both `msime-bigram.bin` and `msime-trigram.bin`, constructs a view excluding them and asserts that candidate order changes. It does not claim a fixed winning sentence.
- `ninekey_latency` reads `NINEKEY_ROUNDS` (default 20), excludes round zero from samples and reports p50/p95/max. It asserts candidates/complete commits, but imposes no latency acceptance threshold; zero/one rounds yield no timed report.
- `phrase_creation_dictionary` injects a synthetic online candidate with `apply_online_candidate`; this is not a live AI request. `number_symbols_dictionary` checks source 6 when mixing is disabled, permitting independently packaged symbol rows. `symbol_candidates_dictionary` reports distant/missing anchors as diagnostics and only its explicit failure conditions fail the process.

## Side Effects

Examples stage/read resource files, create and remove temporary databases/cache directories, write temporary learning/ranking state where enabled, and print candidate/latency diagnostics. `learning_dictionary` resets only its temporary learned store. Helpcode and unweighted nine-key views create filesystem symlinks; missing helpcode tables are copied into the temporary view. None of these mains sends an external provider request.

## Verification

All 21 source files (2461 lines) were read for this contract. No examples, builds or tests were run as part of the documentation bootstrap. Source coverage does not establish dictionary, native-host or performance acceptance.
