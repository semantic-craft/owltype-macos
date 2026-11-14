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
}
