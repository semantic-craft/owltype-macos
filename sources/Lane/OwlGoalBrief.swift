//
//  OwlGoalBrief.swift
//  猫头鹰输入法 (Owltype) — 任务书技能（目标七问）
//
//  把选中的模糊需求整理成一份「目标任务书」，供 AI Agent 独立执行数小时而不跑偏。
//  方法来自 Khazix「目标七问」（github.com/KKKKhazix/khazix-skills leader 技能的推文提炼）：
//  目的 Why / 完成态 Done / 证据 Proof / 反作弊 Anti / 边界 Bounds / 取舍 Trade / 未知 Unknown。
//
//  鉴权、受保护草稿、澄清、transport 与 outcome safety 由 OwlStructuredDrafting 统一负责；
//  本文件只保留目标七问 prompt 与任务书自己的用户文案。
//

import Foundation

/// 任务书技能的错误。结构镜像 `OwlPromptOptimizeError`，文案换成本技能的名词。
enum OwlGoalBriefError: Error, Equatable {
  case disabled
  case emptyDraft
  case draftTooLong(Int)
  case missingAPIKey

  var userMessage: String {
    switch self {
    case .disabled:
      return "云端 AI 已关闭，无法整理任务书。"
    case .missingAPIKey:
      return "尚未配置可用 AI 供应商或 API Key。"
    case .emptyDraft:
      return "请先选中要整理的需求描述。"
    case .draftTooLong(let count):
      return "选中内容过长（\(count) 字），请选中不超过 \(OwlSelectionPolish.maxSelectionLength) 字的内容。"
    }
  }
}

/// UI-facing façade. Shared structured drafting owns admission, auth ordering, request assembly,
/// transport and safe parsing; this type only supplies live dependencies and keeps `compose`.
@MainActor
final class OwlGoalBriefService {
  static let shared = OwlGoalBriefService()

  private let module: OwlStructuredDrafting

  init(
    remote: OwlStructuredDraftingRemote? = nil,
    apiKeyProvider: @escaping () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
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
      configuration: OwlGoalBrief.structuredDraftingConfiguration,
      cloudEnabled: { OwlCloudPreferences.isEnabled },
      authorization: { gate.resolve() },
      remote: remote ?? OwlStructuredDraftingClient()
    )
  }

  func compose(
    _ draft: String,
    clarifications: [OwlPromptClarification] = []
  ) async throws -> OwlPromptOptimizeOutcome {
    try await module.draft(draft, clarifications: clarifications)
  }
}

enum OwlGoalBrief {
  /// 缺失分级是本技能与提示词优化最大的行为差异：任务书天然有〈未知〉一节兜住非致命缺失，
  /// 所以只有「目的 + 完成态」双双推断不出（任务书写了也没意义）才走澄清循环打断用户。
  static let systemPrompt: String = OwlAIBusinessCore.call("prompt", ["id": "goalBrief"])

  static let structuredDraftingConfiguration = OwlStructuredDraftingConfiguration(
    systemPrompt: systemPrompt,
    maxDraftLength: OwlSelectionPolish.maxSelectionLength,
    temperature: 0.2,
    traceName: "goal-brief",
    admissionError: { admission in
      switch admission {
      case .disabled:
        return OwlGoalBriefError.disabled
      case .emptyDraft:
        return OwlGoalBriefError.emptyDraft
      case .draftTooLong(let count):
        return OwlGoalBriefError.draftTooLong(count)
      case .missingAPIKey:
        return OwlGoalBriefError.missingAPIKey
      }
    }
  )

  /// 装配一次整理请求。纯函数（model 由调用方解析后传入），好让请求体可以在单测里断言。
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
}
