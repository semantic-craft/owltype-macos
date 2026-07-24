//
//  FamoSelectionVerifyMenu.swift
//  法墨输入法 (Famo) — 来源核验分组源菜单模型 (issue #134)
//
//  1:1 移植自 Responsay `SelectionVerifyMenu.swift`。任何选区都能核验：
//    · 抽到该组相关的结构化坐标（法条/案号/文献） → 用坐标当检索词（最精准）；
//    · 抽不到 → 整段选区规范化兜底（合并空白 + 截断 80）。
//  付费/JS 站由 FamoVerificationQueryRouter 自动走必应 site: 落到结果页。
//  知网拆两项且「知网·关键词」带词直达排首位（已拍板第一优先，真机验收过）。
//  Core 只产菜单模型；NSMenu 渲染与打开 URL 归 #135。
//

import Foundation

struct FamoVerifyMenuItem: Sendable, Equatable {
  let source: FamoVerificationSource
  let title: String                    // 显示名（北大法宝 / 知网·关键词 / 必应 …）
  let route: FamoVerificationRoute     // 已备好的可打开 route
}

struct FamoVerifyMenuGroup: Sendable, Equatable {
  let title: String                    // 法规 / 案例 / 文献 / 兜底
  let items: [FamoVerifyMenuItem]
}

enum FamoSelectionVerifyMenu {

  // 分组定义：标题 · 该组「相关的」锚点 kind（挑精准检索词）· 该组列出的源（顺序即菜单顺序）。
  private struct GroupSpec {
    let title: String
    let kinds: Set<FamoVerificationKind>
    let sources: [FamoVerificationSource]
  }

  private static let groups: [GroupSpec] = [
    GroupSpec(title: "法规",
              kinds: [.law, .administrativeRule, .standard, .officialDocument],
              sources: [.govLaw, .pkulaw]),
    GroupSpec(title: "案例",
              kinds: [.caseLaw],
              sources: [.pkulaw, .itslaw, .wenshu, .rmfyalk]),
    GroupSpec(title: "文献",
              kinds: [.scholarlyArticle],
              sources: [.cnki, .vip, .wanfang, .baiduScholar]),
    GroupSpec(title: "兜底",
              kinds: [],
              sources: [.bing, .webSearch]),
  ]

  /// 为选区构建分组源菜单。传入抽取器找到的锚点以便各组优先精准坐标；
  /// 无锚点时各组回退整段选区。空选区 → 空菜单。
  static func build(selectedText: String,
                    anchors: [FamoVerificationAnchor] = []) -> [FamoVerifyMenuGroup] {
    let fallback = FamoVerificationQueryRouter.normalizeSelection(selectedText)
    return groups.compactMap { spec in
      let query = query(for: spec, anchors: anchors, fallback: fallback)
      guard !query.isEmpty else { return nil }
      let items = spec.sources.flatMap { source -> [FamoVerifyMenuItem] in
        if source == .cnki { return cnkiItems(query: query) }
        return [FamoVerifyMenuItem(source: source, title: source.displayName,
                                   route: FamoVerificationQueryRouter.route(query: query, source: source))]
      }
      return FamoVerifyMenuGroup(title: spec.title, items: items)
    }
  }

  private static func query(for spec: GroupSpec,
                            anchors: [FamoVerificationAnchor],
                            fallback: String) -> String {
    if let match = anchors.first(where: { spec.kinds.contains($0.kind) }) {
      let q = match.query.trimmingCharacters(in: .whitespacesAndNewlines)
      return q.isEmpty ? match.label : q
    }
    return fallback
  }

  /// 知网拆成两项：关键词直达（一框式 `?kw=`，第一优先）+ 专业检索式（开 AdvSearch 无参页，
  /// route.query=生成的检索式，打开时由剪贴板纪律自动复制供粘贴）。
  private static func cnkiItems(query: String) -> [FamoVerifyMenuItem] {
    let keyword = FamoVerifyMenuItem(
      source: .cnki, title: "知网·关键词",
      route: FamoVerificationQueryRouter.route(query: query, source: .cnki))
    let expert = FamoVerifyMenuItem(
      source: .cnki, title: "知网·专业检索式",
      route: FamoVerificationRoute(kind: .deepLink, source: .cnki,
                                   query: FamoCNKIExpertQueryBuilder.build(query: query),
                                   url: FamoCNKIExpertQueryBuilder.professionalSearchURL))
    return [keyword, expert]
  }
}
