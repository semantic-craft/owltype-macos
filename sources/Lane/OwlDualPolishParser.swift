//
//  OwlDualPolishParser.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  A 5-tier cascading resilient parser for dual polish candidates (2 candidates)
//  and quick reply candidates (3 candidates).
//  Tier 1: Exact XML tags (<candidate_1>, <candidate_2>, <candidate_3>, <reply_1>...)
//  Tier 2: Tag variants (<candidate1>, <candidate 1>, markdown code fences)
//  Tier 3: Numbered lists (1. ..., 2. ..., 1、 ...)
//  Tier 4: Paragraph / newline separation
//  Tier 5: Invariant guarantees (strictly 2 for polish, strictly 3 for replies).
//

import Foundation

enum OwlDualPolishParser {

  // MARK: - Dual Polish Parsing (Exactly 2 Candidates)

  static func parse(raw: String, originalText: String) -> [String] {
    let sanitized = stripMarkdownFences(raw)
    var candidates: [String] = []

    // Tier 1: Exact XML tags (<candidate_1> and <candidate_2>)
    if let c1 = extractTagContent(from: sanitized, tag: "candidate_1"), !c1.isEmpty {
      candidates.append(c1)
    }
    if let c2 = extractTagContent(from: sanitized, tag: "candidate_2"), !c2.isEmpty {
      candidates.append(c2)
    }

    // Also check <reply_1> and <reply_2> if candidate tags were not found
    if candidates.isEmpty {
      if let c1 = extractTagContent(from: sanitized, tag: "reply_1"), !c1.isEmpty {
        candidates.append(c1)
      }
      if let c2 = extractTagContent(from: sanitized, tag: "reply_2"), !c2.isEmpty {
        candidates.append(c2)
      }
    }

    // Tier 2: XML tag variations (<candidate1>, <candidate 1>, <candidate-1>, etc.)
    if candidates.count < 2 {
      let variations = [
        ("candidate1", "candidate2"),
        ("candidate 1", "candidate 2"),
        ("candidate-1", "candidate-2"),
        ("reply1", "reply2"),
        ("reply 1", "reply 2"),
        ("reply-1", "reply-2")
      ]
      for (t1, t2) in variations {
        if candidates.isEmpty, let c1 = extractTagContent(from: sanitized, tag: t1), !c1.isEmpty {
          candidates.append(c1)
        }
        if candidates.count == 1, let c2 = extractTagContent(from: sanitized, tag: t2), !c2.isEmpty {
          candidates.append(c2)
        }
        if candidates.count == 2 { break }
      }
    }

    // Tier 3: Numbered list fallback (1. ..., 2. ..., 1、 ...)
    if candidates.count < 2 {
      let numbered = extractNumberedList(from: sanitized)
      for item in numbered where !candidates.contains(item) {
        candidates.append(item)
        if candidates.count == 2 { break }
      }
    }

    // Tier 4: Double-newline or clean lines
    if candidates.count < 2 {
      let cleanLines = sanitized.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasSuffix(">") }
      for line in cleanLines where !candidates.contains(line) {
        candidates.append(line)
        if candidates.count == 2 { break }
      }
    }

    // Tier 5: Invariant guarantee (strictly 2 distinct candidates)
    if candidates.count == 1 {
      let first = candidates[0]
      if first != originalText && !originalText.isEmpty {
        candidates.append(originalText)
      } else {
        candidates.append(first)
      }
    }

    if candidates.isEmpty {
      let fallback = originalText.isEmpty ? "（未能生成润色候选）" : originalText
      candidates = [fallback, fallback]
    }

    // Ensure distinctness if original text differs
    if candidates.count >= 2 && candidates[0] == candidates[1] && candidates[0] != originalText && !originalText.isEmpty {
      candidates[1] = originalText
    }

    return Array(candidates.prefix(2))
  }

  // MARK: - Reply Parsing (Exactly 3 Candidates)

  static func parseReplies(raw: String) -> [String] {
    let sanitized = stripMarkdownFences(raw)
    var candidates: [String] = []

    // Tier 1: Exact XML tags
    for tag in ["candidate_1", "candidate_2", "candidate_3", "reply_1", "reply_2", "reply_3"] {
      if let c = extractTagContent(from: sanitized, tag: tag), !c.isEmpty, !candidates.contains(c) {
        candidates.append(c)
        if candidates.count == 3 { break }
      }
    }

    // Tier 2: Tag variants (<candidate1>, <reply1>, etc.)
    if candidates.count < 3 {
      let variantTags = [
        "candidate1", "candidate2", "candidate3",
        "candidate 1", "candidate 2", "candidate 3",
        "candidate-1", "candidate-2", "candidate-3",
        "reply1", "reply2", "reply3",
        "reply 1", "reply 2", "reply 3",
        "reply-1", "reply-2", "reply-3"
      ]
      for tag in variantTags {
        if let c = extractTagContent(from: sanitized, tag: tag), !c.isEmpty, !candidates.contains(c) {
          candidates.append(c)
          if candidates.count == 3 { break }
        }
      }
    }

    // Tier 3: Numbered list fallback
    if candidates.count < 3 {
      let numbered = extractNumberedList(from: sanitized)
      for item in numbered where !candidates.contains(item) {
        candidates.append(item)
        if candidates.count == 3 { break }
      }
    }

    // Tier 4: Clean lines
    if candidates.count < 3 {
      let cleanLines = sanitized.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasSuffix(">") }
      for line in cleanLines where !candidates.contains(line) {
        candidates.append(line)
        if candidates.count == 3 { break }
      }
    }

    // Tier 5: Invariant guarantee (strictly 3 candidates)
    let defaultTemplates = [
      "好的，收到，完全赞同您的安排。",
      "收到，我已了解相关情况，稍后给您详细答复。",
      "感谢您的同步，如需任何协助我随时在此配合推进。"
    ]

    var defaultIdx = 0
    while candidates.count < 3 {
      let fallback = defaultTemplates[defaultIdx % defaultTemplates.count]
      if !candidates.contains(fallback) {
        candidates.append(fallback)
      } else {
        candidates.append("收到回复（选项 \(candidates.count + 1)）。")
      }
      defaultIdx += 1
    }

    return Array(candidates.prefix(3))
  }

  // MARK: - Internal Helpers

  static func extractTagContent(from text: String, tag: String) -> String? {
    // Matches <tag>...</tag> case-insensitive, including whitespace and newlines
    let escapedTag = NSRegularExpression.escapedPattern(for: tag)
    let pattern = "(?is)<\(escapedTag)>(.*?)</\(escapedTag)>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return nil
    }
    let nsText = text as NSString
    guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
      return nil
    }
    let range = match.range(at: 1)
    if range.location != NSNotFound {
      let content = nsText.substring(with: range)
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return nil
  }

  static func extractNumberedList(from text: String) -> [String] {
    var items: [String] = []
    // Matches: 1. / 1、 / (1) / 1) at line beginnings
    let pattern = "(?m)^(?:(?:[1-9][0-9]*[\\.\\、\\)])|(?:\\([1-9][0-9]*\\)))\\s*(.+)$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return []
    }
    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    for match in matches {
      let range = match.range(at: 1)
      if range.location != NSNotFound {
        let content = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
          items.append(content)
        }
      }
    }
    return items
  }

  static func stripMarkdownFences(_ text: String) -> String {
    guard text.contains("```") else { return text }

    // Outer envelope fence pattern:
    // Only strip markdown code fences if they wrap the entire envelope
    // (e.g. starts with ```[xml] and ends with ```).
    let envelopePattern = "^\\s*```(?:[a-zA-Z0-9_\\-]+)?\\s*\\r?\\n([\\s\\S]*)\\r?\\n?\\s*```\\s*$"
    if let regex = try? NSRegularExpression(pattern: envelopePattern, options: [.caseInsensitive]) {
      let nsText = text as NSString
      if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
        let range = match.range(at: 1)
        if range.location != NSNotFound {
          let inner = nsText.substring(with: range)
          if !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inner
          }
        }
      }
    }

    // If fences do not wrap the entire envelope, or if raw text contains internal code blocks,
    // do not perform fence stripping that could dismantle internal code fences.
    return text
  }
}
