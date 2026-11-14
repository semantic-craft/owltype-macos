//
//  OwlVerificationAnchors.swift
//  法墨输入法 (Owltype) — 来源核验锚点数据层：坐标抽取 + 案号准入闸 (issue #134)
//
//  1:1 移植自 Responsay `VerificationAnchor.swift` / `FactCoordinateExtractor.swift` /
//  `CaseNumberVerifier.swift`（主线仓 docs/owl-responsay-alignment-spec.md）。
//  本地确定性抽取（正则 + 小词表），不依赖 LLM；抽出的锚点一律 `.pending`（[待核]）。
//  铁律：搜不到 ≠ 不存在——本层永不产出 `.rejected`，判驳只能来自用户显式操作。
//

import Foundation

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
  let url: String
  let provider: String
  let snippet: String?
}

struct OwlVerificationAnchor: Codable, Sendable, Identifiable, Equatable {
  let id: String
  let label: String          // 如 "《民法典》第五百七十七条" / "GB/T 39335"
  let kind: OwlVerificationKind
  let query: String
}
