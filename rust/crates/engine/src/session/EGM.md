# Input session

## Overview

Stateful input composition, candidate overlays, selection and learning above the scheme engine. The host supplies events and applies returned commits; online responses enter through request matching rather than network calls here.

## Interface

- [mod.rs:Session](./mod.rs) owns the engine, runtime paths, composition, candidate and online state; [options.rs:SessionOptions](./options.rs) supplies session options.
- [input.rs](./input.rs) routes keys, scheme changes, local modes, raw commits and URL completion. [editing.rs](./editing.rs), [composition.rs](./composition.rs) and [conversion.rs](./conversion.rs) implement caret editing, composition views and conversion selection.
- [candidates.rs](./candidates.rs) assembles visible rows and handles pinning, fixed positions and removal; [commit.rs](./commit.rs) commits selections and preserves partial composition.
- [online.rs](./online.rs) creates and matches online requests and installs responses; [plugin_commands.rs](./plugin_commands.rs) handles command responses.
- [learning.rs](./learning.rs) persists selection/phrase/context learning; [chain.rs](./chain.rs) and [clock.rs](./clock.rs) bound temporal continuity. [prediction.rs](./prediction.rs) produces explicit post-commit predictions.
- [literal.rs](./literal.rs), [glide.rs](./glide.rs) and [helpcode_entry.rs](./helpcode_entry.rs) preserve literal input, glide handling and helpcode entry behavior.

## Invariants

- `Session` requires serialized access to the same session; independent sessions have separate composition state. Scheme, dedicated-English and local-mode paths decide which input rules apply (`input.rs`).
- The engine's ranking order and the displayed mixed candidate order remain distinct; learning uses the producing dictionary and canonical reading, not a candidate's final screen slot (`candidates.rs`, `learning.rs`).
- Online response application compares live session/request generation and query state; stale responses cannot replace a newer composition (`online.rs`). Placeholder rows do not commit answer text (`commit.rs`).
- URL scheme/TLD completion can continue composition instead of committing; raw Enter preserves typed text, with the explicit helpcode/Wubi lookup exceptions in `raw_commit_text` and `commit_raw` (`input.rs`).
- `is_editable_source` excludes read-only language dictionary rows from personal pin/delete operations. Fixed positions use slots 1–5; removal rejects single-character non-English entries (`input.rs`, `candidates.rs`).
- Post-commit predictions require explicit selection and are bounded to eight rows; enabling prediction does not make space, Enter or focus loss automatically insert a prediction (`prediction.rs`, `input.rs`).
- Learning failures are returned as diagnostics alongside the commit; committed text is not discarded because persistence failed (`learning.rs`, `commit.rs`).

## Side Effects

- Reads dictionaries, helpcode tables and personal state through the engine and user-dictionary modules. Selection, ranking and removal can write user journals and working dictionaries (`learning.rs`, `candidates.rs`).
- Mutates session composition/candidate caches and invalidates pending online requests on relevant edits (`input.rs`, `online.rs`). Online transport and host insertion are outside this directory.
- Expression-mode configuration can warm unit definitions in the background (`input.rs:set_local_mode_options`).

## Verification

From `rust/`: `cargo test -p msime-engine`. Tests were not executed as part of this documentation bootstrap.
