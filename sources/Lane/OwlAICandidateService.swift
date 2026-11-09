//
//  OwlAICandidateService.swift
//  Owltype — Lane A: Cloud AI Candidate Association Service (#392)
//
//  Generates generative cloud completions off the input hot path.
//  Uses OwlProviderAuthGate to resolve provider credentials and
//  OwlLLMGateway to perform non-blocking requests with thinking disabled.
//

import Foundation

struct OwlAICandidateTicket: Equatable, Sendable {
  let sessionID: UInt64
  let generation: UInt64
  let rawInput: String
  let actionEpoch: UInt64

  init(sessionID: UInt64, generation: UInt64, rawInput: String, actionEpoch: UInt64) {
    self.sessionID = sessionID
    self.generation = generation
    self.rawInput = rawInput
    self.actionEpoch = actionEpoch
  }
}

protocol OwlAICandidateServiceProtocol: Sendable {
  func generateCandidates(ticket: OwlAICandidateTicket, preContext: String?) async -> [String]
  func rerankCandidates(
    preContext: String?,
    pinyin: String,
    localCandidates: [String],
    ticket: OwlAICandidateTicket
  ) async throws -> Int?
}

extension OwlAICandidateServiceProtocol {
  func rerankCandidates(
    preContext: String?,
    pinyin: String,
    localCandidates: [String],
    ticket: OwlAICandidateTicket
  ) async throws -> Int? {
    nil
  }
}

final class OwlAICandidateService: OwlAICandidateServiceProtocol, @unchecked Sendable {
  static let shared = OwlAICandidateService()

  private let gateway: OwlLLMGateway
  private let authGateProvider: @Sendable () async -> OwlProviderAuthOutcome
  private let customGenerator: (@Sendable (OwlAICandidateTicket, String?) async -> [String])?
  private let customReranker: (@Sendable (String?, String, [String], OwlAICandidateTicket) async throws -> Int?)?
  private let rerankCache = OwlCandidateRerankCache()

  init(
    gateway: OwlLLMGateway = OwlLLMGateway(),
    authGateProvider: (@Sendable () async -> OwlProviderAuthOutcome)? = nil,
    customGenerator: (@Sendable (OwlAICandidateTicket, String?) async -> [String])? = nil,
    customReranker: (@Sendable (String?, String, [String], OwlAICandidateTicket) async throws -> Int?)? = nil
  ) {
    self.gateway = gateway
    self.authGateProvider = authGateProvider ?? {
      await MainActor.run {
        let gate = OwlProviderAuthGate(
          profileProvider: { OwlProviderProfileStore.shared.defaultProfile },
          profileSecretProvider: { try OwlProviderKeychain().secret(named: $0) },
          legacyKeyProvider: nil
        )
        return gate.resolve()
      }
    }
    self.customGenerator = customGenerator
    self.customReranker = customReranker
  }

  func generateCandidates(ticket: OwlAICandidateTicket, preContext: String?) async -> [String] {
    if let customGenerator {
      return await customGenerator(ticket, preContext)
    }

    if Task.isCancelled { return [] }

    let auth = await authGateProvider()
    guard case let .ready(routing, apiKey) = auth else {
      return []
    }

    let systemPrompt = "You are an intelligent input method AI completion assistant. Provide 1 to 3 natural, concise completions or associations continuing from the user's input/context. Return each completion on a separate line, without numbering, explanation, or quotes."
    var userContent = ""
    if let preContext = preContext, !preContext.isEmpty {
      userContent += "Context: \(preContext)\n"
    }
    userContent += "Input: \(ticket.rawInput)"

    let messages = [
      OwlDeepSeekMessage(role: "system", content: systemPrompt),
      OwlDeepSeekMessage(role: "user", content: userContent)
    ]

    let thinkingFields = OwlThinkingControl.offFields(providerID: routing.providerID, model: routing.model)
    let payload = OwlDeepSeekChatRequest(
      model: routing.model,
      messages: messages,
      temperature: 0.3,
      stream: false,
      responseFormat: nil,
      thinking: thinkingFields.thinking,
      enableThinking: thinkingFields.enableThinking,
      reasoningEffort: thinkingFields.reasoningEffort,
      reasoningSplit: thinkingFields.reasoningSplit
    )

    do {
      let rawResponse = try await gateway.complete(
        payload,
        routing: routing,
        apiKey: apiKey,
        purpose: .interactiveRewrite
      )
      if Task.isCancelled { return [] }
      return Self.parseCandidates(rawResponse, rawInput: ticket.rawInput)
    } catch {
      return []
    }
  }

  static func parseCandidates(_ raw: String, rawInput: String) -> [String] {
    let lines = raw
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var cleaned: [String] = []
    for line in lines {
      var s = line
      if let match = s.range(of: #"^(\d+[\.\、\)]|\-|\*)\s*"#, options: .regularExpression) {
        s.removeSubrange(match)
      }
      s = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if !s.isEmpty, s != rawInput, !cleaned.contains(s) {
        cleaned.append(s)
      }
      if cleaned.count >= 3 { break }
    }
    return cleaned
  }

  func rerankCandidates(
    preContext: String?,
    pinyin: String,
    localCandidates: [String],
    ticket: OwlAICandidateTicket
  ) async throws -> Int? {
    if let customReranker {
      return try await customReranker(preContext, pinyin, localCandidates, ticket)
    }

    if Task.isCancelled { return nil }
    guard localCandidates.count >= 2 else { return nil }

    // Pre-context: up to 100 characters
    let trimmedContext: String? = {
      guard let preContext, !preContext.isEmpty else { return nil }
      return String(preContext.suffix(100))
    }()

    // Local candidates: up to 32 items
    let candidatePool = Array(localCandidates.prefix(32))

    // Check in-memory cache
    let key = Self.cacheKey(preContext: trimmedContext, pinyin: pinyin, candidates: candidatePool)
    let cached = rerankCache.get(key)
    if cached.hit {
      return cached.value
    }

    let auth = await authGateProvider()
    guard case let .ready(routing, apiKey) = auth else {
      return nil
    }

    let systemPrompt = """
      You are a discriminative Chinese input method candidate reranker. \
      Given the preceding text context, pinyin input, and numbered local candidates (c0, c1, ...), \
      select the single most appropriate candidate that fits the context naturally. \
      Respond ONLY with the choice tag (e.g. c0, c1, c2, ...) or 'none' if no change is needed. \
      Do not output explanations, punctuation, quotes, or any other text.
      """

    var userContent = ""
    if let trimmedContext {
      userContent += "Context: \(trimmedContext)\n"
    }
    userContent += "Pinyin: \(pinyin)\n"
    userContent += "Candidates:\n"
    for (i, cand) in candidatePool.enumerated() {
      userContent += "c\(i): \(cand)\n"
    }
    userContent += "none: keep original order"

    let messages = [
      OwlDeepSeekMessage(role: "system", content: systemPrompt),
      OwlDeepSeekMessage(role: "user", content: userContent)
    ]

    let thinkingFields = OwlThinkingControl.offFields(providerID: routing.providerID, model: routing.model)
    let payload = OwlDeepSeekChatRequest(
      model: routing.model,
      messages: messages,
      temperature: 0.0,
      stream: false,
      responseFormat: nil,
      thinking: thinkingFields.thinking,
      enableThinking: thinkingFields.enableThinking,
      reasoningEffort: thinkingFields.reasoningEffort,
      reasoningSplit: thinkingFields.reasoningSplit
    )

    do {
      let rawResponse = try await gateway.complete(
        payload,
        routing: routing,
        apiKey: apiKey,
        purpose: .interactiveRewrite
      )
      if Task.isCancelled { return nil }
      let result = Self.parseRerankResponse(rawResponse, candidateCount: candidatePool.count)
      rerankCache.set(key, value: result)
      return result
    } catch {
      return nil
    }
  }

  static func parseRerankResponse(_ raw: String, candidateCount: Int) -> Int? {
    guard candidateCount > 0 else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.lowercased().contains("none") {
      return nil
    }

    if let match = trimmed.range(of: #"(?i)\bc(\d+)\b"#, options: .regularExpression) {
      let matchedString = String(trimmed[match])
      let digits = matchedString.filter(\.isNumber)
      if let index = Int(digits), index >= 0, index < candidateCount {
        return index
      }
    }

    if let match = trimmed.range(of: #"^\d+$"#, options: .regularExpression),
       let index = Int(trimmed[match]), index >= 0, index < candidateCount {
      return index
    }

    return nil
  }

  static func cacheKey(preContext: String?, pinyin: String, candidates: [String]) -> String {
    let ctx = preContext.map { String($0.suffix(100)) } ?? ""
    return "\(ctx)\u{1E}\(pinyin)\u{1E}\(candidates.joined(separator: "\u{1F}"))"
  }

  func clearRerankCacheForTesting() {
    rerankCache.clear()
  }
}

final class OwlCandidateRerankCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cache: [String: Int?] = [:]
  private var keys: [String] = []
  private let capacity: Int

  init(capacity: Int = 128) {
    self.capacity = capacity
  }

  func get(_ key: String) -> (hit: Bool, value: Int?) {
    lock.lock()
    defer { lock.unlock() }
    if let val = cache[key] {
      return (true, val)
    }
    return (false, nil)
  }

  func set(_ key: String, value: Int?) {
    lock.lock()
    defer { lock.unlock() }
    if cache[key] == nil {
      if keys.count >= capacity {
        let oldest = keys.removeFirst()
        cache.removeValue(forKey: oldest)
      }
      keys.append(key)
    }
    cache[key] = value
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    cache.removeAll()
    keys.removeAll()
  }
}
