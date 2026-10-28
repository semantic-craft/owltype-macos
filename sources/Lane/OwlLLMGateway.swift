//
//  OwlLLMGateway.swift
//  猫头鹰输入法 (Owltype) — the one way an AI skill reaches a model
//
//  Selection polish and structured drafting used to fork Chat vs `/responses`, build the request,
//  check the status, parse two reply shells and record usage each on their own. That sequence —
//  and every provider quirk inside it — now lives here, above a transport seam, so one table of
//  recorded requests covers every caller (see `OwlLLMGatewayTests`). Streaming answers (任意提问,
//  plain generation) take the same fork through `stream(messages:routing:apiKey:)`; their table is
//  `OwlLLMStreamingRecordingTests`.
//
//  Never reachable from the input hot path: `scripts/check-ai-off-hot-path.sh` fails the gate if
//  `sources/Controller` or `sources/Engine` names this file's types or `URLSession`.
//

import Foundation

/// What a provider profile's wire supports, resolved once from `(providerID, model, host)`.
/// Callers ask this value instead of re-deriving provider identity.
struct OwlProviderCapabilities {
  /// The `/responses` dialect, or nil when the provider stays on Chat Completions.
  let dialect: OwlResponsesDialect?
  /// The provider's lowest-latency thinking fields for Chat requests (`OwlThinkingControl`).
  let thinkingOff: OwlThinkingControl.Fields
  /// Which 任意提问 联网 search applies. `.none` = this provider cannot search.
  let searchChannel: OwlSearchControl.Channel
  let model: String

  /// `endpoint` is nil for a request builder that has no URL (the Chat payload) or a form without
  /// one; provider id then decides alone, exactly as the host fallback would with no host.
  init(providerID: String, model: String, endpoint: URL? = nil) {
    self.dialect = OwlResponsesWire.dialect(providerID: providerID, model: model, endpoint: endpoint)
    self.thinkingOff = OwlThinkingControl.offFields(providerID: providerID, model: model)
    self.searchChannel = Self.searchChannel(providerID: providerID, host: endpoint?.host ?? "")
    self.model = model
  }

  init(routing: OwlCloudRouting) {
    self.init(providerID: routing.providerID, model: routing.model, endpoint: routing.endpoint)
  }

  /// Chat `response_format: json_object`. MiniMax documents no JSON mode; keep prompt + local
  /// validation as the contract there.
  var sendsChatJSONMode: Bool { thinkingOff.reasoningSplit == nil }

  /// The sampling temperature to send, or nil when the model rejects sampling controls.
  func temperature(_ value: Double) -> Double? {
    OwlChatSamplingControl.temperature(value, model: model)
  }

  /// `thinkingOff` as top-level JSON fields, merged onto an encoded Chat body.
  var thinkingOffBody: [String: Any] { OwlThinkingControl.offBody(thinkingOff) }

  /// How this provider's search is carried; the ask adapter dispatches on it.
  var searchTransport: OwlSearchControl.Transport {
    switch searchChannel {
    case .deepSeek: return .deepSeekSearchAPI
    case .none: return .none
    }
  }

  /// 面向用户的联网署名名。非可联网 → nil。
  var searchDisplayName: String? { Self.searchDisplayName(searchChannel) }

  /// The profile 任意提问 联网 answers with on the official endpoint; settings copy names it.
  static let askSearch = OwlProviderCapabilities(
    providerID: OwlSearchControl.searchProviderID, model: OwlSearchControl.searchModel)

  /// The 署名 name for a provider id alone (the window knows only who answered, not the host).
  static func searchDisplayName(providerID: String) -> String? {
    searchDisplayName(searchChannel(providerID: providerID, host: ""))
  }

  /// `providerID` wins; `host` is the fallback for a custom profile whose id was never stamped —
  /// same precedence as `OwlLLMProviderCatalog.inferredProviderID`.
  static func searchChannel(providerID: String, host: String) -> OwlSearchControl.Channel {
    if providerID.lowercased() == OwlSearchControl.searchProviderID { return .deepSeek }
    return host.lowercased().contains("deepseek") ? .deepSeek : .none
  }

  private static func searchDisplayName(_ channel: OwlSearchControl.Channel) -> String? {
    switch channel {
    case .deepSeek: return "DeepSeek"
    case .none: return nil
    }
  }
}

/// Why an AI skill is calling. It fixes the timeout and retry policy, so callers never pass them.
enum OwlLLMCallPurpose {
  /// 划词润色：用户盯着菜单等，8 秒内要有结果；瞬时故障重试一次。
  case interactiveRewrite
  /// 提示词优化 / 任务书：要生成一整段结构化文本，实测百炼 qwen3.6-flash 生成约 1.3KB 中文要
  /// 约 20 秒，8 秒必然掐断。用户已看到「正在优化…」，等十几秒可以接受、卡死不行，故 60 秒硬上限；
  /// 不重试（重来一遍的等待比报错更糟）。
  case drafting
  /// 「验证连通性」：一次真实请求，20 秒；不重试 —— 用户要的是这一发的真实结论。
  case connectivityProbe

  var timeout: TimeInterval {
    switch self {
    case .interactiveRewrite: return OwlCloudPreferences.requestTimeout
    case .drafting: return 60
    case .connectivityProbe: return 20
    }
  }

  var maxAttempts: Int {
    switch self {
    case .interactiveRewrite: return OwlCloudRetry.maxAttempts
    case .drafting, .connectivityProbe: return 1
    }
  }
}

/// The seam under the gateway: send one request, return the bytes and the response; or open one
/// and return its body as text chunks as they arrive.
/// Adapters: `OwlURLSessionTransport` in production, a recording fake in tests.
protocol OwlLLMTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, URLResponse)
  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource
}

extension OwlLLMTransport {
  /// A fake that only answers `send` streams its whole reply as one chunk; the SSE parsers
  /// re-frame chunks into lines, so this behaves like a fast socket.
  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource {
    let (data, response) = try await send(request)
    let text = String(decoding: data, as: UTF8.self)
    let chunks = AsyncThrowingStream<String, Error> { continuation in
      continuation.yield(text)
      continuation.finish()
    }
    return OwlStreamingBytesSource(response: response as? HTTPURLResponse, chunks: chunks)
  }
}

struct OwlURLSessionTransport: OwlLLMTransport {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }

  /// `URLSession.bytes(for:)` → an async line iterator re-emitted as `\n`-terminated text chunks,
  /// so the parsers' chunk-boundary buffering is exercised identically to a raw socket.
  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource {
    let (bytes, response) = try await session.bytes(for: request)
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for try await line in bytes.lines {
            // `.lines` strips the newline; restore it so the parser frames events correctly.
            continuation.yield(line + "\n")
            if Task.isCancelled { break }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return OwlStreamingBytesSource(response: response as? HTTPURLResponse, chunks: stream)
  }
}

/// One JSON-mode completion for a non-streaming AI skill, or one streamed free-text answer.
/// Resolves provider capabilities, picks the Chat or `/responses` wire, applies the purpose's timeout
/// and retry, parses either reply shell and records usage telemetry — model name and token counts
/// only, never text.
struct OwlLLMGateway: Sendable {
  let transport: OwlLLMTransport
  /// The two streaming wires. Default: built over `transport`; tests may inject scripted ones.
  private let chatStreamer: OwlChatStreaming
  private let responsesStreamer: OwlResponsesStreaming

  init(
    transport: OwlLLMTransport = OwlURLSessionTransport(),
    chatStreamer: OwlChatStreaming? = nil,
    responsesStreamer: OwlResponsesStreaming? = nil
  ) {
    self.transport = transport
    self.chatStreamer = chatStreamer ?? OwlStreamingChatClient(transport: transport)
    self.responsesStreamer = responsesStreamer ?? OwlResponsesStreamingClient(transport: transport)
  }

  /// Streams a free-text answer (no JSON mode, no built-in search) over whichever wire the
  /// provider speaks. Cancelling the consuming task tears the upstream down.
  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    if let dialect = OwlProviderCapabilities(routing: routing).dialect {
      return responsesStreamer.stream(
        messages: messages, routing: routing, apiKey: apiKey, dialect: dialect, webSearch: false)
    }
    return chatStreamer.stream(messages: messages, routing: routing, apiKey: apiKey)
  }

  /// Returns the model's reply text. `payload` is the skill's Chat-shaped request; the Responses
  /// providers reuse its messages and temperature. Cancelling the calling task cancels the request
  /// and any pending retry.
  func complete(
    _ payload: OwlDeepSeekChatRequest,
    routing: OwlCloudRouting,
    apiKey: String,
    purpose: OwlLLMCallPurpose
  ) async throws -> String {
    var lastError: Error = OwlCloudRequestError.emptyResponse
    for attempt in 0..<purpose.maxAttempts {
      do {
        return try await completeOnce(payload, routing: routing, apiKey: apiKey, purpose: purpose)
      } catch {
        lastError = error
        guard attempt + 1 < purpose.maxAttempts, OwlCloudRetry.isRetryable(error) else { throw error }
        try await Task.sleep(nanoseconds: OwlCloudRetry.backoffNanoseconds)
      }
    }
    throw lastError
  }

  private func completeOnce(
    _ payload: OwlDeepSeekChatRequest,
    routing: OwlCloudRouting,
    apiKey: String,
    purpose: OwlLLMCallPurpose
  ) async throws -> String {
    let dialect = OwlProviderCapabilities(routing: routing).dialect
    let request: URLRequest
    if let dialect {
      request = try OwlResponsesWire.request(
        endpoint: routing.endpoint,
        model: routing.model,
        messages: payload.messages,
        apiKey: apiKey,
        authHeaderStyle: routing.authHeaderStyle,
        dialect: dialect,
        stream: false,
        webSearch: false,
        // Mirrors the Chat payload's `response_format`. Only the `.deepseek` dialect writes
        // `text.format`; Qwen / 豆包 never carried it on Responses (see `OwlResponsesWire.body`).
        jsonObject: true,
        temperature: payload.temperature,
        timeout: purpose.timeout)
    } else {
      var chatRequest = URLRequest(url: routing.endpoint)
      chatRequest.httpMethod = "POST"
      chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      routing.authHeaderStyle.apply(to: &chatRequest, apiKey: apiKey)
      chatRequest.timeoutInterval = purpose.timeout
      chatRequest.httpBody = try JSONEncoder().encode(payload)
      request = chatRequest
    }

    let (data, response) = try await transport.send(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw OwlCloudRequestError.badHTTPStatus(http.statusCode)
    }

    if dialect != nil {
      let decoded = try OwlResponsesWire.parse(data)
      if let usage = decoded.usage {
        OwlCloudUsageTelemetry.record(OwlCloudUsageSnapshot(
          model: decoded.model ?? routing.model,
          completionTokens: usage.outputTokens,
          promptTokens: usage.inputTokens,
          promptCacheHitTokens: usage.cachedTokens,
          promptCacheMissTokens: max(0, usage.inputTokens - usage.cachedTokens),
          totalTokens: usage.totalTokens))
      }
      guard !decoded.text.isEmpty else { throw OwlCloudRequestError.emptyResponse }
      return decoded.text
    }

    let decoded = try JSONDecoder().decode(OwlDeepSeekClient.Response.self, from: data)
    if let usage = decoded.usage {
      OwlCloudUsageTelemetry.record(OwlCloudUsageSnapshot(
        model: decoded.model ?? routing.model,
        completionTokens: usage.completionTokens,
        promptTokens: usage.promptTokens,
        promptCacheHitTokens: usage.promptCacheHitTokens ?? 0,
        promptCacheMissTokens: usage.promptCacheMissTokens ?? 0,
        totalTokens: usage.totalTokens))
    }
    guard let content = decoded.choices.first?.message.content else {
      throw OwlCloudRequestError.emptyResponse
    }
    return content
  }
}
