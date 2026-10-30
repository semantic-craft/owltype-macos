//
//  OwlSelectionVerifyMenu.swift
//  猫头鹰输入法 (Owltype) — 来源核验分组源菜单模型 (issue #134)
//
//  1:1 移植自 Responsay `SelectionVerifyMenu.swift`。任何选区都能核验：
//    · 抽到该组相关的结构化坐标（法条/案号/文献） → 用坐标当检索词（最精准）；
//    · 抽不到 → 整段选区规范化兜底（合并空白 + 截断 80）。
//  付费/JS 站由 OwlVerificationQueryRouter 自动走必应 site: 落到结果页。
//  知网拆两项且「知网·关键词」带词直达排首位（已拍板第一优先，真机验收过）。
//  Core 只产菜单模型；NSMenu 渲染与打开 URL 归 #135。
//

import Foundation

struct OwlVerifyMenuItem: Codable, Sendable, Equatable {
  let source: OwlVerificationSource
  let title: String                    // 显示名（北大法宝 / 知网·关键词 / 必应 …）
  let route: OwlVerificationRoute     // 已备好的可打开 route
}

struct OwlVerifyMenuGroup: Codable, Sendable, Equatable {
  let title: String                    // 法规 / 案例 / 文献 / 兜底
  let items: [OwlVerifyMenuItem]
}

enum OwlSelectionVerifyMenu {
  static func build(selectedText: String, anchors: [OwlVerificationAnchor] = []) -> [OwlVerifyMenuGroup] {
    OwlAIBusinessCore.call("verifyMenu", ["text": selectedText, "anchors": OwlAIBusinessCore.json(anchors)])
  }
}
