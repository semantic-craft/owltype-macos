//
//  OwlAIPolishService.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  Live implementation of dual candidate polish (2 candidates) and
//  quick reply generation (3 candidates) conforming to
//  `OwlSelectionPolishClientProtocol` and `OwlReplyGeneratorProtocol`.
//  Supports dependency injection for 100% offline hermetic testing.
//

import Foundation

// MARK: - Protocols

public protocol OwlSelectionPolishClientProtocol: Sendable {
  /// Polishes the selection text into exactly 2 distinct candidates.
  func polishSelection(text: String, style: OwlPolishStyle) async throws -> [String]
}

public protocol OwlReplyGeneratorProtocol: Sendable {
  /// Generates exactly 3 reply candidates given the context and template.
  func generateReplies(contextText: String, template: OwlReplyTemplate) async throws -> [String]
}

// MARK: - Live Service

public final class OwlAIPolishService: OwlSelectionPolishClientProtocol, OwlReplyGeneratorProtocol, @unchecked Sendable {
  public static let shared = OwlAIPolishService()

  private let gateway: OwlLLMGateway
  private let authGateProvider: @Sendable () async -> OwlProviderAuthOutcome
  private let customPolisher: (@Sendable (String, OwlPolishStyle) async throws -> [String])?
  private let customReplier: (@Sendable (String, OwlReplyTemplate) async throws -> [String])?

  init(
    gateway: OwlLLMGateway = OwlLLMGateway(),
    authGateProvider: (@Sendable () async -> OwlProviderAuthOutcome)? = nil,
    customPolisher: (@Sendable (String, OwlPolishStyle) async throws -> [String])? = nil,
    customReplier: (@Sendable (String, OwlReplyTemplate) async throws -> [String])? = nil
  ) {
    self.gateway = gateway
    self.authGateProvider = authGateProvider ?? {
      await MainActor.run {
        let gate = OwlProviderAuthGate(
          profileProvider: { OwlProviderProfileStore.shared.defaultProfile },
          profileSecretProvider: { try OwlProviderKeychain().secret(named: $0) },
          legacyKeyProvider: OwlCloudKeychain.readDeepSeekAPIKey
        )
        return gate.resolve()
      }
    }
    self.customPolisher = customPolisher
    self.customReplier = customReplier
  }

  public convenience init(
    customPolisher: (@Sendable (String, OwlPolishStyle) async throws -> [String])? = nil,
    customReplier: (@Sendable (String, OwlReplyTemplate) async throws -> [String])? = nil
  ) {
    self.init(
      gateway: OwlLLMGateway(),
      authGateProvider: nil,
      customPolisher: customPolisher,
      customReplier: customReplier
    )
  }

  // MARK: - OwlSelectionPolishClientProtocol

  public func polishSelection(text: String, style: OwlPolishStyle) async throws -> [String] {
    if let customPolisher {
      return try await customPolisher(text, style)
    }

    if let reason = OwlSelectionPolish.rejectionReason(for: text) {
      throw reason
    }

    guard OwlCloudPreferences.isEnabled else {
      throw OwlSelectionPolishError.disabled
    }

    let auth = await authGateProvider()
    guard case let .ready(routing, apiKey) = auth else {
      throw OwlSelectionPolishError.missingAPIKey
    }

    let systemPrompt = OwlDualPolishPromptCatalog.buildSystemPrompt(style: style)
    let userPrompt = OwlDualPolishPromptCatalog.buildUserPrompt(text: text)

    let thinkingFields = OwlThinkingControl.offFields(providerID: routing.providerID, model: routing.model)
    let payload = OwlDeepSeekChatRequest(
      model: routing.model,
      messages: [
        OwlDeepSeekMessage(role: "system", content: systemPrompt),
        OwlDeepSeekMessage(role: "user", content: userPrompt)
      ],
      temperature: style.temperature,
      stream: false,
      responseFormat: nil,
      thinking: thinkingFields.thinking,
      enableThinking: thinkingFields.enableThinking,
      reasoningEffort: thinkingFields.reasoningEffort,
      reasoningSplit: thinkingFields.reasoningSplit
    )

    let raw = try await gateway.complete(payload, routing: routing, apiKey: apiKey, purpose: .interactiveRewrite)
    return OwlDualPolishParser.parse(raw: raw, originalText: text)
  }

  // MARK: - OwlReplyGeneratorProtocol

  public func generateReplies(contextText: String, template: OwlReplyTemplate) async throws -> [String] {
    if let customReplier {
      return try await customReplier(contextText, template)
    }

    guard OwlCloudPreferences.isEnabled else {
      throw OwlSelectionPolishError.disabled
    }

    let trimmed = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return OwlDualPolishParser.parseReplies(raw: "", contextText: contextText)
    }

    let auth = await authGateProvider()
    guard case let .ready(routing, apiKey) = auth else {
      throw OwlSelectionPolishError.missingAPIKey
    }

    let systemPrompt = OwlReplyPromptCatalog.buildSystemPrompt(template: template)
    let userPrompt = OwlReplyPromptCatalog.buildUserPrompt(contextText: contextText)

    let thinkingFields = OwlThinkingControl.offFields(providerID: routing.providerID, model: routing.model)
    let payload = OwlDeepSeekChatRequest(
      model: routing.model,
      messages: [
        OwlDeepSeekMessage(role: "system", content: systemPrompt),
        OwlDeepSeekMessage(role: "user", content: userPrompt)
      ],
      temperature: 0.3,
      stream: false,
      responseFormat: nil,
      thinking: thinkingFields.thinking,
      enableThinking: thinkingFields.enableThinking,
      reasoningEffort: thinkingFields.reasoningEffort,
      reasoningSplit: thinkingFields.reasoningSplit
    )

    let raw = try await gateway.complete(payload, routing: routing, apiKey: apiKey, purpose: .interactiveRewrite)
    return OwlDualPolishParser.parseReplies(raw: raw, contextText: contextText)
  }
}
