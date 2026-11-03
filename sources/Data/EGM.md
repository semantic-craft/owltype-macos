# Emoji and symbol data

## Overview

Glyph/category values, fixed catalog access and recent-selection persistence used by the emoji panel.

## Interface

- `OwlGlyph` and `OwlEmojiCategory` define selectable text, keyword and category metadata. [OwlEmojiData.swift:OwlGlyph] [OwlEmojiData.swift:OwlEmojiCategory]
- `OwlEmojiData.items(for:)` and `search` dispatch `emoji_category_items` and `emoji_search` rules through `OwlAppCore`; local static catalogs are also declared. [OwlEmojiData.swift:OwlEmojiData]
- `OwlEmojiRecents.current`, `push` and `glyphs` expose the recent list, with a starter fallback. [OwlEmojiData.swift:OwlEmojiRecents]

## Invariants

- Glyph identity is its character string; recent glyphs use count greater than three to choose wide presentation. [OwlEmojiData.swift:OwlGlyph.id] [OwlEmojiData.swift:OwlEmojiRecents.glyphs]
- `push` passes a cap of 14 to the Rust `emoji_push_recent` rule; category/search/recent policy is resolved through `OwlAppCore.required`. [OwlEmojiData.swift:OwlEmojiRecents.push]

## Side Effects

- Reads and writes the OwlEmojiRecent defaults key when accessing/updating recents. [OwlEmojiData.swift:OwlEmojiRecents]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
