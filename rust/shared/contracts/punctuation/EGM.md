# Shared punctuation constants

## Overview
Generated C++ constants describe the shared punctuation mapping policy.

## Interface
- `policy.h:metasequoia::punctuation_contract` exports `version`, `Mapping`, `AlternatingMapping`, `simple`, `alternating`, `corner_quotes`, `hollow_brackets`, `enumeration_comma`, and nested-quote constants.
- `policy.h:is_supported`, `simple_output`, `alternating_mapping`, `corner_quote_mapping`, `hollow_bracket_output`, and `enumeration_comma_output` perform constexpr lookup.

## Invariants
- `policy.h:version` is 4; lookup functions return null for unmapped characters, except `is_supported`, which returns a boolean.
- `policy.h` identifies itself as generated from `policy.json`; the header is a generated contract, not the policy authoring source.

## Side Effects
- None. `policy.h` contains constexpr constants and read-only lookup functions.

## Verification
- From `rust/`: `cargo test -p msime-client-core` exercises the Rust consumer's punctuation rules. This does not compile the C++ header.
