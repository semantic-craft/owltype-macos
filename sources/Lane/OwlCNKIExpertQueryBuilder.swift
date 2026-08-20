//
//  OwlCNKIExpertQueryBuilder.swift
//  猫头鹰输入法 (Owltype) — 知网专业检索式构造器 (issue #133)
//
//  1:1 移植自 Responsay `CNKIExpertQueryBuilder.swift`（其源头是 opencli-stack
//  academic-search 的 buildCnkiProfessionalExpr，已对真实 CNKI 验证）。
//
//  知网「专业检索」页 kns.cnki.net/kns8s/AdvSearch **无 GET 参数**：检索式由输入法生成、
//  复制到剪贴板、用户粘贴进页面文本框（配套 toast 文案见 #135）。这是知网组的第二入口；
//  第一入口是带词直达 `?kw=`（OwlVerificationQueryRouter）。
//    · 字段码：SU 主题 / TI 题名 / AU 作者 / AB 摘要 / KY 关键词 / LY 文献来源(期刊)
//    · 匹配算符（按字段）：SU → %=（相关匹配，官方推荐）；TI/AB → %（包含）；其余 → =
//    · 同字段多词用「 * 」(逻辑与) 组合；字段间用 AND/OR/NOT（前后空格）
//    · 检索词用英文单引号括起；词内单引号 ' 转义为 ''（保住引号配对）
//

import Foundation

enum OwlCNKIExpertQueryBuilder {

  /// 知网专业检索页（打开后把检索式粘进文本框，URL 不带检索参数）。
  static let professionalSearchURL = URL(string: "https://kns.cnki.net/kns8s/AdvSearch")!

  /// 拆解后的检索输入。裸主题 → SU；学术引注可带作者/期刊，分别路由到 AU/LY。
  struct Input: Sendable, Equatable {
    var query: String
    var author: String?
    var journal: String?      // 多个期刊用 '+' 分隔
    var field: String         // SU / TI / AU / AB / KY / DOI（默认 SU）

    init(query: String, author: String? = nil, journal: String? = nil, field: String = "SU") {
      self.query = query
      self.author = author
      self.journal = journal
      self.field = field
    }
  }

  /// 裸检索词便捷入口。
  static func build(query: String) -> String { build(Input(query: query)) }

  static func build(_ input: Input) -> String {
    let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return "" }

    var parts = [fieldExpr(field: normalizeField(input.field), query: query)]

    if let author = input.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
      parts.append("AU = '\(escape(author))'")
    }

    if let journal = input.journal?.trimmingCharacters(in: .whitespacesAndNewlines), !journal.isEmpty {
      let journals = journal.split(separator: "+").map { escape(String($0)) }.filter { !$0.isEmpty }
      if journals.count == 1 {
        parts.append("LY = '\(journals[0])'")
      } else if journals.count > 1 {
        parts.append("(" + journals.map { "LY = '\($0)'" }.joined(separator: " OR ") + ")")
      }
    }

    return parts.joined(separator: " AND ")
  }

  // MARK: - Internals

  /// CNKI 专业检索用 '' 表示词内单引号（SQL 式转义）。
  static func escape(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "'", with: "''")
  }

  /// 单字段检索式。SU→%=；TI/AB→%；其余→=。多词用「 * 」组合。
  static func fieldExpr(field: String, query: String) -> String {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let escaped = escape(value)
    let terms = value.split(whereSeparator: { $0.isWhitespace })
      .map { escape(String($0)) }
      .filter { !$0.isEmpty }

    let op: String
    switch field {
    case "SU": op = "%="
    case "TI", "AB": op = "%"
    default: op = "="
    }

    guard ["SU", "TI", "AB"].contains(field), terms.count > 1 else {
      return "\(field) \(op) '\(escaped)'"
    }
    return "\(field) \(op) " + terms.map { "'\($0)'" }.joined(separator: " * ")
  }

  private static let knownFields: Set<String> = ["SU", "TI", "AU", "AB", "KY", "DOI"]

  static func normalizeField(_ type: String) -> String {
    let key = type.trimmingCharacters(in: .whitespaces).uppercased()
    return knownFields.contains(key) ? key : "SU"
  }
}
