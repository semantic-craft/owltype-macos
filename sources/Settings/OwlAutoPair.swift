//
//  OwlAutoPair.swift
//  法墨输入法 (Owltype) — 自动配对括号 pure decision layer (task 07-02)
//
//  中文模式下 commit 单个开括号 → 补全整对并把光标移到中间（对齐搜狗「标点配对」）；
//  commit 单个闭括号且光标右侧已是同一闭括号 → skip-over 跳过不重复插入。
//
//  This file is PURE value logic only — no IMK, no client reads, no UserDefaults. The
//  execution (insertText with replacementRange, the zero-permission right-neighbor read)
//  lives at the commit seam in `OwlInputController+RimeUpdate.swift`, mirroring how
//  `OwlCommitTransform` splits pure transform vs. controller side effects.
//
//  Boundary (ADR-0001 / 0002 / 0003): string/value transforms only when reached from the
//  IMK commit path — no disk IO, no YAML, no network, zero Rime config changes.
//

import Foundation

/// What the commit path should do with one committed string when 自动配对括号 is on.
/// Pure `Equatable` value so the decision is unit-testable without a client.
enum OwlAutoPairAction: Equatable {
  /// Not a pair-table hit (or the switch is off) — insert the commit text unchanged.
  case plain
  /// The commit is EXACTLY one opening char: insert `open + close` in one shot (content
  /// first — correct in every app), then, only when `caretMove` is true (bundle ID on the
  /// allowlist), best-effort self-replace the open char via `replacementRange` so the
  /// caret lands between the pair. Non-allowlisted apps degrade to "caret after the closer".
  case pair(open: String, close: String, caretMove: Bool)
  /// The commit is EXACTLY one closing char and the char right of the caret is that same
  /// closer: overwrite it (`insertText` with `replacementRange` over the neighbor) — the
  /// caret skips over instead of doubling the closer.
  case skipOver(close: String)
}

enum OwlAutoPair {
  /// 开→闭 static pair table (PRD D2: 括号全套 + 引号；成对输入扩展再加 ASCII 括号). Quotes need
  /// zero yaml changes: rime-ice's punctuator alternation (`"` → “ then ”) stays untouched —
  /// “/‘ count as openers here and ”/’ as closers, so alternation + skip-over cooperate naturally
  /// (first `"` yields “|”, the closing `"` after the content is swallowed by skip-over).
  ///
  /// ASCII 括号 `< ( [ {`（成对输入）：写 XML/代码时半角括号也自动闭合，典型路径是从 `<` 键的配对
  /// 候选菜单选出单个 ASCII 开括号后由本表补对。**直引号 `" ' \`` 故意不入表**：它们开==闭，会让
  /// 下面 `pairs[character]` 先命中而永远判成 opener，skip-over 再也触发不了（成对引号越滚越多）。
  static let pairs: [Character: Character] = [
    "（": "）",
    "【": "】",
    "《": "》",
    "〈": "〉",
    "「": "」",
    "『": "』",
    "〔": "〕",
    "“": "”",
    "‘": "’",
    "<": ">",
    "(": ")",
    "[": "]",
    "{": "}"
  ]

  /// All closing chars (the skip-over candidates).
  static let closers: Set<Character> = Set(pairs.values)

  /// The closing char of `text` iff text is EXACTLY one pair-table closer, else nil.
  /// The commit path calls this BEFORE reading the caret's right neighbor, so the client
  /// (IPC) read only happens when it could actually matter.
  static func singleCloser(in text: String) -> Character? {
    guard let character = text.first, text.count == 1, closers.contains(character) else { return nil }
    return character
  }

  /// Pure decision. Trigger rule v1 (PRD): the commit text must be EXACTLY one pair-table
  /// char — composed commits like 「你好（」 pass through untouched (`.plain`).
  static func decision(
    enabled: Bool,
    commitText: String,
    rightNeighbor: Character?,
    caretMoveAllowed: Bool
  ) -> OwlAutoPairAction {
    guard enabled, let character = commitText.first, commitText.count == 1 else { return .plain }
    if let close = pairs[character] {
      return .pair(open: String(character), close: String(close), caretMove: caretMoveAllowed)
    }
    if closers.contains(character), rightNeighbor == character {
      return .skipOver(close: String(character))
    }
    return .plain
  }
}
