# Quanpin cached candidate pages

## Overview

Two production helpers store and copy pages for the parent dictionary. Other files in this directory are test modules referenced under `cfg(test)`.

## Interface

- `[path_page.rs:PathPage]` stores an empty page, complete `WordItem` rows, or compact dictionary rows; `copy_rows`, `append_to` and `cloned_rows` reconstruct identical candidates.
- `[page_copy.rs:clone_rows_reusing]` clones a page while selectively reusing an evicted page's allocations.

## Invariants

- `[path_page.rs:from_dictionary]` compacts only sufficiently large ordinary Quanpin database pages with a shared nonempty consumed reading. Fixed positions, fuzzy/corrected/sentence metadata or other sources/schemes require full rows. Canonical keys, words and weights remain per-row.
- `[path_page.rs:ordinary_row]` exhaustively destructures `WordItem`, making added fields require an explicit compression decision. `ClonedRows` implements exact-size iteration in stored order.
- `[page_copy.rs:clone_vec_reusing]` and string-copy helpers reuse only capacities equal to the new source length, avoiding retained oversized allocations. `clone_row_reusing` copies every candidate field and recursively handles sentence words.

## Side Effects

These helpers allocate, copy and reuse process memory. They perform no I/O, persistence or candidate reordering.

## Verification

From `rust/`: `cargo test -p msime-engine quanpin::dictionary`. This documentation pass read both production helpers; it did not run tests.
