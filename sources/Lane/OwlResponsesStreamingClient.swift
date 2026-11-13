//
//  OwlResponsesStreamingClient.swift
//  法墨输入法 (Owltype) — `/responses` 流式传输（Qwen / 豆包 / OpenAI）
//
//  `OwlStreamingChatClient` speaks `/chat/completions`, whose frames are
//  `{"choices":[{"delta":{"content":"…"}}]}`. The Responses API is a DIFFERENT event shape:
//
//      data: {"type":"response.output_text.delta","delta":"…"}   → one delta
//      data: {"type":"response.completed"}                        → end
//      data: {"type":"response.failed","response":{"error":{…}}}  → failure
//      data: [DONE]                                               → end
//
//  Feeding those frames to `OwlSSEChatParser` is not an error — every line simply has no
//  `choices`, so the parser returns nil for all of them and the stream finishes normally with ZERO
//  content. No throw, no crash, no log: the user just gets a blank answer. That silent-empty is
//  the failure this file exists to prevent, and `OwlResponsesStreamingClientTests` pins it.
//
//  Same transport contract as the chat client: injected byte source (no socket in tests), non-2xx
//  finishes the stream with `OwlStreamingError.badHTTPStatus`, cancellation tears the upstream down.
//
//  Off the per-keystroke IMK hot path: Qwen cloud skills and explicit Responses search routes use it.
//

import Foundation

// MARK: - Pure `/responses` SSE parser (the testable core)

/// Stateful, pure (no networking) parser for a Responses-API **streaming** response.
///
/// Mirrors `OwlSSEChatParser`'s interface — `consume(_:)` per network chunk, buffering a partial
/// trailing line across calls, `finish()` to flush — so the client's byte loop is identical for
/// both transports. Only the per-line decision differs.
///
/// Robustness (a stream degrades, never crashes): SSE comments (`:`), blank keepalives, `event:`
/// lines, and the whole reasoning / output-item / content-part scaffolding are ignored. A
/// malformed-JSON `data:` line is skipped. A `response.failed` / `error` frame is NOT ignored — it
/// is recorded in `failure` so the client can finish with a real error instead of an empty answer.
struct OwlResponsesStreamParser {
  private let core = OwlProviderStream(responses: true)
  var isFinished: Bool { core.isFinished }
  var failure: String? { core.failure }
  mutating func consume(_ chunk: String) -> [String] { core.consume(Data(chunk.utf8)) }
  mutating func consume(_ chunk: Data) -> [String] { core.consume(chunk) }
  mutating func finish() -> [String] { core.finish() }
  mutating func cancel() { core.cancel() }
}

// MARK: - Streaming client

/// The narrow `/responses` streaming port. Kept separate from `OwlChatStreaming` on purpose:
/// `OwlLLMGateway.stream` picks the dialect; the caller decides whether this is a plain generation
/// or a built-in search request.
protocol OwlResponsesStreaming: Sendable {
  /// Stream an assistant answer for `messages` over `/responses`. Yields text deltas in order; a
  /// non-2xx status or an upstream `response.failed` finishes the stream with a `OwlStreamingError`.
  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String,
    dialect: OwlResponsesDialect,
    webSearch: Bool
  ) -> AsyncThrowingStream<String, Error>
}

/// Live `/responses` streaming client. Same skeleton as `OwlStreamingChatClient` — only the
/// request body (`OwlResponsesWire`) and the frame parser differ.
struct OwlResponsesStreamingClient: OwlResponsesStreaming {
  /// Per-request timeout (seconds). Longer than plain chat's 30: a search round-trips to the web
  /// before the first token, so the same budget would time out a working request.
  let timeout: TimeInterval
  /// Byte/line source. Default = the gateway transport (`URLSession.bytes` in production);
  /// a test may pass a scripted source instead (no socket).
  private let bytesProvider: @Sendable (URLRequest) async throws -> OwlStreamingBytesSource

  init(
    timeout: TimeInterval = 90,
    transport: OwlLLMTransport = OwlURLSessionTransport(),
    bytesProvider: (@Sendable (URLRequest) async throws -> OwlStreamingBytesSource)? = nil
  ) {
    self.timeout = timeout
    self.bytesProvider = bytesProvider ?? { try await transport.openStream($0) }
  }

  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String,
    dialect: OwlResponsesDialect,
    webSearch: Bool
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(
            messages: messages, routing: routing, apiKey: apiKey,
            dialect: dialect, webSearch: webSearch)
          let source = try await bytesProvider(request)

          if let http = source.response, !OwlProviderCore.httpAccepted(http.statusCode) {
            let detail = await OwlServerErrorDetail.read(source.dataChunks)
            continuation.finish(throwing: OwlStreamingError.badHTTPStatus(http.statusCode, detail: detail))
            return
          }

          var parser = OwlResponsesStreamParser()
          defer { parser.cancel() }
          for try await chunk in source.dataChunks {
            try Task.checkCancellation()
            for delta in parser.consume(chunk) {
              continuation.yield(delta)
            }
            if parser.isFinished { break }
          }
          // Flush any trailing line the upstream left without a closing newline.
          if !parser.isFinished {
            for delta in parser.finish() {
              continuation.yield(delta)
            }
          }
          // A `response.failed` frame must surface as an error — otherwise the answer is blank and
          // the window shows a successful empty reply.
          if let failure = parser.failure {
            continuation.finish(throwing: OwlStreamingError.upstreamFailure(failure))
            return
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Build the streaming `/responses` POST. The endpoint comes from the profile's chat URL,
  /// rewritten by `OwlResponsesWire.url`; an un-rewritable endpoint throws rather than silently
  /// posting a Responses body at `/chat/completions`.
  private func makeRequest(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String,
    dialect: OwlResponsesDialect,
    webSearch: Bool
  ) throws -> URLRequest {
    guard let url = OwlResponsesWire.url(from: routing.endpoint) else {
      throw OwlStreamingError.invalidEndpoint
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    routing.authHeaderStyle.apply(to: &request, apiKey: apiKey)
    request.timeoutInterval = timeout
    request.httpBody = try JSONSerialization.data(
      withJSONObject: OwlResponsesWire.body(
        model: routing.model,
        messages: messages,
        stream: true,
        dialect: dialect,
        webSearch: webSearch,
        temperature: 0.2
      )
    )
    return request
  }
}
