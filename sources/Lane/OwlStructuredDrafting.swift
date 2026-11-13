//
//  OwlStructuredDrafting.swift
//  法墨输入法 (Owltype) — structured drafting seam
//
//  A deep module for explicit cloud skills that turn a protected draft into either a safe final
//  document or a bounded clarification request. Admission, auth ordering, request assembly,
//  transport, and outcome parsing stay behind one interface; feature files supply only their prompt
//  contract and user-facing admission errors.
//

import Foundation

/// A structured-drafting result: either a non-empty final document or questions for the user.
enum OwlPromptOptimizeOutcome: Equatable {
  case ready(String)
  case needsClarification([String])
}

/// One clarification answer carried into a later structured-drafting request.
struct OwlPromptClarification: Codable, Equatable, Sendable {
  let question: String
  let answer: String
}

/// Feature-neutral admission reasons. A feature maps them to its own user-facing error type.
enum OwlStructuredDraftingAdmission: Equatable {
  case disabled
  case emptyDraft
  case draftTooLong(Int)
  case missingAPIKey
}

/// The domain contract supplied by a structured-drafting feature.
struct OwlStructuredDraftingConfiguration {
  let systemPrompt: String
  let maxDraftLength: Int
  let temperature: Double
  let traceName: String
  let admissionError: (OwlStructuredDraftingAdmission) -> Error
}

/// Everything the remote adapter needs after admission and auth have succeeded.
struct OwlStructuredDraftingRemoteRequest {
  let routing: OwlCloudRouting
  let apiKey: String
  let payload: OwlDeepSeekChatRequest
  let traceName: String
  let clarificationCount: Int
}

/// The only remote dependency of the module. Tests replace it with an in-memory adapter.
@MainActor
protocol OwlStructuredDraftingRemote {
  func fetch(_ request: OwlStructuredDraftingRemoteRequest) async throws -> String
}

/// Admission -> auth -> protected request -> remote adapter -> safe outcome.
@MainActor
final class OwlStructuredDrafting {
  nonisolated static let fallbackClarification: String = OwlAIBusinessCore.call("clarification")
  nonisolated static let maxClarificationQuestions: Int = OwlAIBusinessCore.call("limit", ["id": "clarifications"])

  private let configuration: OwlStructuredDraftingConfiguration
  private let cloudEnabled: () -> Bool
  private let authorization: () -> OwlProviderAuthOutcome
  private let remote: OwlStructuredDraftingRemote

  init(
    configuration: OwlStructuredDraftingConfiguration,
    cloudEnabled: @escaping () -> Bool,
    authorization: @escaping () -> OwlProviderAuthOutcome,
    remote: OwlStructuredDraftingRemote
  ) {
    self.configuration = configuration
    self.cloudEnabled = cloudEnabled
    self.authorization = authorization
    self.remote = remote
  }

  /// Runs the entire structured-drafting flow. Admission always precedes Keychain/auth resolution;
  /// the remote adapter is unreachable until both have succeeded.
  func draft(
    _ draft: String,
    clarifications: [OwlPromptClarification] = []
  ) async throws -> OwlPromptOptimizeOutcome {
    let admission: OwlAIAdmission = OwlAIBusinessCore.call("admission", ["enabled": cloudEnabled(),
      "text": draft, "limit": configuration.maxDraftLength, "trimCount": true])
    switch admission.error {
    case "disabled": throw configuration.admissionError(.disabled)
    case "empty": throw configuration.admissionError(.emptyDraft)
    case "tooLong": throw configuration.admissionError(.draftTooLong(admission.count))
    default: break
    }

    let routing: OwlCloudRouting
    let apiKey: String
    switch authorization() {
    case let .ready(resolvedRouting, resolvedKey):
      routing = resolvedRouting
      apiKey = resolvedKey
    case .unconfigured, .missingKey:
      throw configuration.admissionError(.missingAPIKey)
    }

    let payload = Self.chatRequest(
      systemPrompt: configuration.systemPrompt,
      draft: draft,
      clarifications: clarifications,
      model: routing.model,
      providerID: routing.providerID,
      temperature: configuration.temperature
    )
    let raw = try await remote.fetch(OwlStructuredDraftingRemoteRequest(
      routing: routing,
      apiKey: apiKey,
      payload: payload,
      traceName: configuration.traceName,
      clarificationCount: clarifications.count
    ))
    return Self.parse(raw)
  }

  /// Pure request assembly shared by the live module and request-shape tests/evaluations.
  nonisolated static func chatRequest(
    systemPrompt: String,
    draft: String,
    clarifications: [OwlPromptClarification] = [],
    model: String,
    providerID: String = "",
    temperature: Double
  ) -> OwlDeepSeekChatRequest {
    OwlAIBusinessCore.call("skillRequest", ["kind": "structured", "systemPrompt": systemPrompt,
      "draft": draft, "clarifications": OwlAIBusinessCore.json(clarifications),
      "model": model, "providerID": providerID, "temperature": temperature])
  }

  /// Model reply -> safe outcome. Degraded JSON never reaches the replacement path.
  nonisolated static func parse(_ raw: String) -> OwlPromptOptimizeOutcome {
    struct Outcome: Decodable { let prompt: String?; let questions: [String]? }
    let outcome: Outcome = OwlAIBusinessCore.call("structuredParse", ["text": raw])
    if let prompt = outcome.prompt { return .ready(prompt) }
    return .needsClarification(outcome.questions!)
  }

  /// Protects a draft without escaping ordinary angle brackets, so code and HTML remain byte-for-
  /// byte intact. Only the sentinel tags are escaped to prevent a draft from closing the boundary.
  nonisolated static func protectedDraft(_ draft: String) -> String {
    OwlAIBusinessCore.call("protectedDraft", ["text": draft])
  }


}

/// Live adapter: the module's authorized request through the LLM gateway, which owns provider
/// routing, the wire dialects and the drafting timeout.
struct OwlStructuredDraftingClient: OwlStructuredDraftingRemote {
  let gateway: OwlLLMGateway

  init(gateway: OwlLLMGateway = OwlLLMGateway()) {
    self.gateway = gateway
  }

  func fetch(_ request: OwlStructuredDraftingRemoteRequest) async throws -> String {
    OwlLiveInputTrace.write {
      "\(request.traceName) model=\(request.routing.model) clarifications=\(request.clarificationCount)"
    }
    return try await gateway.complete(
      request.payload, routing: request.routing, apiKey: request.apiKey, purpose: .drafting)
  }
}

struct OwlAIAdmission: Decodable { let error: String; let count: Int }
