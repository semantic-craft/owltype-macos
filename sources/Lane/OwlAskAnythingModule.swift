//
//  OwlAskAnythingModule.swift
//  猫头鹰输入法 (Owltype) — 任意提问 use-case seam
//
//  The caller-facing interface is deliberately tiny: messages in, streamed answer + attribution
//  out. Provider ordering, search failover, and Responses dialect selection stay behind this seam.
//  `OwlResponsesStreamingClient` is consumed only by the transport adapter below; the use-case
//  module asks for plain generation or a searched answer without knowing either wire dialect.
//

import Foundation

// MARK: - Caller seam

/// 任意提问的完整用例接口：报告是否可用、流式回答，并持续给出真实联网署名。
///
/// The interface intentionally exposes neither provider priority nor Responses dialects. The
/// conversation caller depends on this port directly; provider inference, search types, transport
/// dispatch, failover, and attribution orchestration all remain inside the module.
@MainActor
protocol OwlAskAnythingOpening {
  func readiness() -> OwlStreamingReadiness

  func open(
    messages: [OwlDeepSeekMessage]
  ) -> Result<OwlAskStreamOpen, OwlStreamingReadiness>
}

// MARK: - Provider-neutral transport port

/// The two operations the ask use case needs from transport. A caller says only whether it wants a
/// plain answer or a searched one; the adapter owns chat-vs-Responses, search and every dialect.
@MainActor
protocol OwlAskAnythingTransporting {
  func streamPlain(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>

  /// nil means this routing cannot search. No request is sent.
  func streamWebSearch(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>?
}

/// Adapts the existing chat and Responses transports to the provider-neutral ask port.
///
/// 联网 = DeepSeek Search 接口取回网页 → 编号结果放进 system 消息 → 普通生成作答 → 由结果生成来源
/// 脚注。搜没搜由检索请求本身决定，来源网址只来自检索结果。The module above this type never sees a
/// Responses dialect, which is the boundary issue #107 establishes.
@MainActor
struct OwlAskAnythingTransportAdapter: OwlAskAnythingTransporting {
  private let chatClient: OwlChatStreaming
  private let responsesClient: OwlResponsesStreaming
  private let searchClient: OwlDeepSeekSearching

  init(
    chatClient: OwlChatStreaming,
    responsesClient: OwlResponsesStreaming,
    searchClient: OwlDeepSeekSearching
  ) {
    self.chatClient = chatClient
    self.responsesClient = responsesClient
    self.searchClient = searchClient
  }

  func streamPlain(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    if let dialect = OwlResponsesWire.dialect(
      providerID: routing.providerID, model: routing.model, endpoint: routing.endpoint) {
      return responsesClient.stream(
        messages: messages,
        routing: routing,
        apiKey: apiKey,
        dialect: dialect,
        webSearch: false)
    }
    return chatClient.stream(messages: messages, routing: routing, apiKey: apiKey)
  }

  func streamWebSearch(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    guard OwlSearchControl.transport(
      providerID: routing.providerID, host: routing.endpoint.host ?? "") == .deepSeekSearchAPI,
      let endpoint = OwlDeepSeekSearchWire.endpoint(for: routing.endpoint) else { return nil }
    let question = messages.last(where: { $0.role == "user" })?.content ?? ""
    let searchClient = searchClient
    return AsyncThrowingStream { continuation in
      let task = Task { @MainActor in
        do {
          let results: [OwlWebSearchResult]
          do {
            results = try await searchClient.search(
              query: question, endpoint: endpoint, apiKey: apiKey,
              limit: OwlWebSearchGrounding.askResultCount)
          } catch let OwlDeepSeekSearchError.badHTTPStatus(status) {
            // 与作答请求同一种错误：401/402/404 照样触发换下一个 DeepSeek 档案。
            throw OwlStreamingError.badHTTPStatus(status)
          } catch is OwlDeepSeekSearchError {
            throw OwlStreamingError.upstreamFailure("DeepSeek 搜索返回了无法解析的结果")
          }
          var answer = ""
          for try await delta in streamPlain(
            messages: OwlWebSearchGrounding.askMessages(messages, results: results),
            routing: routing, apiKey: apiKey) {
            try Task.checkCancellation()
            answer += delta
            continuation.yield(delta)
          }
          let footer = OwlWebSearchGrounding.sourcesFooter(results, answer: answer)
          if !answer.isEmpty, !footer.isEmpty { continuation.yield(footer) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

// MARK: - Use-case module

/// 任意提问的用例模块。It owns attempt planning, pre-content failover, plain fallback, streaming,
/// cancellation propagation, and attribution updates; transports remain injected adapters.
@MainActor
final class OwlAskAnythingModule: OwlAskAnythingOpening {
  static let shared = OwlAskAnythingModule()

  private let gate: OwlProviderAuthGate
  private let transport: OwlAskAnythingTransporting
  private let searchResolver: OwlAskSearchResolver

  /// Live composition root for 任意提问. Callers receive only `OwlAskAnythingOpening`; all
  /// provider, search, and wire dependencies are assembled here and never cross that boundary.
  convenience init(
    client: OwlChatStreaming? = nil,
    responsesClient: OwlResponsesStreaming? = nil,
    profileProvider: @escaping () -> OwlProviderProfile? = {
      OwlProviderProfileStore.shared.defaultProfile
    },
    profileSecretProvider: @escaping (String) throws -> String? = {
      try OwlProviderKeychain().secret(named: $0)
    },
    legacyKeyProvider: @escaping () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
    searchResolver: OwlAskSearchResolver? = nil,
    searchClient: OwlDeepSeekSearching? = nil
  ) {
    let gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider)
    let transport = OwlAskAnythingTransportAdapter(
      chatClient: client ?? OwlStreamingChatClient(),
      responsesClient: responsesClient ?? OwlResponsesStreamingClient(),
      searchClient: searchClient ?? OwlDeepSeekSearchClient())
    self.init(
      gate: gate,
      transport: transport,
      searchResolver: searchResolver ?? OwlAskSearchResolver())
  }

  init(
    gate: OwlProviderAuthGate,
    transport: OwlAskAnythingTransporting,
    searchResolver: OwlAskSearchResolver
  ) {
    self.gate = gate
    self.transport = transport
    self.searchResolver = searchResolver
  }

  func readiness() -> OwlStreamingReadiness {
    gate.resolve()
  }

  func open(
    messages: [OwlDeepSeekMessage]
  ) -> Result<OwlAskStreamOpen, OwlStreamingReadiness> {
    let attempts = searchResolver.resolveAll()
    guard let first = attempts.first else {
      return plainOpen(messages: messages).map {
        OwlAskStreamOpen(stream: $0, searchProviderID: nil)
      }
    }

    let attribution = OwlAskAttribution(searchProviderID: first.providerID)
    // The first route is opened synchronously. Keeping it primed preserves the existing synchronous
    // opening timing, while the outer stream owns cancellation of the active adapter.
    let primed = transport.streamWebSearch(
      messages: messages, routing: first.routing, apiKey: first.apiKey)
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task { [weak self] in
        guard let self else { return continuation.finish() }
        await self.pump(
          attempts: attempts,
          primed: primed,
          messages: messages,
          attribution: attribution,
          into: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return .success(OwlAskStreamOpen(stream: stream, attribution: attribution))
  }

  /// 逐家尝试到首个 delta；一旦有内容，后续失败不能换家，避免拼出两家各半的答案。
  private func pump(
    attempts: [OwlAskSearchRoute],
    primed: AsyncThrowingStream<String, Error>?,
    messages: [OwlDeepSeekMessage],
    attribution: OwlAskAttribution,
    into continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async {
    var primed = primed
    var lastError: Error?

    for (index, attempt) in attempts.enumerated() {
      if Task.isCancelled { return continuation.finish() }
      attribution.update(searchProviderID: attempt.providerID)

      let inner: AsyncThrowingStream<String, Error>
      do {
        if index == 0, let ready = primed {
          inner = ready
        } else {
          inner = try open(route: attempt, messages: messages)
        }
      } catch {
        if error is CancellationError || Task.isCancelled {
          return continuation.finish(throwing: CancellationError())
        }
        guard OwlAskSearchFailover.shouldTryNextAttempt(
          after: error, hasYieldedDelta: false) else {
          return continuation.finish(throwing: error)
        }
        lastError = error
        continue
      }
      primed = nil

      var yieldedAnyContent = false
      do {
        for try await delta in inner {
          try Task.checkCancellation()
          yieldedAnyContent = true
          continuation.yield(delta)
        }
        guard yieldedAnyContent else { throw OwlStreamingError.emptyResponse }
        return continuation.finish()
      } catch {
        if error is CancellationError || Task.isCancelled {
          return continuation.finish(throwing: CancellationError())
        }
        guard OwlAskSearchFailover.shouldTryNextAttempt(
          after: error, hasYieldedDelta: yieldedAnyContent) else {
          return continuation.finish(throwing: error)
        }
        lastError = error
      }
    }

    // Every online route was unusable. Fall back to plain ask and remove the online signature.
    attribution.update(searchProviderID: nil)
    guard case let .success(plain) = plainOpen(messages: messages) else {
      return continuation.finish(throwing: lastError ?? OwlStreamingError.nonHTTPResponse)
    }
    do {
      for try await delta in plain {
        try Task.checkCancellation()
        continuation.yield(delta)
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func open(
    route: OwlAskSearchRoute,
    messages: [OwlDeepSeekMessage]
  ) throws -> AsyncThrowingStream<String, Error> {
    try Task.checkCancellation()
    guard let stream = transport.streamWebSearch(
      messages: messages, routing: route.routing, apiKey: route.apiKey) else {
      throw OwlStreamingError.invalidEndpoint
    }
    return stream
  }

  private func plainOpen(
    messages: [OwlDeepSeekMessage]
  ) -> Result<AsyncThrowingStream<String, Error>, OwlStreamingReadiness> {
    switch gate.resolve() {
    case let .ready(routing, apiKey):
      return .success(transport.streamPlain(
        messages: messages, routing: routing, apiKey: apiKey))
    case .unconfigured:
      return .failure(.unconfigured)
    case .missingKey:
      return .failure(.missingKey)
    }
  }
}
