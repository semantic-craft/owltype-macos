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

/// 任意提问的完整用例接口：报告是否可用、流式回答，并持续给出真实联网署名。
///
/// The interface intentionally exposes neither provider priority nor Responses dialects. The
/// conversation caller depends on this port directly; provider inference, search types, transport
/// dispatch, failover, and attribution orchestration all remain inside the module.
@MainActor
protocol FamoAskAnythingOpening {
  func readiness() -> FamoStreamingReadiness

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
  static let shared = FamoAskAnythingModule()
  static let defaultWebSearchResultCount = 5

  private let gate: FamoProviderAuthGate
  private let transport: FamoAskAnythingTransporting
  private let searchResolver: FamoAskSearchResolver
  private let isWebSearchEnabled: () -> Bool
  private let preferredWebSearchBackend: () -> FamoWebSearchBackend
  private let webSearchKeyProvider: (FamoWebSearchBackend) -> String?
  private let webSearchClientFactory: (FamoWebSearchBackend) -> FamoWebSearching
  private let webSearchResultCount: Int

  /// Live composition root for 任意提问. Callers receive only `FamoAskAnythingOpening`; all
  /// provider, search, and wire dependencies are assembled here and never cross that boundary.
  convenience init(
    client: FamoChatStreaming? = nil,
    responsesClient: FamoResponsesStreaming? = nil,
    profileProvider: @escaping () -> FamoProviderProfile? = {
      FamoProviderProfileStore.shared.defaultProfile
    },
    profileSecretProvider: @escaping (String) throws -> String? = {
      try FamoProviderKeychain().secret(named: $0)
    },
    legacyKeyProvider: @escaping () throws -> String? = FamoCloudKeychain.readDeepSeekAPIKey,
    searchResolver: FamoAskSearchResolver? = nil,
    isWebSearchEnabled: @escaping () -> Bool = { FamoAskWebSearchSettings.isEnabled },
    preferredWebSearchBackend: (() -> FamoWebSearchBackend)? = nil,
    webSearchKeyProvider: ((FamoWebSearchBackend) -> String?)? = nil,
    webSearchClientFactory: ((FamoWebSearchBackend) -> FamoWebSearching)? = nil
  ) {
    let gate = FamoProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider)
    let transport = FamoAskAnythingTransportAdapter(
      chatClient: client ?? FamoStreamingChatClient(),
      responsesClient: responsesClient ?? FamoResponsesStreamingClient())
    self.init(
      gate: gate,
      transport: transport,
      searchResolver: searchResolver ?? FamoAskSearchResolver(),
      isWebSearchEnabled: isWebSearchEnabled,
      preferredWebSearchBackend: preferredWebSearchBackend ?? {
        FamoWebSearchBackendSettings.backend
      },
      webSearchKeyProvider: webSearchKeyProvider ?? {
        FamoWebSearchKeyStore.apiKey(for: $0)
      },
      webSearchClientFactory: webSearchClientFactory ?? { $0.makeClient() },
      webSearchResultCount: Self.defaultWebSearchResultCount)
  }

  init(
    gate: FamoProviderAuthGate,
    transport: FamoAskAnythingTransporting,
    searchResolver: FamoAskSearchResolver,
    isWebSearchEnabled: @escaping () -> Bool = { FamoAskWebSearchSettings.isEnabled },
    preferredWebSearchBackend: @escaping () -> FamoWebSearchBackend = {
      FamoWebSearchBackendSettings.backend
    },
    webSearchKeyProvider: @escaping (FamoWebSearchBackend) -> String?,
    webSearchClientFactory: @escaping (FamoWebSearchBackend) -> FamoWebSearching = { $0.makeClient() },
    webSearchResultCount: Int = 5
  ) {
    self.gate = gate
    self.transport = transport
    self.searchResolver = searchResolver
    self.isWebSearchEnabled = isWebSearchEnabled
    self.preferredWebSearchBackend = preferredWebSearchBackend
    self.webSearchKeyProvider = webSearchKeyProvider
    self.webSearchClientFactory = webSearchClientFactory
    self.webSearchResultCount = webSearchResultCount
  }

  func readiness() -> FamoStreamingReadiness {
    gate.resolve()
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
    // synchronous opening timing, while the outer stream owns cancellation of the active adapter.
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

  /// 已配好 Key 的独立搜索后端，用户选择只重排、不设门槛。
  ///
  /// 偏好后端缺 Key 时只淘汰它自己；其余已配置后端仍按产品顺位进入同一尝试矩阵。把
  /// 「偏好 + Key」绑成一个可选值会在偏好缺 Key 时错误丢掉所有后端，所以两者必须分开解析。
  private func webSearchBackends() -> [(backend: FamoWebSearchBackend, apiKey: String)] {
    FamoWebSearchBackend.orderedCandidates(preferred: preferredWebSearchBackend()).compactMap { backend in
      guard let rawKey = webSearchKeyProvider(backend) else { return nil }
      let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !apiKey.isEmpty else { return nil }
      return (backend, apiKey)
    }
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
        guard FamoAskSearchFailover.shouldTryNextAttempt(
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
        guard yieldedAnyContent else { throw FamoStreamingError.emptyResponse }
        return continuation.finish()
      } catch {
        if error is CancellationError || Task.isCancelled {
          return continuation.finish(throwing: CancellationError())
        }
        guard FamoAskSearchFailover.shouldTryNextAttempt(
          after: error, hasYieldedDelta: yieldedAnyContent) else {
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
