//
//  OwlVerificationAnchors.swift
//  猫头鹰输入法 (Owltype) — 来源核验锚点数据层：坐标抽取 + 案号准入闸 (issue #134)
//
//  1:1 移植自 Responsay `VerificationAnchor.swift` / `FactCoordinateExtractor.swift` /
//  `CaseNumberVerifier.swift`（主线仓 docs/owl-responsay-alignment-spec.md）。
//  本地确定性抽取（正则 + 小词表），不依赖 LLM；抽出的锚点一律 `.pending`（[待核]）。
//  铁律：搜不到 ≠ 不存在——本层永不产出 `.rejected`，判驳只能来自用户显式操作。
//

import Foundation

// MARK: - 锚点状态与徽标

enum OwlVerificationStatus: String, Codable, Sendable {
  case pending             // [待核]
  case verifiedLaw         // [法条-已核]
  case verifiedCase        // [案例-已核]
  case scholarlyReference  // [学理-参考]
  case userConfirmed       // [用户确认]
  case rejected            // 仅用户显式判驳
}

/// UI 呈现用的三态归并；tag 文案逐字对齐 Responsay `VerificationOutcome`。
enum OwlVerificationOutcome: String, Codable, Sendable, CaseIterable {
  case pending
  case verified
  case rejected

  var tag: String {
    switch self {
    case .pending: return "[待核]"
    case .verified: return "[已核]"
    case .rejected: return "[已驳]"
    }
  }

  init(_ status: OwlVerificationStatus) {
    switch status {
    case .pending: self = .pending
    case .rejected: self = .rejected
    case .verifiedLaw, .verifiedCase, .scholarlyReference, .userConfirmed: self = .verified
    }
  }
}

extension OwlVerificationKind {
  /// 锚点行的 kind 徽标文案（对齐 Responsay 待核清单）。
  var badgeLabel: String {
    switch self {
    case .law: return "法条"
    case .caseLaw: return "案例"
    case .administrativeRule: return "法规"
    case .standard: return "标准"
    case .scholarlyArticle: return "文献"
    case .officialDocument: return "文件"
    case .date: return "日期"
    case .money: return "金额"
    case .other: return "其他"
    }
  }
}

/// 已确认来源，仅在状态离开 `.pending` 后出现。
struct OwlVerifiedAnchorSource: Codable, Sendable, Equatable {
  let title: String
  let url: String
  let accessedAt: String
  let provider: String
  let snippet: String?
}

struct OwlVerificationAnchor: Codable, Sendable, Identifiable, Equatable {
  let id: String
  let label: String          // 如 "《民法典》第五百七十七条" / "GB/T 39335"
  let kind: OwlVerificationKind
  var status: OwlVerificationStatus
  let query: String
  let preferredSources: [OwlVerificationSource]
  var source: OwlVerifiedAnchorSource?

  init(id: String, label: String, kind: OwlVerificationKind,
       status: OwlVerificationStatus = .pending, query: String,
       preferredSources: [OwlVerificationSource] = [],
       source: OwlVerifiedAnchorSource? = nil) {
    self.id = id
    self.label = label
    self.kind = kind
    self.status = status
    self.query = query
    self.preferredSources = preferredSources
    self.source = source
  }
}

// MARK: - 本地坐标抽取器（正则 + 小词表，确定性，无 LLM）

enum OwlFactCoordinateExtractor {

  /// 「什么算数字」的唯一定义（含中文数字），供法条条号匹配。
  static let numeralClass = "0-9〇零一二三四五六七八九十百千两"

  /// 对文本抽出全部待核锚点：按 label 去重、首见有序、一律 `.pending`。
  static func extract(from text: String) -> [OwlVerificationAnchor] {
    guard !text.isEmpty else { return [] }
    var seen = Set<String>()
    var anchors: [OwlVerificationAnchor] = []
    for rule in rules {
      for raw in matches(of: rule.pattern, in: text) {
        var label = normalize(raw)
        if rule.kind == .officialDocument { label = stripLeadIn(label) }
        guard label.count >= rule.minLength, !seen.contains(label) else { continue }
        seen.insert(label)
        anchors.append(OwlVerificationAnchor(
          id: "\(rule.kind.rawValue):\(label)",
          label: label,
          kind: rule.kind,
          status: .pending,
          query: label,
          preferredSources: rule.sources))
      }
    }
    return anchors
  }

  private struct Rule {
    let kind: OwlVerificationKind
    let pattern: String
    let minLength: Int
    let sources: [OwlVerificationSource]
  }

  private static let articleNumber = "[\(numeralClass)]+"

  private static let rules: [Rule] = [
    // 法条号: 《X》（修订年）第N条（之N）（第N款）（第N项） — 容忍空格（"《个保法》第 24 条"）。
    Rule(kind: .law,
         pattern: "《[^》]{1,40}》(?:[（(]\\d{4}年[^）)]{0,12}[)）])?第\\s*\(articleNumber)\\s*条(?:之\\s*\(articleNumber))?(?:第\\s*\(articleNumber)\\s*款)?(?:第\\s*[（(]?\\s*\(articleNumber)\\s*[)）]?\\s*项)?",
         minLength: 4, sources: [.govLaw, .pkulaw]),
    // 指导案例: 指导案例24号 / 指导案例第24号 — 无年份圆括号，独立规则。
    Rule(kind: .law,
         pattern: "指导案例(?:第)?\\s*\\d+\\s*号",
         minLength: 5, sources: [.pkulaw, .qwenSearch]),
    // 规范性文件号: 国发〔2007〕19号、法释〔2018〕1号 — 六角括号区别于案号的圆括号。
    Rule(kind: .officialDocument,
         pattern: "[一-龥]{1,8}〔\\s*\\d{4}\\s*〕\\s*\\d+\\s*号",
         minLength: 5, sources: [.govLaw, .pkulaw]),
    // 案号: (2021)京01民终1234号 — 圆括号（含半角）；六角括号也兜底（部分来源误用）。
    Rule(kind: .caseLaw,
         pattern: "[(（〔]\\s*\\d{4}\\s*[)）〕][^\\s，。；,.；]{2,24}?号",
         minLength: 8, sources: [.pkulaw, .qwenSearch]),
    // 标准号: GB/T 39335-2020, ISO 27001
    Rule(kind: .standard,
         pattern: "(?:GB(?:/T)?|JR/T|YD/T|ISO|IEC)\\s*\\d+(?:[\\-—.]\\d+)*",
         minLength: 4, sources: [.govLaw, .qwenSearch]),
    // 日期: 2021年1月1日 / 2021-01-01
    Rule(kind: .date,
         pattern: "\\d{4}\\s*年\\s*\\d{1,2}\\s*月\\s*\\d{1,2}\\s*日|\\d{4}-\\d{1,2}-\\d{1,2}",
         minLength: 6, sources: [.manual]),
    // 金额: 10万元 / ￥1,200.50 / 5000元
    Rule(kind: .money,
         pattern: "(?:￥|¥)\\s*\\d[\\d,]*(?:\\.\\d+)?|\\d[\\d,]*(?:\\.\\d+)?\\s*(?:万|亿)?\\s*元",
         minLength: 2, sources: [.manual]),
  ]

  private static func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }

  /// 合并内部空白："《个保法》第 24 条" → "《个保法》第24条"。
  static func normalize(_ raw: String) -> String {
    raw.components(separatedBy: .whitespacesAndNewlines).joined()
  }

  // 长词优先：先剥「依据」再剥「依/据」，先「参见」再「见」。
  private static let docLeadIns = ["依据", "根据", "参见", "按照", "依照", "适用", "载于",
                                   "见", "据", "依", "按", "载"]

  /// 剥掉文件号正则可能吞进的常见引导词（中文无词边界，"依据国发〔2007〕19号" → "国发〔2007〕19号"）。
  static func stripLeadIn(_ s: String) -> String {
    for w in docLeadIns where s.hasPrefix(w) { return String(s.dropFirst(w.count)) }
    return s
  }
}

// MARK: - 案号准入闸（案例锚点进入展示/报告前必过）

enum OwlCaseType: Sendable, Equatable {
  case criminalFirstInstance       // 刑初
  case criminalSecondInstance      // 刑终
  case civilFirstInstance          // 民初
  case civilSecondInstance         // 民终
  case administrativeFirstInstance // 行初
  case execution                   // 执
  case caseLibrary                 // 入库编号
}

enum OwlCaseNumberStatus: Sendable, Equatable {
  case complete            // ✅ 可提取且格式正确
  case partial             // ⚠️ 有类型标记但缺年份/完整编号（截断）
  case missing             // ❌ 完全无案号信号
  case suspectedFabricated // ❓ 形似案号但格式不符规范（常见于 AI 杜撰）
}

enum OwlCaseNumberDisposition: Sendable, Equatable {
  case admit                       // 准入
  case attemptCompleteElseDiscard  // 尝试补全，失败则废弃
  case discard                     // 废弃
}

struct OwlCaseNumber: Sendable, Equatable {
  let raw: String
  let year: Int
  let courtCode: String   // 法院代字，如 皖1702 / 粤03
  let caseType: OwlCaseType
  let sequence: Int
}

struct OwlCaseNumberVerdict: Sendable, Equatable {
  let caseNumber: OwlCaseNumber?
  let status: OwlCaseNumberStatus

  var disposition: OwlCaseNumberDisposition {
    switch status {
    case .complete: return .admit
    case .partial: return .attemptCompleteElseDiscard
    case .missing, .suspectedFabricated: return .discard
    }
  }
}

/// 纯函数：提取 → 格式校验 → 三重分类（+❓疑似虚构）→ 处置。
struct OwlCaseNumberVerifier: Sendable {
  let currentYear: Int

  func verify(_ text: String) -> OwlCaseNumberVerdict {
    let shapes = fullShapeMatches(in: text)
    if let valid = shapes.first(where: { $0.yearValid }) {
      return OwlCaseNumberVerdict(caseNumber: valid.cn, status: .complete)
    }
    if !shapes.isEmpty {
      // 完整形状存在但无一年份合法 = 格式不符规范 → 疑似虚构。
      return OwlCaseNumberVerdict(caseNumber: nil, status: .suspectedFabricated)
    }
    if Self.hasPartialStem(in: text) {
      return OwlCaseNumberVerdict(caseNumber: nil, status: .partial)
    }
    if Self.hasSuspectShape(in: text) {
      return OwlCaseNumberVerdict(caseNumber: nil, status: .suspectedFabricated)
    }
    return OwlCaseNumberVerdict(caseNumber: nil, status: .missing)
  }

  /// ❓ 形似案号但既非合法完整、也非真词干：`(YYYY)<连续非标点串>号` 的壳（类型字编造）。
  private static func hasSuspectShape(in text: String) -> Bool {
    let pattern = "[（(]\\d{4}[）)][^\\s。，、；：（）()]{1,18}号"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    let ns = text as NSString
    return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
  }

  /// ⚠️ 部分：有「代字（汉字+数字）+ 类型标记」的真案号词干，但完整匹配没过（缺年份/序号）。
  /// 「汉字+数字」前缀把「执行/执法」这类普通词里的「执」排除掉。
  private static func hasPartialStem(in text: String) -> Bool {
    let pattern = "\\p{Han}+\\d+(刑初|刑终|民初|民终|行初|执)|入库编号\\d"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    let ns = text as NSString
    return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
  }

  private static let markerTable: [(marker: String, type: OwlCaseType)] = [
    ("刑初", .criminalFirstInstance), ("刑终", .criminalSecondInstance),
    ("民初", .civilFirstInstance), ("民终", .civilSecondInstance),
    ("行初", .administrativeFirstInstance), ("执", .execution),
  ]

  /// 所有「完整形状」案号匹配（不论年份是否合法），各带 `yearValid` 标记。
  private func fullShapeMatches(in text: String) -> [(cn: OwlCaseNumber, yearValid: Bool)] {
    let ns = text as NSString
    var out: [(OwlCaseNumber, Bool)] = []
    func collect(_ pattern: String, _ build: (NSTextCheckingResult) -> OwlCaseNumber?) {
      guard let re = try? NSRegularExpression(pattern: pattern) else { return }
      for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if let cn = build(m) { out.append((cn, (1900...currentYear).contains(cn.year))) }
      }
    }
    // 入库编号 YYYY-XX-X-XXX-XXX（人民法院案例库，形状与裁判文书案号不同）
    collect("入库编号(\\d{4})-\\d{2}-\\d-\\d{3}-\\d{3}") { m in
      guard let year = Int(ns.substring(with: m.range(at: 1))) else { return nil }
      return OwlCaseNumber(raw: ns.substring(with: m.range), year: year,
                            courtCode: "", caseType: .caseLibrary, sequence: 0)
    }
    // 裁判文书：(YYYY)<代字><marker><seq>号（半/全角括号兼容）
    for entry in Self.markerTable {
      collect("[（(](\\d{4})[）)]([^（）()号]*?)\(entry.marker)(\\d+)号") { m in
        guard let year = Int(ns.substring(with: m.range(at: 1))),
              let seq = Int(ns.substring(with: m.range(at: 3))) else { return nil }
        let code = ns.substring(with: m.range(at: 2))
        guard !code.isEmpty else { return nil }
        return OwlCaseNumber(raw: ns.substring(with: m.range), year: year,
                              courtCode: code, caseType: entry.type, sequence: seq)
      }
    }
    return out
  }
}
