# Wubi schemes and dictionary queries

## Overview

Wubi 86/98 key composition, fourteen-key grid expansion, dictionary lookup, reverse coding and frequency hints. The session coordinates pinyin lookup/mixing and commit actions; this directory supplies scheme/provider behavior.

## Interface

- [scheme.rs](scheme.rs): `WubiScheme` retains raw keys, mixed/pinyin-lookup permissions, wildcard mode and optional grid keys; `handle_key` accepts `SchemeKey`, and `build_request_into` publishes a `QueryRequest`.
- [grid.rs](grid.rs): grid-key mapping and `expand_into` produce sorted Cartesian expansions. [code.rs](code.rs): `phrase_code` constructs phrase codes through a caller-supplied character-code lookup.
- [provider.rs](provider.rs): `WubiProvider` lazily opens its dictionary, changes 86/98 profiles, queries keys/grid expansions and provides `reverse_code_into`. `ensure_reverse_indexes` installs reverse-value indexes on a caller-provided writable connection.
- [frequency.rs](frequency.rs): `WubiFrequency` reads pinyin frequency hints for ranking grid alternatives. [lookup.rs](lookup.rs): `lookup_codes` returns bounded reverse codes for Han characters and an eligible whole phrase.

## Invariants

- Ordinary Wubi composition is at most four keys; mixed or explicit pinyin-lookup mode permits up to 32. `z` is accepted only in the modes that allow it. Grid mode is chosen by the first key, cannot mix grid and hardware-letter input, and has at most four keys; its ZX key represents `x`, not a wildcard. `expand_into` itself does not impose the scheme's length cap.
- `phrase_code` uses first two codes from each of two characters, one/one/two for three, and first codes of the first three plus the last character for longer phrases. A needed prefix must consist of lowercase ASCII letters. Zero/one-character input has no phrase code; an unusable required character is reported distinctly.
- Provider queries cap results at 50, place exact codes first and retain distinct code/word rows rather than deduplicating all equal text. Wildcard `z` becomes a safely escaped GLOB pattern. Grid exact-code groups use pinyin frequency hints while preserving table order within each code; longer completions follow.
- Read-only connection failures yield empty results and release the failed connection for later retry. Reverse lookups prefer longer codes, then weight/key/row order, and cache successes and misses in a 1024-entry LRU; profile changes clear reverse state.
- `WubiFrequency` shares at most four path-keyed character tables and caps its own phrase cache at 4096. Phrase hints inspect at most seven characters and at most 16 initial combinations. A busy partial character scan is not published globally; the instance can retain it. Reset clears its connection/phrase cache while retaining its character table.
- `lookup_codes` returns at most eight codes per table, short codes first, for at most 64 distinct Han characters in first-occurrence order. It marks character truncation and only attempts a whole-Han phrase of 2–16 characters. Missing data returns empty code lists without modifying session/user state.

## Side Effects

Provider and frequency queries lazily open read-only/no-follow SQLite connections, populate bounded caches and close connections on reset/failure. `ensure_reverse_indexes` is the explicit write exception: it creates absent value indexes for existing Wubi tables using the supplied connection. No network requests or user-learning writes originate here.

## Verification

From `rust/`: `cargo test -p msime-engine wubi::`. All production bodies were read; test-only bodies were excluded. No tests were executed during this documentation bootstrap.
