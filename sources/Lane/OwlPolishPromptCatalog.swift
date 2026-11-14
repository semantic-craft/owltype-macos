//
//  OwlPolishPromptCatalog.swift
//  法墨输入法 (Owltype) — 润色提示词变体注册表 (issue #136, A/B 挂载)
//
//  B4 划词「润色」的 system prompt / temperature 从 OwlSelectionPolish 的硬编码单串改为这里的
//  变体注册表，给 A/B 对比留结构空间：
//    - v1-legacy（保底/默认）：出厂 prompt + temp 0.3。2026-07-31 追加一句逐候选保真硬线
//      （法律/程序动作词不得互换），此前与 #136 之前逐字节一致。
//    - v2-responsay-aligned：段落化装配（仿 Responsay TextTransformPromptAssembler 的
//      role/task/rules/output 分段），对齐的是 Responsay 的 rewrite（重改写）线而非 polish
//      （听写成稿）线（docs/owl-responsay-alignment-spec.md §2.1），并补三块硬护栏（§2.2）：
//      ① byte-for-byte preserve 清单；② 忠实度红线（不改确定度/保留 hedges/不加寒暄署名
//      总结腔）；③ 只处理用户明确选择的文本。
//      temp 0.2 对齐 Responsay LLMGenerationProfile.resolve(rewrite)。
//
//  变体选择存于 OwlExperimentalPreferences.selectionPolishPromptVariant（default-OFF 模式：
//  未设置/未知值一律回退 v1-legacy，不崩）。（「润色·多版本挑选」技能已于 2026-07-26 技能精简中
//  删除，个性化改写由「任意提问」兜底。）
//

import Foundation

/// One resolved polish prompt variant: id + system prompt + sampling temperature. Pure value so
/// the request-construction layer (`OwlSelectionPolish.chatRequest`) stays unit-testable.
struct OwlPolishPromptVariant: Codable, Equatable, Sendable {
  let id: String
  let systemPrompt: String
  let temperature: Double
}

/// The variant registry. Resolution is total: any id (nil, unknown, future) maps to a variant,
/// falling back to `legacy` — a mis-set preference can never crash or blank the prompt.
enum OwlPolishPromptCatalog {
  /// Total lookup: known id → its variant; nil / unknown → v1-legacy (never throws, never blank).
  static func variant(id: String?) -> OwlPolishPromptVariant {
    OwlAIBusinessCore.call("polishVariant", ["id": id as Any? ?? NSNull()])
  }

  /// Resolve the active variant from the experimental preference — the ONE seam the request path
  /// reads, so a test that sets the preference and builds a request exercises true read-back.
  static func resolveActive() -> OwlPolishPromptVariant {
    variant(id: OwlExperimentalPreferences.selectionPolishPromptVariant)
  }
}
