# Mobile English correction

## Overview

This child module extends the parent English dictionary with bounded local correction and word segmentation. Its sibling files are regression fixtures and do not add production interfaces.

## Interface

- `[correction.rs:EnglishDictionary::correct_mobile_english]` returns one changed suggestion or `None`.
- `[correction.rs:CorrectionCache]` caches indexed prefix pages; `one_edit`, `neighbors`, `canonical`, and `protected` define edit candidates and preserved spellings.

## Invariants

- `[correction.rs:MAX_INPUT]`, `MAX_EDITS`, `MAX_WORDS`, `PREFIX_ROWS`, and `CACHE_PAGES` bound input to 32 bytes, edits to two, segmented words to six, queried pages to 128 rows and cache to 128 pages.
- `[correction.rs:correct_mobile_english]` accepts only ASCII letters/apostrophes, preserves explicit uppercase after the first character and protected abbreviations, and does not change an unchanged result. Canonical spellings can be restored without a database; other correction requires a ready dictionary and excludes apostrophe input.
- `[correction.rs:Path::better_than]` resolves candidates by cost, then edits/word count, then text. `one_edit` permits neighboring substitution, adjacent transposition, deletion, or insertion.

## Side Effects

- `[correction.rs:correction_page]` reads indexed parent dictionary pages and mutates the in-memory FIFO page cache. It does not persist learned words or contact a service.

## Verification

From `rust/`: `cargo test -p msime-engine dictionary::english`. No Rust build or tests were run for this documentation pass.
