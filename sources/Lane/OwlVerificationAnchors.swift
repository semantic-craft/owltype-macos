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
  static func extract(from text: String) -> [OwlVerificationAnchor] {
    OwlAIBusinessCore.call("anchors", ["text": text])
  }
  static func normalize(_ raw: String) -> String { OwlAIBusinessCore.call("normalizeAnchor", ["text": raw]) }
  static func stripLeadIn(_ text: String) -> String { OwlAIBusinessCore.call("stripLeadIn", ["text": text]) }
}

// MARK: - 案号准入闸（案例锚点进入展示/报告前必过）

enum OwlCaseType: String, Codable, Sendable, Equatable {
  case criminalFirstInstance       // 刑初
  case criminalSecondInstance      // 刑终
  case civilFirstInstance          // 民初
  case civilSecondInstance         // 民终
  case administrativeFirstInstance // 行初
  case execution                   // 执
  case caseLibrary                 // 入库编号
}

enum OwlCaseNumberStatus: String, Codable, Sendable, Equatable {
  case complete            // ✅ 可提取且格式正确
  case partial             // ⚠️ 有类型标记但缺年份/完整编号（截断）
  case missing             // ❌ 完全无案号信号
  case suspectedFabricated // ❓ 形似案号但格式不符规范（常见于 AI 杜撰）
}

enum OwlCaseNumberDisposition: String, Codable, Sendable, Equatable {
  case admit                       // 准入
  case attemptCompleteElseDiscard  // 尝试补全，失败则废弃
  case discard                     // 废弃
}

struct OwlCaseNumber: Codable, Sendable, Equatable {
  let raw: String
  let year: Int
  let courtCode: String   // 法院代字，如 皖1702 / 粤03
  let caseType: OwlCaseType
  let sequence: Int
}

struct OwlCaseNumberVerdict: Codable, Sendable, Equatable {
  let caseNumber: OwlCaseNumber?
  let status: OwlCaseNumberStatus

  var disposition: OwlCaseNumberDisposition {
    OwlAIBusinessCore.call("caseDisposition", ["status": status.rawValue])
  }

}

/// 纯函数：提取 → 格式校验 → 三重分类（+❓疑似虚构）→ 处置。
struct OwlCaseNumberVerifier: Sendable {
  let currentYear: Int
  func verify(_ text: String) -> OwlCaseNumberVerdict {
    OwlAIBusinessCore.call("caseNumber", ["text": text, "currentYear": currentYear])
  }
}
