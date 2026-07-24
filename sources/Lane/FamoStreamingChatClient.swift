//
//  FamoStreamingChatClient.swift
//  法墨输入法 (Famo) — OpenAI-compatible STREAMING chat transport (roadmap B9, streaming half)
//
//  This is the token-by-token transport the B10 AI conversation window will consume. Famo's
//  existing provider stack (FamoDeepSeekCloudLane) is request/response only (`stream: false`,
//  `URLSession.data(for:)`). This file adds a `stream: true` path that yields assistant content
//  deltas as an `AsyncThrowingStream<String, Error>`, reusing the multi-provider profile +
//  keychain foundation (`FamoCloudRouting`, `FamoProviderProfileStore`, `FamoProviderKeychain`,
//  `FamoDeepSeekMessage`) BY REFERENCE only.
//
//  TRANSPORT ONLY. This client sends whatever messages it is given. Building the messages (the
//  context assembly) is the CALLER's responsibility — B10 must assemble them BEFORE handing them
//  here. B9 is simply the transport, not a content-policy site.
//
//  Off the IMK hot path: nothing in `processKey` / `handle` calls this — an explicit AI trigger does.
//

import Foundation

// MARK: - Errors

/// Typed failures for the streaming transport. Kept separate from `FamoCloudRequestError` so the
/// streaming chat path (a free-text answer) and the candidate path (a list) never share an error space.
enum FamoStreamingError: Error, Equatable {
  /// The HTTP response was non-2xx. The stream finishes with this instead of yielding garbage.
  case badHTTPStatus(Int)
  /// The response was not an HTTPURLResponse (should not happen for http(s), defensive).
  case nonHTTPResponse
  /// The endpoint could not be rewritten to the route's transport (`/responses`). No request sent.
  case invalidEndpoint
  /// The upstream reported a failure MID-STREAM (a Responses-API `response.failed` frame) after a
  /// 2xx. Carries its message. Without this the stream would just end, showing a blank answer as
  /// if it had succeeded.
  case upstreamFailure(String)
}

/// Why a high-level streaming request could not even start (no profile / no key). Returned as a
/// typed value rather than thrown so B10 can present a "configure a provider" prompt without a
/// crash-shaped error. No network is touched when this is returned.
/// Streaming keeps its familiar name; the underlying type is the shared `FamoProviderAuthOutcome`
/// (see `FamoProviderAuthGate`), so one enum serves streaming / 划词润色 / 来源核验.
typealias FamoStreamingReadiness = FamoProviderAuthOutcome

/// A successfully opened 任意提问 stream plus WHO answered it: `searchProviderID` names the 联网模型
/// when the question was routed through 联网搜索, or is nil for a plain-chat answer. The AI window
/// renders it as the 署名 chip so the user can see this answer came from a live search.
struct FamoAskStreamOpen {
  let stream: AsyncThrowingStream<String, Error>
  let searchProviderID: String?
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
struct FamoSSEChatParser {
  /// Carries an incomplete trailing line between chunks. Empty between whole-line boundaries.
  private var buffer = ""
  /// True once `data: [DONE]` has been observed. Further input is ignored.
  private(set) var isFinished = false

  /// One streaming chunk's decoded JSON shape: `choices[0].delta.content`. Everything else is
  /// `decodeIfPresent`/optional so a role-only or finish-reason-only chunk decodes without throwing.
  private struct StreamChunk: Decodable {
    struct Choice: Decodable {
      struct Delta: Decodable {
        let content: String?
      }
      let delta: Delta?
    }
    let choices: [Choice]?
  }

  /// Feed one text chunk; return the assistant content deltas that completed within it (in order).
  /// Partial trailing content is retained for the next call. After `[DONE]` everything is ignored.
  mutating func consume(_ chunk: String) -> [String] {
    guard !isFinished else { return [] }
    buffer += chunk

    var deltas: [String] = []
    // Split on `\n`; the LAST element is the (possibly incomplete) trailing line — re-buffer it.
    // Using a manual split keeps an empty trailing line (the blank-line event separator) intact.
    var lines = buffer.components(separatedBy: "\n")
    buffer = lines.removeLast()

    for rawLine in lines {
      // Tolerate CRLF framing: a `\r` left at the end of a line by `\r\n` splitting.
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
      if let delta = handle(line: line) {
        deltas.append(delta)
      }
      if isFinished { break }
    }
    if isFinished { buffer = "" }
    return deltas
  }

  /// Flush at end-of-stream: process any retained trailing line that never got a closing `\n`
  /// (some endpoints omit the final newline). Returns a final delta if that line carried one.
  mutating func finish() -> [String] {
    guard !isFinished else { return [] }
    let line = buffer.hasSuffix("\r") ? String(buffer.dropLast()) : buffer
    buffer = ""
    guard let delta = handle(line: line) else { return [] }
    return [delta]
  }

  /// Decide a single complete SSE line. Returns a non-empty content delta, or nil for
  /// blank/comment/non-data/role-only/empty/malformed lines (all ignored, never fatal).
  private mutating func handle(line: String) -> String? {
    // Blank line = event separator; SSE comment = `:` prefix. Both carry no payload.
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if trimmed.hasPrefix(":") { return nil }
    guard trimmed.hasPrefix("data:") else { return nil }

    // Strip exactly the `data:` prefix; SSE permits an optional single leading space after it.
    var payload = String(trimmed.dropFirst("data:".count))
    if payload.hasPrefix(" ") { payload.removeFirst() }

    if payload == "[DONE]" {
      isFinished = true
      return nil
    }

    guard let data = payload.data(using: .utf8),
          let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
          let content = chunk.choices?.first?.delta?.content,
          !content.isEmpty else {
      // Malformed JSON, role-only/empty delta, or unexpected shape → skip silently, not fatal.
      return nil
    }
    return content
  }
}

// MARK: - Streaming client

/// Injection point for the underlying byte/line source. The live default is `URLSession.bytes(for:)`,
/// which produces an `URLSession.AsyncBytes` line iterator. A test supplies a scripted source so the
/// parser can be driven end-to-end with no socket (same idiom as `FamoCloudCandidateFetching`).
///
/// The provider returns the HTTP response plus an `AsyncThrowingStream` of TEXT chunks (already
/// UTF-8 decoded). Chunks need NOT be whole lines — `FamoSSEChatParser` re-frames them.
struct FamoStreamingBytesSource {
  let response: HTTPURLResponse?
  let chunks: AsyncThrowingStream<String, Error>
}

/// The narrow streaming transport port. B10 depends on THIS, not the concrete client, so the window
/// can be tested against a fake stream.
protocol FamoChatStreaming {
  /// Stream an assistant answer for `messages`, routed by `routing`, authorized with `apiKey`.
  /// Yields content deltas in order and finishes when the upstream sends `[DONE]`. Honors task
  /// cancellation (cancelling the consuming task tears down the upstream byte stream). A non-2xx
  /// HTTP status finishes the stream with `FamoStreamingError.badHTTPStatus`.
  ///
  /// `extraBody` merges provider-specific top-level fields into the request (联网搜索 —
  /// `FamoSearchControl.extraBody`). Empty (the default) leaves the body byte-identical to the
  /// plain-chat request.
  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error>
}

extension FamoChatStreaming {
  /// Plain chat — no provider extras. Keeps every existing call site (and test fake) unchanged.
  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    stream(messages: messages, routing: routing, apiKey: apiKey, extraBody: [:])
  }
}

/// Live OpenAI-compatible streaming client. Builds the POST (`Authorization: Bearer`, `stream: true`,
/// model/endpoint from `routing`, NO `response_format` — streaming + json_object don't mix for a
/// free-text answer), opens the byte source, and re-frames its chunks through `FamoSSEChatParser`.
struct FamoStreamingChatClient: FamoChatStreaming {
  /// Request body for a streaming chat. Mirrors `FamoDeepSeekChatRequest` minus `response_format`.
  private struct StreamingRequest: Encodable {
    let model: String
    let messages: [FamoDeepSeekMessage]
    let temperature: Double
    let stream: Bool
  }

  /// Per-request timeout (seconds). Bounds a hung stream; same spirit as `FamoCloudPreferences.requestTimeout`.
  let timeout: TimeInterval
  /// Byte/line source. Default = live `URLSession.bytes`; injectable for tests (no socket).
  private let bytesProvider: (URLRequest) async throws -> FamoStreamingBytesSource

  init(
    timeout: TimeInterval = 30,
    bytesProvider: ((URLRequest) async throws -> FamoStreamingBytesSource)? = nil
  ) {
    self.timeout = timeout
    self.bytesProvider = bytesProvider ?? FamoStreamingChatClient.liveBytesProvider
  }

  /// Live source: `URLSession.bytes(for:)` → an async line iterator re-emitted as `\n`-terminated
  /// text chunks so the parser's chunk-boundary buffering is exercised identically to a raw socket.
  private static func liveBytesProvider(_ request: URLRequest) async throws -> FamoStreamingBytesSource {
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let http = response as? HTTPURLResponse
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
    return FamoStreamingBytesSource(response: http, chunks: stream)
  }

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(
            messages: messages, routing: routing, apiKey: apiKey, extraBody: extraBody)
          let source = try await bytesProvider(request)

          if let http = source.response, !(200...299).contains(http.statusCode) {
            continuation.finish(throwing: FamoStreamingError.badHTTPStatus(http.statusCode))
            return
          }

          var parser = FamoSSEChatParser()
          for try await chunk in source.chunks {
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
  /// `extraBody` (联网搜索) is merged as TOP-LEVEL fields onto the encoded request. An empty
  /// `extraBody` skips the merge entirely, leaving the plain-chat body byte-identical.
  private func makeRequest(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) throws -> URLRequest {
    var request = URLRequest(url: routing.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    routing.authHeaderStyle.apply(to: &request, apiKey: apiKey)
    request.timeoutInterval = timeout
    let encoded = try JSONEncoder().encode(
      StreamingRequest(
        model: routing.model,
        messages: messages,
        temperature: 0.2,
        stream: true
      )
    )
    request.httpBody = extraBody.isEmpty ? encoded : Self.merging(extraBody, into: encoded)
    return request
  }

  /// Merge provider extras onto an encoded request body. A re-serialization failure falls back to
  /// the un-merged body: the question still gets answered (just without search) instead of throwing.
  private static func merging(_ extraBody: [String: Any], into encoded: Data) -> Data {
    guard var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
      return encoded
    }
    object.merge(extraBody) { _, extra in extra }
    guard let merged = try? JSONSerialization.data(withJSONObject: object) else { return encoded }
    return merged
  }
}

// MARK: - High-level entry (resolves the active profile + key)

/// A thin façade B10 can call without wiring routing/keys itself. Resolves the active provider
/// profile + API key via the shared `FamoProviderAuthGate` (same injectable `profileProvider` /
/// `profileSecretProvider` defaults), then streams. When nothing is configured it returns a typed
/// `FamoStreamingReadiness` (no network, no throw-crash) so the caller can prompt for setup.
///
/// TRANSPORT ONLY (see file header): the privacy gate / redaction / sensitive-mode block are the
/// caller's responsibility, applied to `messages` BEFORE calling here.
@MainActor
final class FamoStreamingChatService {
  static let shared = FamoStreamingChatService()

  private let client: FamoChatStreaming
  /// The `/responses` transport (豆包 / OpenAI 联网). Held ONLY here — `stream` never touches it,
  /// so 划词技能 structurally cannot reach a search endpoint.
  private let responsesClient: FamoResponsesStreaming
  /// Resolves the active profile → routing + key (or a typed not-ready outcome). Built from the
  /// injected profile/secret/legacy closures so tests keep injecting exactly as before.
  private let gate: FamoProviderAuthGate
  /// Resolves the 任意提问 联网搜索 route (nil = search off / none configured → plain chat).
  /// Only `openAsk` consults it; `stream` (划词技能) never searches.
  private let searchResolver: FamoAskSearchResolver

  init(
    client: FamoChatStreaming? = nil,
    responsesClient: FamoResponsesStreaming? = nil,
    profileProvider: @escaping () -> FamoProviderProfile? = { FamoProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try FamoProviderKeychain().secret(named: $0) },
    legacyKeyProvider: @escaping () throws -> String? = FamoCloudKeychain.readDeepSeekAPIKey,
    searchResolver: FamoAskSearchResolver? = nil
  ) {
    self.client = client ?? FamoStreamingChatClient()
    self.responsesClient = responsesClient ?? FamoResponsesStreamingClient()
    self.gate = FamoProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider
    )
    self.searchResolver = searchResolver ?? FamoAskSearchResolver()
  }

  /// Resolve routing + key from the active profile (or legacy globals). Pure, no network. A test can
  /// assert readiness before any stream is opened. Delegates to the shared `FamoProviderAuthGate`.
  func readiness() -> FamoStreamingReadiness {
    gate.resolve()
  }

  /// Stream an answer for `messages` using the resolved active profile + key. On a not-yet-configured
  /// setup it returns the typed readiness via `unconfigured`/`missingKey` and yields NO stream — the
  /// caller checks `readiness()` first (or handles the returned readiness) before consuming.
  func stream(messages: [FamoDeepSeekMessage]) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
    switch readiness() {
    case let .ready(routing, apiKey):
      return .success(client.stream(messages: messages, routing: routing, apiKey: apiKey))
    case .unconfigured:
      return .failure(.unconfigured)
    case .missingKey:
      return .failure(.missingKey)
    }
  }

  /// 任意提问 entry: stream an answer, routing through a 联网搜索 provider when one is configured and
  /// the toggle is on. Falls back to plain chat (`stream`) when the resolver returns nil — the
  /// deliberate SILENT degrade: 联网 is a bonus, never a reason for the question to fail.
  ///
  /// Separate from `stream` on purpose: 划词技能 call that one and can therefore never search,
  /// which is the scope boundary made structural rather than documented.
  func openAsk(messages: [FamoDeepSeekMessage]) -> Result<FamoAskStreamOpen, FamoStreamingReadiness> {
    if let route = searchResolver.resolve(), let stream = openSearch(route: route, messages: messages) {
      return .success(FamoAskStreamOpen(stream: stream, searchProviderID: route.providerID))
    }
    return stream(messages: messages).map {
      FamoAskStreamOpen(stream: $0, searchProviderID: nil)
    }
  }

  /// Open the resolved route on ITS transport. nil = this route can't actually search (only
  /// reachable if a route ever escapes the resolver's search-capable candidate list) → the caller
  /// falls back to plain chat rather than claiming a 联网 answer it didn't get.
  private func openSearch(
    route: FamoAskSearchRoute,
    messages: [FamoDeepSeekMessage]
  ) -> AsyncThrowingStream<String, Error>? {
    switch route.transport {
    case .chatCompletions:
      return client.stream(
        messages: messages,
        routing: route.routing,
        apiKey: route.apiKey,
        extraBody: route.extraBody
      )
    case let .responses(isOpenAI):
      return responsesClient.stream(
        messages: messages,
        routing: route.routing,
        apiKey: route.apiKey,
        isOpenAI: isOpenAI
      )
    case .none:
      return nil
    }
  }
}
