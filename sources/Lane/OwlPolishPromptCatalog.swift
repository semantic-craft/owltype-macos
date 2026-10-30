//
//  OwlPolishPromptCatalog.swift
//  猫头鹰输入法 (Owltype) — 润色提示词变体注册表 (issue #136, A/B 挂载)
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
  static let legacyVariantID = "v1-legacy"
  static let responsayAlignedVariantID = "v2-responsay-aligned"

  /// v1 保底：出厂 prompt 原样（从 OwlSelectionPolish.systemPrompt 原位迁入，逐字未动）。
  static let legacy = variant(id: legacyVariantID)

  /// v2：对齐 Responsay rewrite 线（temp 0.2 = LLMGenerationProfile.resolve(rewrite)）。
  static let responsayAligned = variant(id: responsayAlignedVariantID)

  /// Total lookup: known id → its variant; nil / unknown → v1-legacy (never throws, never blank).
  static func variant(id: String?) -> OwlPolishPromptVariant {
    OwlAIBusinessCore.call("polishVariant", ["id": id as Any? ?? NSNull()])
  }

  /// Resolve the active variant from the experimental preference — the ONE seam the request path
  /// reads, so a test that sets the preference and builds a request exercises true read-back.
  static func resolveActive() -> OwlPolishPromptVariant {
    variant(id: OwlExperimentalPreferences.selectionPolishPromptVariant)
  }

  // MARK: - v1 prompt (legacy + fidelity hard line)

  /// 2026-07-31 保真加固：在出厂 prompt 上追加一句硬约束。旧基线 qwen3.7-flash 实盘曾把
  /// 「可能撤销合同」润成「或许解除该合同」——撤销与解除是两种法律效果，润色绝不能替用户
  /// 换法律动作。约束写成通用规则（动作/效果词 + 确定度 + 事实逐项保留），三个生产模型
  /// （qwen3.7-plus / qwen3.7-max / doubao-seed-2-1-pro）共用，不做供应商分支。
  static let legacySystemPrompt: String = OwlAIBusinessCore.call("prompt", ["id": "polishLegacy"])

  // MARK: - v2 prompt (Responsay rewrite-line aligned, sectioned)

  /// 段落装配仿 TextTransformPromptAssembler.build：role / task / 同语种硬规则 / 忠实度红线 /
  /// byte-for-byte preserve / explicit-input boundary / output，"\n\n" 连接，便于后续只 A/B 某一段。
  static let responsayAlignedSystemPrompt: String = OwlAIBusinessCore.call("prompt", ["id": "polishAligned"])

}
