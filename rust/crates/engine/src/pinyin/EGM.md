# Shared pinyin spelling and geometry

## Overview

Scheme-neutral syllable tables, cuts, fuzzy variants, typo candidates and glide decoding support both pinyin engines. The `autocorrect/`, `fuzzy/`, `glide/` and `typos/` children contain only tests; the table fixture is verification data.

## Interface

- `[syllables.rs:intact_pinyin_list]` fixes the ordered 421-syllable inventory; normalization helpers map dictionary umlaut aliases and outgoing cloud spelling.
- `[segment.rs:cut_pinyin_by_mode]` offers correction-aware and literal cuts; `is_complete_pinyin_input` performs the strict completeness check. `[graph.rs:build_syllable_graph]` and `enumerate_complete_segmentations` enumerate intact paths.
- `[normalize.rs:normalize_full_pinyin]` validates imported reading text against an optional expected syllable count. `[jianpin.rs:matches_mixed_segments]` and related helpers define abbreviated lookup predicates.
- `[active_helpcode.rs:detect_active_helpcode_length]` detects one/two trailing uppercase help letters over a complete base.
- `[fuzzy.rs:fuzzy_segmentations]`, `[autocorrect.rs:autocorrect_cut_kbest]` and `[typos.rs:syllable_typos]` supply distinct fuzzy, invalid-spelling correction and legal-to-legal typo paths.
- `[glide.rs:decode_glide]` produces geometric hypotheses; `rank_by_dictionary` reranks using one caller-supplied batch of weights.

## Invariants

- `[segment.rs:cut_one_piece_min_segments]` minimizes syllable count, breaking ties by shorter first pieces. Correction aliases have stable insertion priorities; correction paths and their Cartesian products cap at 32. Manual apostrophes delimit independently cut parts; strict completeness rejects empty parts.
- `[graph.rs:build_syllable_graph]` lists longest intact edges first and prunes unreachable tails. Graph enumeration is depth-first and caller-bounded; the shared default is 32.
- `[normalize.rs:normalize_full_pinyin]` strips ASCII whitespace and lowercases, rejects invalid delimiters/incomplete readings/count mismatches, and rejects alias corrections that would change the imported letters.
- `[jianpin.rs:matches_mixed_segments]` requires the same segment count; double initials match exactly. Quanpin single initials match first letters, while Shuangpin preserves the distinction between single and retroflex initials.
- `[fuzzy.rs:fuzzy_segmentations]` expands only intact syllables under enabled initial/final rules, includes the original during bounded beam expansion, and removes it from returned alternatives.
- `[autocorrect.rs:autocorrect_cut_kbest]` rejects zero limits, disabled types, empty input, apostrophes and inputs longer than 64 bytes. Paths contain 1–3 corrected edges and rank by correction count, weight, then arrival; duplicate syllable sequences collapse. Legal syllables are not correction keys; generated wrong keys are 3–6 letters. `correction_table` requires exactly one known type bit and panics otherwise.
- `[typos.rs:syllable_typos]` uses its own keyboard adjacency, canonicalizes legal variants, and retains the cheapest edit kind. `discounted` bounds the personal acceptance discount through a capped logarithm.
- `[glide.rs:decode_glide]` requires finite coordinates, positive finite keyboard dimensions and at least two points. Coordinates normalize by key dimensions; resampling caps at 128 points, hypotheses at 30 letters, and each sample keeps six prefixes within the beam. First/last letters align to stroke endpoints, with penalties for distance, bends/backtracking, skipped dwell and repeated letters. `rank_by_dictionary` considers at most eight intact splits per hypothesis and preserves cost/text ordering.

## Side Effects

- Lazy `OnceLock` tables retain syllables, aliases, correction indexes, typo variants and the glide trie in process memory. The module performs no direct SQLite or filesystem I/O; `rank_by_dictionary` invokes the supplied weight callback once.

## Verification

From `rust/`: `cargo test -p msime-engine pinyin`. This documentation pass did not execute the tests or a live glide gesture.
