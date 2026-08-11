//
//  FamoAskAnythingModule.swift
//  法墨输入法 (Famo) — 任意提问 use-case seam
//
//  The caller-facing interface is deliberately tiny: messages in, streamed answer + attribution
//  out. Provider ordering, search failover, and Responses dialect selection stay behind this seam.
//  `FamoResponsesStreamingClient` is consumed only by the transport adapter below; the use-case
//  module asks for plain generation or built-in search without knowing either wire dialect.
//

import Foundation

// MARK: - Caller seam

/// 任意提问的完整用例接口：规划可用尝试、流式回答，并持续给出真实联网署名。
///
/// The interface intentionally exposes neither provider priority nor Responses dialects. The
/// conversation caller remains on `FamoStreamingChatService.openAsk` until issue #119; that method
/// delegates here without changing its existing contract.
@MainActor
protocol FamoAskAnythingOpening {
  func open(
    messages: [FamoDeepSeekMessage]
  ) -> Result<FamoAskStreamOpen, FamoStreamingReadiness>
}

// MARK: - Provider-neutral transport port

/// The two operations the ask use case needs from transport. A caller says only whether it wants a
/// plain answer or a model's built-in search; the adapter owns chat-vs-Responses and every dialect.
@MainActor
protocol FamoAskAnythingTransporting {
  func streamPlain(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>

  /// nil means this routing cannot actually perform built-in search. No request is sent.
  func streamBuiltInSearch(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>?
}

/// Adapts the existing chat and Responses transports to the provider-neutral ask port.
///
/// Qwen's built-in search lands here as a `/responses` request with `webSearch = true`; plain Qwen
/// generation uses the same adapter with `webSearch = false`. The module above this type never sees
/// `.qwen` (or any other Responses dialect), which is the boundary issue #107 establishes.
@MainActor
struct FamoAskAnythingTransportAdapter: FamoAskAnythingTransporting {
  private let chatClient: FamoChatStreaming
  private let responsesClient: FamoResponsesStreaming

  init(chatClient: FamoChatStreaming, responsesClient: FamoResponsesStreaming) {
    self.chatClient = chatClient
    self.responsesClient = responsesClient
  }

  func streamPlain(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    if let dialect = FamoResponsesWire.dialect(
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

  func streamBuiltInSearch(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    switch FamoSearchControl.transport(
      providerID: routing.providerID,
      host: routing.endpoint.host ?? "",
      model: routing.model
    ) {
    case .chatCompletions:
      return chatClient.stream(
        messages: messages,
        routing: routing,
        apiKey: apiKey,
        extraBody: FamoSearchControl.extraBody(
          providerID: routing.providerID, host: routing.endpoint.host ?? ""))
    case let .responses(dialect):
      return responsesClient.stream(
        messages: messages,
        routing: routing,
        apiKey: apiKey,
        dialect: dialect,
        webSearch: true)
    case .none:
      return nil
    }
  }
}

// MARK: - Attempt plan

/// 一次可尝试的联网候选。两种形态在怎么拿到网页上根本不同，所以是类型而不是约定：
///   - `.grounded`：独立搜索服务先检索，结果注入后由默认供应商作答；
///   - `.builtIn`：模型自己的联网工具，检索与作答在同一次请求里。
private enum FamoAskAttempt {
  case grounded(
    backend: FamoWebSearchBackend,
    searchKey: String,
    query: String,
    routing: FamoCloudRouting,
    apiKey: String)
  case builtIn(FamoAskSearchRoute)

  /// 署名 chip 上写谁。`.grounded` 写检索方，`.builtIn` 写联网作答方。
  var attributionID: String {
    switch self {
    case let .grounded(backend, _, _, _, _): return backend.attributionID
    case let .builtIn(route):                return route.providerID
    }
  }
}

// MARK: - Use-case module

/// 任意提问的用例模块。It owns attempt planning, pre-content failover, plain fallback, streaming,
/// cancellation propagation, and attribution updates; transports remain injected adapters.
@MainActor
final class FamoAskAnythingModule: FamoAskAnythingOpening {
  private let gate: FamoProviderAuthGate
  private let transport: FamoAskAnythingTransporting
  private let searchResolver: FamoAskSearchResolver
  private let isWebSearchEnabled: () -> Bool
  private let webSearchProvider: () -> (backend: FamoWebSearchBackend, apiKey: String)?
  private let webSearchKeyProvider: (FamoWebSearchBackend) -> String?
  private let webSearchClientFactory: (FamoWebSearchBackend) -> FamoWebSearching
  private let webSearchResultCount: Int

  init(
    gate: FamoProviderAuthGate,
    transport: FamoAskAnythingTransporting,
    searchResolver: FamoAskSearchResolver,
    isWebSearchEnabled: @escaping () -> Bool = { FamoAskWebSearchSettings.isEnabled },
    webSearchProvider: @escaping () -> (backend: FamoWebSearchBackend, apiKey: String)?,
    webSearchKeyProvider: @escaping (FamoWebSearchBackend) -> String?,
    webSearchClientFactory: @escaping (FamoWebSearchBackend) -> FamoWebSearching = { $0.makeClient() },
    webSearchResultCount: Int = 5
  ) {
    self.gate = gate
    self.transport = transport
    self.searchResolver = searchResolver
    self.isWebSearchEnabled = isWebSearchEnabled
    self.webSearchProvider = webSearchProvider
    self.webSearchKeyProvider = webSearchKeyProvider
    self.webSearchClientFactory = webSearchClientFactory
    self.webSearchResultCount = webSearchResultCount
  }

  func open(
    messages: [FamoDeepSeekMessage]
  ) -> Result<FamoAskStreamOpen, FamoStreamingReadiness> {
    let attempts = askAttempts(messages: messages)
    guard let first = attempts.first else {
      return plainOpen(messages: messages).map {
        FamoAskStreamOpen(stream: $0, searchProviderID: nil)
      }
    }

    let attribution = FamoAskAttribution(searchProviderID: first.attributionID)
    // A built-in route can be opened synchronously. Keeping it primed preserves the existing
    // openAsk timing, while the outer stream owns cancellation of the active adapter.
    let primed = openImmediately(attempt: first, messages: messages)
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
    return .success(FamoAskStreamOpen(stream: stream, attribution: attribution))
  }

  /// 这一问可以依次尝试的联网候选。独立搜索层在前，模型内置联网在后；具体 provider
  /// 顺位完全封装在 resolver/module 内，不穿过 caller seam。
  private func askAttempts(messages: [FamoDeepSeekMessage]) -> [FamoAskAttempt] {
    guard isWebSearchEnabled() else { return [] }
    var attempts: [FamoAskAttempt] = []
    if let query = FamoWebSearchContext.query(from: messages),
       case let .ready(routing, apiKey) = gate.resolve() {
      for backend in webSearchBackends() {
        attempts.append(.grounded(
          backend: backend.backend,
          searchKey: backend.apiKey,
          query: query,
          routing: routing,
          apiKey: apiKey))
      }
    }
    attempts.append(contentsOf: searchResolver.resolveAll().map(FamoAskAttempt.builtIn))
    return attempts
  }

  /// 已配好 Key 的搜索后端，用户选中的后端排第一；其他已配置后端随后。
  private func webSearchBackends() -> [(backend: FamoWebSearchBackend, apiKey: String)] {
    guard let selected = webSearchProvider() else { return [] }
    var output = [selected]
    for backend in FamoWebSearchBackend.allCases where backend != selected.backend {
      if let key = webSearchKeyProvider(backend) {
        output.append((backend, key))
      }
    }
    return output
  }

  /// 逐家尝试到首个 delta；一旦有内容，后续失败不能换家，避免拼出两家各半的答案。
  private func pump(
    attempts: [FamoAskAttempt],
    primed: AsyncThrowingStream<String, Error>?,
    messages: [FamoDeepSeekMessage],
    attribution: FamoAskAttribution,
    into continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async {
    var primed = primed
    var lastError: Error?

    for (index, attempt) in attempts.enumerated() {
      if Task.isCancelled { return continuation.finish() }
      attribution.update(searchProviderID: attempt.attributionID)

      let inner: AsyncThrowingStream<String, Error>
      do {
        if index == 0, let ready = primed {
          inner = ready
        } else {
          inner = try await open(attempt: attempt, messages: messages)
        }
      } catch {
        if error is CancellationError || Task.isCancelled {
          return continuation.finish(throwing: CancellationError())
        }
        guard FamoAskSearchFailover.shouldTryNextProvider(after: error) else {
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
        return continuation.finish()
      } catch {
        if error is CancellationError || Task.isCancelled {
          return continuation.finish(throwing: CancellationError())
        }
        guard !yieldedAnyContent,
              FamoAskSearchFailover.shouldTryNextProvider(after: error) else {
          return continuation.finish(throwing: error)
        }
        lastError = error
      }
    }

    // Every online route was unusable. Fall back to plain ask and remove the online signature.
    attribution.update(searchProviderID: nil)
    guard case let .success(plain) = plainOpen(messages: messages) else {
      return continuation.finish(throwing: lastError ?? FamoStreamingError.nonHTTPResponse)
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

  /// Built-in routes do not need an async search phase and retain the existing synchronous open.
  private func openImmediately(
    attempt: FamoAskAttempt,
    messages: [FamoDeepSeekMessage]
  ) -> AsyncThrowingStream<String, Error>? {
    guard case let .builtIn(route) = attempt else { return nil }
    return transport.streamBuiltInSearch(
      messages: messages, routing: route.routing, apiKey: route.apiKey)
  }

  private func open(
    attempt: FamoAskAttempt,
    messages: [FamoDeepSeekMessage]
  ) async throws -> AsyncThrowingStream<String, Error> {
    try Task.checkCancellation()
    switch attempt {
    case let .grounded(backend, searchKey, query, routing, apiKey):
      let results = try await webSearchClientFactory(backend).search(
        query: query, apiKey: searchKey, limit: webSearchResultCount)
      try Task.checkCancellation()
      guard !results.isEmpty else { throw FamoWebSearchError.noResults }
      return transport.streamPlain(
        messages: FamoWebSearchContext.injecting(results: results, into: messages),
        routing: routing,
        apiKey: apiKey)
    case let .builtIn(route):
      guard let stream = transport.streamBuiltInSearch(
        messages: messages, routing: route.routing, apiKey: route.apiKey) else {
        throw FamoWebSearchError.invalidEndpoint
      }
      return stream
    }
  }

  private func plainOpen(
    messages: [FamoDeepSeekMessage]
  ) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
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
