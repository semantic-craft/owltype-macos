//
//  OwlStreamingChatClient.swift
//  猫头鹰输入法 (Owltype) — OpenAI-compatible STREAMING chat transport (roadmap B9, streaming half)
//
//  This is the token-by-token transport the B10 AI conversation window will consume. Owltype's
//  existing provider stack (OwlDeepSeekCloudLane) is request/response only (`stream: false`,
//  `URLSession.data(for:)`). This file adds a `stream: true` path that yields assistant content
//  deltas as an `AsyncThrowingStream<String, Error>`, reusing the multi-provider profile +
//  keychain foundation (`OwlCloudRouting`, `OwlProviderProfileStore`, `OwlProviderKeychain`,
//  `OwlDeepSeekMessage`) BY REFERENCE only.
//
//  TRANSPORT ONLY. This client sends whatever messages it is given. Building the messages (the
//  context assembly) is the CALLER's responsibility — B10 must assemble them BEFORE handing them
//  here. B9 is simply the transport, not a content-policy site.
//
//  Off the IMK hot path: nothing in `processKey` / `handle` calls this — an explicit AI trigger does.
//

import Foundation

// MARK: - Errors

/// Typed failures for the streaming transport. Kept separate from `OwlCloudRequestError` so the
/// streaming chat path (a free-text answer) and the candidate path (a list) never share an error space.
enum OwlStreamingError: Error, Equatable {
  /// The HTTP response was non-2xx. The stream finishes with this instead of yielding garbage.
  /// `detail` is what the error body said, nil when it said nothing readable.
  case badHTTPStatus(Int, detail: OwlServerErrorDetail? = nil)
  /// The response was not an HTTPURLResponse (should not happen for http(s), defensive).
  case nonHTTPResponse
  /// The endpoint could not be rewritten to the route's transport (`/responses`). No request sent.
  case invalidEndpoint
  /// The transport ended normally without ever yielding answer text. This is not success, and it
  /// is not known to be a configuration refusal, so the ask module reports it without fanning out.
  case emptyResponse
  /// The upstream reported a failure MID-STREAM (a Responses-API `response.failed` frame) after a
  /// 2xx. Carries its message. Without this the stream would just end, showing a blank answer as
  /// if it had succeeded.
  case upstreamFailure(String)
}

/// Why a high-level streaming request could not even start (no profile / no key). Returned as a
/// typed value rather than thrown so B10 can present a "configure a provider" prompt without a
/// crash-shaped error. No network is touched when this is returned.
/// Streaming keeps its familiar name; the underlying type is the shared `OwlProviderAuthOutcome`
/// (see `OwlProviderAuthGate`), so one enum serves streaming / 划词润色 / 来源核验.
typealias OwlStreamingReadiness = OwlProviderAuthOutcome

/// WHO answered this question — a **mutable** carrier, deliberately not a plain value.
///
/// 归属在开流那一刻还不算数：请求发出之后才知道方舟没开通内容插件（404 `ToolNotOpen`）、Key 已失效
/// （401）、搜索服务的 Key 是错的（`invalid_api_key`）。运行期顺位会换一家，全败还会退回普通
/// 问答，两种情况都改写归属。所以任意提问 module 交出的是这个盒子而不是一个定值 —— AI 窗在拿到第一段内容
/// 与流结束时读回它，署名 chip 写的于是是**最终真的答了这一问的那家**，而不是「本来打算用谁」。
@MainActor
final class OwlAskAttribution {
  /// 联网供应商 / 搜索后端 id；nil = 这一问没走联网（普通问答）。
  private(set) var searchProviderID: String?

  init(searchProviderID: String? = nil) {
    self.searchProviderID = searchProviderID
  }

  func update(searchProviderID: String?) {
    self.searchProviderID = searchProviderID
  }
}

/// A successfully opened 任意提问 stream plus WHO answered it. The AI window renders the attribution
/// as the 署名 chip so the user can see this answer came from a live search — and, because the
/// attribution is re-read as content arrives, so that a runtime failover is visible rather than hidden.
@MainActor
struct OwlAskStreamOpen {
  let stream: AsyncThrowingStream<String, Error>
  let attribution: OwlAskAttribution

  var searchProviderID: String? { attribution.searchProviderID }

  init(stream: AsyncThrowingStream<String, Error>, attribution: OwlAskAttribution) {
    self.stream = stream
    self.attribution = attribution
  }

  init(stream: AsyncThrowingStream<String, Error>, searchProviderID: String?) {
    self.init(
      stream: stream, attribution: OwlAskAttribution(searchProviderID: searchProviderID))
  }
}

// MARK: - Pure SSE delta parser (the testable core)

/// Stateful, pure (no networking) parser for an OpenAI/DeepSeek **streaming** chat response.
///
/// The wire format is Server-Sent-Events: a sequence of `data: {json}` lines, events separated by
/// blank lines, terminated by `data: [DONE]`. The decoder is byte/line-oriented at the source, but
/// network chunks do NOT respect line boundaries — a chunk can split mid-line or mid-event — so the
/// parser BUFFERS a partial trailing line across `consume(_:)` calls and only acts on complete lines.
///
/// `consume(_:)` is fed each text chunk as it arrives and returns the assistant content deltas that
/// became complete within that chunk (in order). `isFinished` flips once `data: [DONE]` is seen.
///
/// Robustness (none of these error — a stream must degrade, not crash):
///   - SSE comment lines (`:` prefix) and blank keepalive lines are ignored.
///   - A `data:` payload whose JSON has no `choices[0].delta.content` (e.g. the role-only first
///     chunk, or a finish-reason-only final chunk) is ignored.
///   - A malformed-JSON `data:` line is skipped (silently) — a partial buffer is held until the
///     line is complete, so a split mid-JSON does not produce a spurious skip.
struct OwlSSEChatParser {
  private let core = OwlProviderStream(responses: false)
  var isFinished: Bool { core.isFinished }
  var failure: String? { core.failure }
  mutating func consume(_ chunk: String) -> [String] { core.consume(Data(chunk.utf8)) }
  mutating func consume(_ chunk: Data) -> [String] { core.consume(chunk) }
  mutating func finish() -> [String] { core.finish() }
  mutating func cancel() { core.cancel() }
}

// MARK: - Streaming client

/// Injection point for the underlying byte/line source. The live default is `URLSession.bytes(for:)`,
/// which produces an `URLSession.AsyncBytes` line iterator. A test supplies a scripted source so the
/// parser can be driven end-to-end with no socket (same idiom as `OwlCloudCandidateFetching`).
///
/// The provider returns raw Data chunks; UTF-8 decoding and frame buffering belong to Rust.
/// The text initializer is retained for the existing synthetic transport fixtures.
struct OwlStreamingBytesSource {
  let response: HTTPURLResponse?
  let dataChunks: AsyncThrowingStream<Data, Error>
  init(response: HTTPURLResponse?, dataChunks: AsyncThrowingStream<Data, Error>) {
    self.response = response; self.dataChunks = dataChunks
  }
  init(response: HTTPURLResponse?, chunks: AsyncThrowingStream<String, Error>) {
    self.response = response
    self.dataChunks = AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await text in chunks { continuation.yield(Data(text.utf8)) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  }

/// The narrow streaming transport port. B10 depends on THIS, not the concrete client, so the window
/// can be tested against a fake stream.
protocol OwlChatStreaming: Sendable {
  /// Stream an assistant answer for `messages`, routed by `routing`, authorized with `apiKey`.
  /// Yields content deltas in order and finishes when the upstream sends `[DONE]`. Honors task
  /// cancellation (cancelling the consuming task tears down the upstream byte stream). A non-2xx
  /// HTTP status finishes the stream with `OwlStreamingError.badHTTPStatus`.
  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>
}

/// Live OpenAI-compatible streaming client. Builds the POST (`Authorization: Bearer`, `stream: true`,
/// model/endpoint from `routing`, NO `response_format` — streaming + json_object don't mix for a
/// free-text answer), opens the byte source, and re-frames its chunks through `OwlSSEChatParser`.
struct OwlStreamingChatClient: OwlChatStreaming {
  /// Per-request timeout (seconds). Bounds a hung stream; same spirit as `OwlCloudPreferences.requestTimeout`.
  let timeout: TimeInterval
  /// Byte/line source. Default = the gateway transport (`URLSession.bytes` in production);
  /// a test may pass a scripted source instead (no socket).
  private let bytesProvider: @Sendable (URLRequest) async throws -> OwlStreamingBytesSource

  init(
    timeout: TimeInterval = 30,
    transport: OwlLLMTransport = OwlURLSessionTransport(),
    bytesProvider: (@Sendable (URLRequest) async throws -> OwlStreamingBytesSource)? = nil
  ) {
    self.timeout = timeout
    self.bytesProvider = bytesProvider ?? { try await transport.openStream($0) }
  }

  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(messages: messages, routing: routing, apiKey: apiKey)
          let source = try await bytesProvider(request)

          if let http = source.response, !OwlProviderCore.httpAccepted(http.statusCode) {
            let detail = await OwlServerErrorDetail.read(source.dataChunks)
            continuation.finish(throwing: OwlStreamingError.badHTTPStatus(http.statusCode, detail: detail))
            return
          }

          var parser = OwlSSEChatParser()
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
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Build the streaming POST. `routing.endpoint` / `routing.model` come from the active provider
  /// profile (or the legacy globals when none). No `response_format`.
  ///
  /// `OwlProviderCapabilities.thinkingOffBody` — 强制关思考, applied to EVERY 任意提问 request (plain or 联网) —
  /// is merged onto the encoded request. This is the choke point for the whole ask lane: the
  /// providers' own field names differ, so the dialect lives in one place instead of at each call
  /// site. A provider with no known thinking switch still gets a byte-identical plain-chat body.
  private func makeRequest(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) throws -> URLRequest {
    var request = URLRequest(url: routing.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    routing.authHeaderStyle.apply(to: &request, apiKey: apiKey)
    request.timeoutInterval = timeout
    struct BodyPlan: Decodable { let body: OwlJSONValue; let foundationEncoding: Bool }
    let plan: BodyPlan = OwlProviderCore.call("chatStreamPlan", ["providerID": routing.providerID,
      "model": routing.model, "messages": OwlAppCore.payload(messages)])
    let encoded = try JSONEncoder().encode(plan.body)
    request.httpBody = plan.foundationEncoding
      ? try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: encoded))
      : encoded
    return request
  }

}

// MARK: - Plain streaming seam

/// Narrow port for non-conversation skills that must never search.
@MainActor
protocol OwlPlainStreaming {
  func readiness() -> OwlStreamingReadiness

  func stream(
    messages: [OwlDeepSeekMessage]
  ) -> Result<AsyncThrowingStream<String, Error>, OwlStreamingReadiness>
}

// MARK: - High-level entry (resolves the active profile + key)

/// A thin façade for non-conversation plain-generation skills. Resolves the active provider profile
/// + API key via the shared `OwlProviderAuthGate` (same injectable `profileProvider` /
/// `profileSecretProvider` defaults), then streams. When nothing is configured it returns a typed
/// `OwlStreamingReadiness` (no network, no throw-crash) so the caller can prompt for setup.
///
/// TRANSPORT ONLY (see file header): the privacy gate / redaction / sensitive-mode block are the
/// caller's responsibility, applied to `messages` BEFORE calling here.
@MainActor
final class OwlStreamingChatService {
  static let shared = OwlStreamingChatService()

  /// Resolves the active profile → routing + key (or a typed not-ready outcome). Built from the
  /// injected profile/secret/legacy closures so tests keep injecting exactly as before.
  private let gate: OwlProviderAuthGate
  /// Provider-neutral transport for plain streaming. The gateway picks the wire.
  private let transport: OwlAskAnythingTransporting

  init(
    client: OwlChatStreaming? = nil,
    responsesClient: OwlResponsesStreaming? = nil,
    profileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) },
    legacyKeyProvider: @escaping () throws -> String? = { nil }
  ) {
    let gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider
    )
    let transport = OwlAskAnythingTransportAdapter(
      gateway: OwlLLMGateway(chatStreamer: client, responsesStreamer: responsesClient))
    self.gate = gate
    self.transport = transport
  }

  /// Resolve routing + key from the active profile (or legacy globals). Pure, no network. A test can
  /// assert readiness before any stream is opened. Delegates to the shared `OwlProviderAuthGate`.
  func readiness() -> OwlStreamingReadiness {
    gate.resolve()
  }

  /// Stream an answer for `messages` using the resolved active profile + key. On a not-yet-configured
  /// setup it returns the typed readiness via `unconfigured`/`missingKey` and yields NO stream — the
  /// caller checks `readiness()` first (or handles the returned readiness) before consuming.
  func stream(messages: [OwlDeepSeekMessage]) -> Result<AsyncThrowingStream<String, Error>, OwlStreamingReadiness> {
    switch readiness() {
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

extension OwlStreamingChatService: OwlPlainStreaming {}
