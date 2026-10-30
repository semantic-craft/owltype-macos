//
//  OwlEmojiData.swift
//  猫头鹰输入法 (Owltype) — 表情/符号面板 data
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
  static let emoji: [OwlGlyph] = [
    g("😀", "smile 笑 开心"), g("😄", "笑 happy"), g("😁", "grin"), g("😂", "laugh 笑哭 哭笑"),
    g("🤣", "rofl 大笑"), g("😊", "smile 微笑"), g("🙂", "slight"), g("😉", "wink 眨眼"),
    g("😍", "love 爱 心 喜欢"), g("😘", "kiss 亲"), g("😎", "cool 酷"), g("🤩", "star 星星眼"),
    g("🥳", "party 庆祝"), g("😏", "smirk"), g("😴", "sleep 睡"), g("🤔", "think 思考"),
    g("😭", "cry 哭"), g("😅", "sweat"), g("😡", "angry 生气"), g("🥺", "plead 委屈"),
    g("👍", "thumbsup 赞 好 顶"), g("👎", "thumbsdown 踩"), g("👏", "clap 鼓掌"), g("🙏", "pray 拜托 谢谢"),
    g("💪", "muscle 加油"), g("🤝", "handshake 握手"), g("❤️", "heart 心 爱"), g("🧡", "orange heart"),
    g("💛", "yellow heart"), g("💚", "green heart"), g("💙", "blue heart"), g("💜", "purple heart"),
    g("🔥", "fire 火 热"), g("✨", "sparkle 闪"), g("🎉", "party 庆祝 撒花"), g("🎊", "confetti"),
    g("⭐", "star 星"), g("💯", "hundred 满分 百分"), g("✅", "check 对"), g("❌", "cross 错"),
    g("💡", "idea 灯泡"), g("🚀", "rocket 火箭")
  ]

  static let symbol: [OwlGlyph] = [
    g("×", "times 乘 叉"), g("÷", "divide 除"), g("±", "plusminus 正负"), g("∓", ""),
    g("°", "degree 度"), g("′", ""), g("″", ""), g("µ", "micro"),
    g("§", "section 节 章节"), g("¶", "pilcrow 段落"), g("→", "arrow 箭头 右"), g("←", "arrow 左"),
    g("↑", "上"), g("↓", "下"), g("↔", ""), g("⇒", "implies"),
    g("★", "star 星 实心"), g("☆", "star 星 空心"), g("♥", "heart 心"), g("♦", ""),
    g("♣", ""), g("♠", ""), g("✓", "check 对勾"), g("✗", "cross"),
    g("∞", "infinity 无穷"), g("≈", "approx 约"), g("≠", "neq 不等"), g("≤", "leq"),
    g("≥", "geq"), g("√", "root 根号"), g("∑", "sum 求和"), g("∫", "integral 积分"),
    g("π", "pi"), g("Ω", "omega"), g("©", "copyright 版权"), g("®", "registered"),
    g("™", "trademark 商标"), g("№", "number 编号"), g("‰", "permille 千分"), g("†", "dagger")
  ]

  static let kaomoji: [OwlGlyph] = [
    w("(๑•́ ₃ •̀๑)", "撇嘴 委屈"), w("¯\\_(ツ)_/¯", "耸肩 摊手 shrug"),
    w("(╯°□°)╯︵ ┻━┻", "掀桌 flip"), w("┬─┬ ノ( ゜-゜ノ)", "摆正 putback"),
    w("(´；ω；｀)", "哭 cry"), w("(≧▽≦)", "开心 happy"), w("(＾▽＾)", "笑 smile"),
    w("(╥﹏╥)", "大哭"), w("(ಠ_ಠ)", "无语 disapprove"), w("ʕ•ᴥ•ʔ", "熊 bear"),
    w("(☞ﾟヮﾟ)☞", "指 point"), w("(◍•ᴗ•◍)", "可爱 cute"), w("(｀・ω・´)", "认真"),
    w("(ノ°▽°)ノ︵", "撒"), w("σ(￣、￣〃)", "思考"), w("(*/ω＼*)", "害羞 shy")
  ]

  static let punct: [OwlGlyph] = [
    g("《》", "书名号 shumihao"), g("「」", "引号 quote"), g("『』", "引号 双书名"), g("【】", "方头括号"),
    g("（）", "括号 paren"), g("〈〉", "尖括号"), g("—", "破折号 dash"), g("…", "省略号 ellipsis"),
    g("§", "节 section"), g("¶", "段落 paragraph"), g("、", "顿号"), g("；", "分号 semicolon"),
    g("：", "冒号 colon"), g("·", "间隔号 middot"), g("※", "参考 reference"), g("～", "波浪 tilde"),
    g("‖", "双竖线"), g("＂", "引号"), g("•", "项目符号 bullet"), g("‹›", "单尖括号"),
    g("«»", "法文引号"), g("¡", "倒叹号"), g("¿", "倒问号"), g("℃", "摄氏度")
  ]

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

  private static func g(_ char: String, _ keywords: String) -> OwlGlyph {
    OwlGlyph(char: char, keywords: keywords, wide: false)
  }
  private static func w(_ char: String, _ keywords: String) -> OwlGlyph {
    OwlGlyph(char: char, keywords: keywords, wide: true)
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
