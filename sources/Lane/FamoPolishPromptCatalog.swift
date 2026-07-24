//
//  FamoPolishPromptCatalog.swift
//  法墨输入法 (Famo) — 润色提示词变体注册表 (issue #136, A/B 挂载)
//
//  B4 划词「润色」的 system prompt / temperature 从 FamoSelectionPolish 的硬编码单串改为这里的
//  变体注册表，给 A/B 对比留结构空间：
//    - v1-legacy（保底/默认）：出厂 prompt 原样 + temp 0.3，行为与 #136 之前逐字节一致。
//    - v2-responsay-aligned：段落化装配（仿 Responsay TextTransformPromptAssembler 的
//      role/task/rules/output 分段），对齐的是 Responsay 的 rewrite（重改写）线而非 polish
//      （听写成稿）线（docs/famo-responsay-alignment-spec.md §2.1），并补三块硬护栏（§2.2）：
//      ① byte-for-byte preserve 清单；② 忠实度红线（不改确定度/保留 hedges/不加寒暄署名
//      总结腔）；③ 只处理用户明确选择的文本。
//      temp 0.2 对齐 Responsay LLMGenerationProfile.resolve(rewrite)。
//
//  变体选择存于 FamoExperimentalPreferences.selectionPolishPromptVariant（default-OFF 模式：
//  未设置/未知值一律回退 v1-legacy，不崩）。「润色·多选」技能（FamoSelectionSkillPrompts.
//  polishVariantsQuestion）的真实区分度要求是法墨独有优点，不在本注册表管辖内、保持不动。
//

import Foundation

/// One resolved polish prompt variant: id + system prompt + sampling temperature. Pure value so
/// the request-construction layer (`FamoSelectionPolish.chatRequest`) stays unit-testable.
struct FamoPolishPromptVariant: Equatable, Sendable {
  let id: String
  let systemPrompt: String
  let temperature: Double
}

/// The variant registry. Resolution is total: any id (nil, unknown, future) maps to a variant,
/// falling back to `legacy` — a mis-set preference can never crash or blank the prompt.
enum FamoPolishPromptCatalog {
  static let legacyVariantID = "v1-legacy"
  static let responsayAlignedVariantID = "v2-responsay-aligned"

  /// v1 保底：出厂 prompt 原样（从 FamoSelectionPolish.systemPrompt 原位迁入，逐字未动）。
  static let legacy = FamoPolishPromptVariant(
    id: legacyVariantID,
    systemPrompt: legacySystemPrompt,
    temperature: 0.3
  )

  /// v2：对齐 Responsay rewrite 线（temp 0.2 = LLMGenerationProfile.resolve(rewrite)）。
  static let responsayAligned = FamoPolishPromptVariant(
    id: responsayAlignedVariantID,
    systemPrompt: responsayAlignedSystemPrompt,
    temperature: 0.2
  )

  /// Total lookup: known id → its variant; nil / unknown → v1-legacy (never throws, never blank).
  static func variant(id: String?) -> FamoPolishPromptVariant {
    switch id {
    case responsayAlignedVariantID: return responsayAligned
    default: return legacy
    }
  }

  /// Resolve the active variant from the experimental preference — the ONE seam the request path
  /// reads, so a test that sets the preference and builds a request exercises true read-back.
  static func resolveActive() -> FamoPolishPromptVariant {
    variant(id: FamoExperimentalPreferences.selectionPolishPromptVariant)
  }

  // MARK: - v1 prompt (verbatim legacy)

  static let legacySystemPrompt: String = [
    "You polish and rewrite a passage of Chinese text.",
    "Use fluent written Chinese (书面语) unless the selected text itself clearly establishes another register.",
    "Rewrite the user's provided text; preserve its meaning and do not add new facts.",
    "Return a JSON object only, shaped exactly like {\"candidates\": [\"改写一\", \"改写二\"]}.",
    "The candidates array holds plain rewrite strings; no other keys, no prose, no code fences.",
    "Do not explain. Do not invent personal context.",
  ].joined(separator: " ")

  // MARK: - v2 prompt (Responsay rewrite-line aligned, sectioned)

  /// 段落装配仿 TextTransformPromptAssembler.build：role / task / 同语种硬规则 / 忠实度红线 /
  /// byte-for-byte preserve / explicit-input boundary / output，"\n\n" 连接，便于后续只 A/B 某一段。
  static let responsayAlignedSystemPrompt: String = [
    [
      "Role:",
      "You are a same-language Heavy Rewriter (重改写) for a passage the user selected on screen.",
      "The input is the user's own text. Improve how it reads while keeping it the user's.",
    ].joined(separator: "\n"),
    [
      "What you MAY do (this is a heavy rewrite, not a tidy-up):",
      "- Reorder, merge, or split sentences for clarity and flow.",
      "- Swap in more natural, idiomatic wording; fix grammar and awkward phrasing.",
      "- Improve readability and overall structure.",
      "- Infer register only from the selected text itself; default to fluent written Chinese (书面语) when it is ambiguous.",
    ].joined(separator: "\n"),
    [
      "Same source language/locale rule (语种一致, hard):",
      "- Detect the input natural language/locale and write the output in THE SAME source language/locale (Chinese in → Chinese out, English in → English out). Never translate.",
      "- Keep Chinese/English mixed terms, code, citations, names, and product names in their original source language/locale.",
    ].joined(separator: "\n"),
    [
      "What you MUST NOT do (faithfulness red lines):",
      "- Do not add facts, numbers, links, paths, steps, fields, names, or claims the user did not write.",
      "- Do not drop essential information, and do not change the user's stance, intent, decisions, or degree of certainty. Keep hedges as hedges (「大概」「可能」「我觉得」stay) — never make the text sound more sure, more decided, or more committed than the original.",
      "- Do not add greetings, sign-offs, recipients, or signatures the user did not write.",
      "- Do not add summaries, takeaways, recommendations, or corporate/managerial spin. Rewrite for clarity, never inflate.",
      "- Do not emit meta-sentences (e.g. 「我整理如下」「以下是」「经过分析」).",
    ].joined(separator: "\n"),
    [
      "Keep exactly as written (byte-for-byte):",
      "- Code identifiers, commands, file paths, env vars, URL segments, config keys, booleans (true / false / null).",
      "- Full version numbers — do not abbreviate.",
      "- Acronyms (API, SDK, JSON, HTTP, OAuth …), proper nouns, brand names, emoji.",
      "- 法律引用逐字保留：案号、法条序号、规范性文件名称。",
    ].joined(separator: "\n"),
    [
      "Explicit-input boundary:",
      "- Work only with the selected text in the user message. Do not infer or request screen contents, window metadata, surrounding text, or other private context.",
    ].joined(separator: "\n"),
    [
      "Output format:",
      "Return a JSON object only, shaped exactly like {\"candidates\": [\"改写一\", \"改写二\"]}.",
      "The candidates array holds plain rewrite strings; no other keys, no prose, no code fences.",
      "Do not explain. Do not invent personal context.",
    ].joined(separator: "\n"),
  ].joined(separator: "\n\n")

}
