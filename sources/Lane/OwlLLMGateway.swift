//
//  OwlLLMGateway.swift
//  猫头鹰输入法 (Owltype) — the one way an AI skill reaches a model
//
//  Selection polish and structured drafting used to fork Chat vs `/responses`, build the request,
//  check the status, parse two reply shells and record usage each on their own. That sequence —
//  and every provider quirk inside it — now runs in the Rust provider core through this adapter.
//  Recorded requests cover every caller (see `OwlLLMGatewayTests`). Streaming answers (任意提问,
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
  var sendsChatJSONMode: Bool { OwlProviderCore.call("jsonMode", ["hasSplit": thinkingOff.reasoningSplit != nil]) }

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
    let raw: String = OwlProviderCore.call("searchChannel", ["providerID": providerID, "host": host])
    return raw == "deepSeek" ? .deepSeek : .none
  }

  private static func searchDisplayName(_ channel: OwlSearchControl.Channel) -> String? {
    switch channel {
    case .deepSeek: return "DeepSeek"
    case .none: return nil
    }
  }
}

/// Why an AI skill is calling. It fixes the timeout and retry policy, so callers never pass them.
enum OwlLLMCallPurpose: String {
  /// 划词润色：用户盯着菜单等，8 秒内要有结果；瞬时故障重试一次。
  case interactiveRewrite
  /// 提示词优化 / 任务书：要生成一整段结构化文本，实测百炼 qwen3.6-flash 生成约 1.3KB 中文要
  /// 约 20 秒，8 秒必然掐断。用户已看到「正在优化…」，等十几秒可以接受、卡死不行，故 60 秒硬上限；
  /// 不重试（重来一遍的等待比报错更糟）。
  case drafting
  /// 「验证连通性」：一次真实请求，20 秒；不重试 —— 用户要的是这一发的真实结论。
  case connectivityProbe

  var timeout: TimeInterval {
    struct Policy: Decodable { let timeout: Double }
    let policy: Policy = OwlProviderCore.call("purpose", ["purpose": rawValue])
    return policy.timeout
  }

  var maxAttempts: Int {
    struct Policy: Decodable { let maxAttempts: Int }
    let policy: Policy = OwlProviderCore.call("purpose", ["purpose": rawValue])
    return policy.maxAttempts
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
    let chunks = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(data); continuation.finish()
    }
    return OwlStreamingBytesSource(response: response as? HTTPURLResponse, dataChunks: chunks)
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

  /// Native byte delivery only. The Rust session handles UTF-8 and SSE boundaries.
  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource {
    let (bytes, response) = try await session.bytes(for: request)
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      let task = Task {
        do {
          var chunk = Data()
          for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            // Byte buffering only: retain every byte, including LF. No UTF-8 decoding,
            // SSE fields or event decisions occur in the native transport.
            if chunk.count >= 4096 || byte == 10 {
              continuation.yield(chunk)
              chunk.removeAll(keepingCapacity: true)
            }
          }
          if !chunk.isEmpty { continuation.yield(chunk) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return OwlStreamingBytesSource(response: response as? HTTPURLResponse, dataChunks: stream)
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
    let call = try OwlAppSession("providerCall", args: ["purpose": purpose.rawValue])
    defer { let _: Bool = call.call("cancel") }
    var allowed: Bool = call.call("next")
    while allowed {
      try Task.checkCancellation()
      do {
        return try await completeOnce(payload, routing: routing, apiKey: apiKey, purpose: purpose)
      } catch {
        try Task.checkCancellation()
        allowed = call.call("retry", ["retryable": OwlCloudRetry.isRetryable(error)])
        guard allowed else { throw error }
        try await Task.sleep(nanoseconds: OwlCloudRetry.backoffNanoseconds)
      }
    }
    throw OwlCloudRequestError.emptyResponse
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
    try Task.checkCancellation()
    struct Parsed: Decodable {
      let text: String?
      let usage: OwlCloudUsageSnapshot?
      let error: String?
      let detail: OwlServerErrorDetail?
    }
    let status = (response as? HTTPURLResponse)?.statusCode
    let parsed: Parsed = OwlProviderCore.call("completionParse", ["bytes": Array(data),
      "responses": dialect != nil, "status": status as Any? ?? NSNull(), "model": routing.model])
    if let usage = parsed.usage { OwlCloudUsageTelemetry.record(usage) }
    switch parsed.error {
    case "http": throw OwlCloudRequestError.badHTTPStatus(status!, detail: parsed.detail)
    case "empty": throw OwlCloudRequestError.emptyResponse
    case "malformed": throw OwlResponsesWireError.malformedResponse
    default: return parsed.text ?? ""
    }
  }
}

/// Typed transport for provider rules. Values never enter preferences, files or logs here.
enum OwlProviderCore {
  static func httpAccepted(_ status: Int) -> Bool { call("httpAccepted", ["status": status]) }
  static func call<T: Decodable>(_ rule: String, _ args: [String: Any] = [:]) -> T {
    OwlProviderHost().required("rule", ["rule": rule, "args": args])
  }
  static func object(_ rule: String, _ args: [String: Any] = [:]) -> [String: Any] {
    let value: OwlJSONValue = call(rule, args)
    return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any] ?? [:]
  }
}

/// The only mutable protocol state is the owned Rust session.
final class OwlProviderStream {
  private let session: OwlAppSession
  private struct Reply: Decodable { let deltas: [String]; let isFinished: Bool; let failure: String? }
  private var projection = Reply(deltas: [], isFinished: false, failure: nil)
  init(responses: Bool) { session = try! OwlAppSession("providerStream", args: ["responses": responses]) }
  var isFinished: Bool { projection.isFinished }
  var failure: String? { projection.failure }
  func consume(_ data: Data) -> [String] {
    // Bound only the ABI transfer, never the protocol line or the response. A native
    // callback may contain megabytes, and UTF-8 may split anywhere in these chunks.
    var deltas: [String] = []
    var offset = data.startIndex
    while offset < data.endIndex {
      let end = data.index(offset, offsetBy: min(65_536, data.distance(from: offset, to: data.endIndex)))
      deltas += update("consume", ["bytes": Array(data[offset..<end])])
      offset = end
    }
    return deltas
  }
  func finish() -> [String] { update("finish") }
  func cancel() { _ = update("cancel") }
  private func update(_ event: String, _ args: [String: Any] = [:]) -> [String] {
    do { projection = try session.request(event, args) }
    catch { projection = Reply(deltas: [], isFinished: true, failure: "invalid stream payload") }
    return projection.deltas
  }
}
