//
//  OwlAskAnythingModule.swift
//  猫头鹰输入法 (Owltype) — 任意提问 use-case seam
//
//  The caller-facing interface is deliberately tiny: messages in, streamed answer + attribution
//  out. Provider ordering and search failover stay behind this seam; the wire and its dialect are
//  `OwlLLMGateway`'s, and whether a route can search is `OwlProviderCapabilities`'. The use-case
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

/// Adapts the LLM gateway and the DeepSeek search client to the provider-neutral ask port.
///
/// 联网 = DeepSeek Search 接口取回网页 → 编号结果放进 system 消息 → 普通生成作答 → 由结果生成来源
/// 脚注。搜没搜由检索请求本身决定，来源网址只来自检索结果。The module above this type never sees a
/// Responses dialect, which is the boundary issue #107 establishes.
@MainActor
struct OwlAskAnythingTransportAdapter: OwlAskAnythingTransporting {
  private let gateway: OwlLLMGateway
  private let searchClient: OwlDeepSeekSearching
  /// The date the searched system prompt states. Tests pin it so recorded request bodies stay stable.
  private let now: () -> Date

  /// `searchClient` defaults to the DeepSeek search client over the gateway's transport.
  init(
    gateway: OwlLLMGateway = OwlLLMGateway(), searchClient: OwlDeepSeekSearching? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.gateway = gateway
    self.now = now
    let transport = gateway.transport
    self.searchClient = searchClient ?? OwlDeepSeekSearchClient(fetch: { try await transport.send($0) })
  }

  /// Scripted wires for tests; production composes through `init(gateway:searchClient:)`.
  init(
    chatClient: OwlChatStreaming,
    responsesClient: OwlResponsesStreaming,
    searchClient: OwlDeepSeekSearching
  ) {
    self.init(
      gateway: OwlLLMGateway(chatStreamer: chatClient, responsesStreamer: responsesClient),
      searchClient: searchClient)
  }

  func streamPlain(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    gateway.stream(messages: messages, routing: routing, apiKey: apiKey)
  }

  func streamWebSearch(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    guard OwlProviderCapabilities(routing: routing).searchTransport == .deepSeekSearchAPI,
      let endpoint = OwlDeepSeekSearchWire.endpoint(for: routing.endpoint) else { return nil }
    let question = messages.last(where: { $0.role == "user" })?.content ?? ""
    let searchClient = searchClient
    let today = now()
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
            messages: OwlWebSearchGrounding.askMessages(messages, results: results, today: today),
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
  private struct AttemptStep: Decodable { let action: String; let index: Int; let providerID: String? }

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
    legacyKeyProvider: @escaping () throws -> String? = { nil },
    searchResolver: OwlAskSearchResolver? = nil,
    searchClient: OwlDeepSeekSearching? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    let gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider)
    let transport = OwlAskAnythingTransportAdapter(
      gateway: OwlLLMGateway(chatStreamer: client, responsesStreamer: responsesClient),
      searchClient: searchClient, now: now)
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
    let core = try! OwlAppSession("askAttempts", args: ["providers": attempts.map(\.providerID)])
    let plan: AttemptStep = core.call("next")
    guard plan.action == "attempt" else {
      return plainOpen(messages: messages).map {
        OwlAskStreamOpen(stream: $0, searchProviderID: nil)
      }
    }

    let first = attempts[plan.index]
    let attribution = OwlAskAttribution(searchProviderID: plan.providerID)
    // The first route is opened synchronously. Keeping it primed preserves the existing synchronous
    // opening timing, while the outer stream owns cancellation of the active adapter.
    let primed = transport.streamWebSearch(
      messages: messages, routing: first.routing, apiKey: first.apiKey)
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task { [weak self] in
        guard let self else { return continuation.finish() }
        await self.pump(
          core: core,
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
    core: OwlAppSession,
    attempts: [OwlAskSearchRoute],
    primed: AsyncThrowingStream<String, Error>?,
    messages: [OwlDeepSeekMessage],
    attribution: OwlAskAttribution,
    into continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async {
    var step: AttemptStep = core.call("next")
    var lastError: Error?
    while true {
      if Task.isCancelled { let _: AttemptStep = core.call("cancel"); return continuation.finish() }
      attribution.update(searchProviderID: step.providerID)
      switch step.action {
      case "attempt":
        let attempt = attempts[step.index]
        do {
          let inner: AsyncThrowingStream<String, Error>
          if step.index == 0, let primed { inner = primed }
          else { inner = try open(route: attempt, messages: messages) }
          for try await delta in inner {
            try Task.checkCancellation()
            step = core.call("delta")
            continuation.yield(delta)
          }
          step = core.call("complete")
          if step.action == "empty" { return continuation.finish(throwing: OwlStreamingError.emptyResponse) }
          return continuation.finish()
        } catch {
          if error is CancellationError || Task.isCancelled {
            let _: AttemptStep = core.call("cancel")
            return continuation.finish(throwing: CancellationError())
          }
          lastError = error
          step = core.call("failure", OwlAskSearchFailover.facts(error))
        }
      case "plain":
        guard case let .success(plain) = plainOpen(messages: messages) else {
          return continuation.finish(throwing: lastError ?? OwlStreamingError.nonHTTPResponse)
        }
        do {
          for try await delta in plain { try Task.checkCancellation(); continuation.yield(delta) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
        return
      default: return continuation.finish(throwing: lastError ?? OwlStreamingError.nonHTTPResponse)
      }
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
