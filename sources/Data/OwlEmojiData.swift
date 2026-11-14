//
//  OwlEmojiData.swift
//  法墨输入法 (Owltype) — 表情/符号面板 data
//
//  Curated glyph sets + search keywords, ported from the Claude Design "Owltype Emoji
//  Panel" handoff. NOTE: a fuller set sourced from rime-ice's emoji mapping is a
//  follow-up (tied to the self-contained config bundling, ADR-0004) — this starter set
//  makes the panel functional now. 「最近」 lives in UserDefaults.
//
//  Boundary (ADR-0001 / 0002 / 0003): pure data; no engine / hot-path involvement.
//

import Foundation

/// One pickable glyph. `wide` items (颜文字) take a full-width row; the rest tile in a grid.
struct OwlGlyph: Identifiable, Hashable, Sendable {
  let char: String
  let keywords: String
  let wide: Bool
  var id: String { char }
}

/// Panel categories (the top tabs). `recent` is backed by `OwlEmojiRecents`.
enum OwlEmojiCategory: String, CaseIterable, Identifiable, Sendable {
  case recent, emoji, symbol, kaomoji, punct
  var id: String { rawValue }

  var label: String {
    switch self {
    case .recent: return "最近"
    case .emoji: return "表情"
    case .symbol: return "符号"
    case .kaomoji: return "颜文字"
    case .punct: return "标点"
    }
  }

  var glyph: String {
    switch self {
    case .recent: return "🕘"
    case .emoji: return "😀"
    case .symbol: return "§"
    case .kaomoji: return "ツ"
    case .punct: return "《"
    }
  }
}

enum OwlEmojiData {
  struct WireGlyph: Decodable {
    let char: String
    let keywords: String
    let wide: Bool
  }

  /// Items for a fixed (non-recent) category.
  static func items(for category: OwlEmojiCategory) -> [OwlGlyph] {
    let wire: [WireGlyph] = OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "emoji_category_items",
      "args": ["category": category.rawValue]
    ])
    return wire.map { OwlGlyph(char: $0.char, keywords: $0.keywords, wide: $0.wide) }
  }

  /// Search across every category by char or keyword (case-insensitive).
  static func search(_ query: String) -> [OwlGlyph] {
    let wire: [WireGlyph] = OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "emoji_search",
      "args": ["query": query]
    ])
    return wire.map { OwlGlyph(char: $0.char, keywords: $0.keywords, wide: $0.wide) }
  }
}

/// 「最近」 store (UserDefaults). Seeded once with a sensible starter set; `push` moves a
/// pick to the front, dedupes, and caps the list. Returns the updated list so the view
/// can re-render without re-reading defaults.
enum OwlEmojiRecents {
  private static let key = "OwlEmojiRecent"
  private static let cap = 14
  private static let seed = ["😂", "❤️", "👍", "《》", "「」", "§", "—", "→", "🎉", "✓", "°", "…"]

  static func current() -> [String] {
    OwlDefaults.standard.stringArray(forKey: key) ?? seed
  }

  @discardableResult
  static func push(_ char: String) -> [String] {
    let list: [String] = OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "emoji_push_recent",
      "args": [
        "list": current(),
        "char": char,
        "cap": cap
      ]
    ])
    OwlDefaults.standard.set(list, forKey: key)
    return list
  }

  /// Recent items as glyphs (wide flag inferred from length, matching the design).
  static func glyphs() -> [OwlGlyph] {
    current().map { OwlGlyph(char: $0, keywords: "", wide: $0.count > 3) }
  }
}
