# handwriting

## Overview

Offline handwriting recognition and provider candidate ordering.

## Interface

- [mod.rs:order_handwriting_candidates](./mod.rs) filters and partitions provider candidates; `contains_cjk`, `MAX_CANDIDATES`, `MAX_CANDIDATE_BYTES` define that boundary.
- [recognizer.rs:handwriting_recognize](./recognizer.rs) accepts a trusted packaged model path, strokes and canvas dimensions on non-Android targets.
- [features.rs:extract](./features.rs) and [model.rs:Model](./model.rs) are internal feature extraction and mapped-model scoring helpers.

## Invariants

- `order_handwriting_candidates` drops empty/over-4096-byte/duplicate entries, preserves order within CJK and other groups, and returns at most 12.
- `recognizer.rs:ink` validates finite positive canvas dimensions up to 10000, at most 64 strokes and 512 points per stroke; points must remain inside the canvas.
- `model.rs:Model::parse` rejects mismatched magic/version, truncation, invalid UTF-8 labels and trailing bytes.

## Side Effects

- `recognizer.rs:load` opens the model without following symlinks, maps it read-only and retains up to eight model paths behind a mutex/LRU; failed loads are not cached. The mapped file must be installed by replacement, not modified in place.

## Verification

From `rust/`: `cargo test -p msime-engine`. This is the existing crate test command, not a claim that tests were run during documentation bootstrap.
