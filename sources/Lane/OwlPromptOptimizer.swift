//
//  OwlPromptOptimizer.swift
//  法墨输入法 (Owltype) — 提示词优化技能 (issue #138)
//
//  把草稿提示词重写成符合 Anthropic Fable 5 提示词工程指南的规范提示词。
//

import Foundation

// OwlPromptOptimizeMode（rewrite / structure 双模式）已删（2026-07-26）：「结构化·加标签」
// 并入「提示词优化」，四要素改写 + XML 标签分区由同一份 system prompt 一次做完。

/// 提示词优化的错误。带用户可读文案，好让协调器不必回显草稿就能说清原因。
enum OwlPromptOptimizeError: Error, Equatable {
  case disabled
  case emptyDraft
  case draftTooLong(Int)
  case missingAPIKey

  var userMessage: String {
    switch self {
    case .disabled:
      return "云端 AI 已关闭，无法优化提示词。"
    case .missingAPIKey:
      return "尚未配置可用 AI 供应商或 API Key。"
    case .emptyDraft:
      return "请先选中要优化的提示词草稿。"
    case .draftTooLong(let count):
      return "草稿过长（\(count) 字），请选中不超过 \(OwlSelectionPolish.maxSelectionLength) 字的内容。"
    }
  }
}

/// UI-facing façade. The deep module owns admission, auth ordering, request assembly, remote fetch,
/// and safe parsing; this type only supplies live dependencies and keeps the feature's public verb.
@MainActor
final class OwlPromptOptimizeService {
  static let shared = OwlPromptOptimizeService()

  private let module: OwlStructuredDrafting

  init(
    remote: OwlStructuredDraftingRemote? = nil,
    apiKeyProvider: @escaping () throws -> String? = { nil },
    profileProvider: @escaping () -> OwlProviderProfile? = {
      OwlProviderProfileStore.shared.defaultProfile
    },
    profileSecretProvider: @escaping (String) throws -> String? = {
      try OwlProviderKeychain().secret(named: $0)
    }
  ) {
    let gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: apiKeyProvider
    )
    self.module = OwlStructuredDrafting(
      configuration: OwlPromptOptimizer.structuredDraftingConfiguration,
      cloudEnabled: { OwlCloudPreferences.isEnabled },
      authorization: { gate.resolve() },
      remote: remote ?? OwlStructuredDraftingClient()
    )
  }

  func optimize(
    _ draft: String,
    clarifications: [OwlPromptClarification] = []
  ) async throws -> OwlPromptOptimizeOutcome {
    try await module.draft(draft, clarifications: clarifications)
  }
}

enum OwlPromptOptimizer {
  /// Live evaluation 保留的领域入口；单一实现已经在 structured seam。
  static let fallbackClarification = OwlStructuredDrafting.fallbackClarification

  /// 澄清问题上限：要预填进任意提问窗口的单行输入框，多了就没法用了。
  static let maxClarificationQuestions = OwlStructuredDrafting.maxClarificationQuestions

  /// 改写目标依据 Anthropic《Prompting Claude Fable 5》：补齐四要素、去步骤脚手架、
  /// 禁止要求复述内部推理（会触发 reasoning_extraction 拒绝）；并依《Prompting best
  /// practices》「Structure prompts with XML tags」给产出按语义套成对标签（原「结构化·
  /// 加标签」独立技能已并入，2026-07-26——优化 + 加标签一次做完）。
  ///
  /// 注意本 prompt 跑在用户自配的云端供应商（通义/豆包/DeepSeek…）上，不是 Fable 5 自己——
  /// 所以这里写得明确无妨；「别过度规定」约束的是**产出的那份提示词**。
  static let systemPrompt: String = OwlAIBusinessCore.call("prompt", ["id": "optimizer"])

  static let structuredDraftingConfiguration = OwlStructuredDraftingConfiguration(
    systemPrompt: systemPrompt,
    maxDraftLength: OwlSelectionPolish.maxSelectionLength,
    temperature: 0.2,
    traceName: "prompt-optimize",
    admissionError: { admission in
      switch admission {
      case .disabled:
        return OwlPromptOptimizeError.disabled
      case .emptyDraft:
        return OwlPromptOptimizeError.emptyDraft
      case .draftTooLong(let count):
        return OwlPromptOptimizeError.draftTooLong(count)
      case .missingAPIKey:
        return OwlPromptOptimizeError.missingAPIKey
      }
    }
  )

  /// 装配一次优化请求。纯函数（model 由调用方解析后传入），好让请求体可以在单测里断言。
  ///
  /// `clarifications` 为空时与首轮请求逐字节一致；补答存在时追加一条用户消息带上问答，
  /// 这样澄清循环不必依赖对话历史就能重跑（#137 落地后可换成真多轮承载）。
  static func chatRequest(
    forDraft draft: String,
    clarifications: [OwlPromptClarification] = [],
    model: String,
    providerID: String = ""
  ) -> OwlDeepSeekChatRequest {
    OwlStructuredDrafting.chatRequest(
      systemPrompt: systemPrompt,
      draft: draft,
      clarifications: clarifications,
      model: model,
      providerID: providerID,
      temperature: structuredDraftingConfiguration.temperature
    )
  }

  /// 模型回复 → 结果。总是返回一个结果：解析失败不抛错、不静默丢弃。
  ///
  /// 安全不变式：`.ready` 只在拿到非空终稿时产生。任何退化（空 prompt、认不出的 status、
  /// 空问题列表）一律转澄清态——否则替换流会清空用户草稿，或把 JSON 原文粘进编辑器。
  static func parse(_ raw: String) -> OwlPromptOptimizeOutcome {
    OwlStructuredDrafting.parse(raw)
  }

  /// 受保护标签三明治（照搬 #136 护栏③）。本技能的输入按定义就是一段指令，最容易被优化器
  /// 「执行」而不是「改写」，所以这道护栏比润色线更要紧。
  ///
  /// 与 #136 的差别：只转义标签本身，不转义所有尖括号。草稿是待改写的正文，可能含
  /// `Array<String>` 这类代码；全量转义会毁掉保真度，而硬规则要求原样保留代码。
  ///
  static func sandwiched(_ draft: String) -> String {
    OwlStructuredDrafting.protectedDraft(draft)
  }
}
