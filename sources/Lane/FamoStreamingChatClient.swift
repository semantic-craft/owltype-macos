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

/// WHO answered this question — a **mutable** carrier, deliberately not a plain value.
///
/// 归属在开流那一刻还不算数：请求发出之后才知道方舟没开通内容插件（404 `ToolNotOpen`）、MiMo 的 Key
/// 已失效（401）、搜索服务的 Key 是错的（`invalid_api_key`）。运行期顺位会换一家，全败还会退回普通
/// 问答，两种情况都改写归属。所以 `openAsk` 交出的是这个盒子而不是一个定值 —— AI 窗在拿到第一段内容
/// 与流结束时读回它，署名 chip 写的于是是**最终真的答了这一问的那家**，而不是「本来打算用谁」。
@MainActor
final class FamoAskAttribution {
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
struct FamoAskStreamOpen {
  let stream: AsyncThrowingStream<String, Error>
  let attribution: FamoAskAttribution

  var searchProviderID: String? { attribution.searchProviderID }

  init(stream: AsyncThrowingStream<String, Error>, attribution: FamoAskAttribution) {
    self.stream = stream
    self.attribution = attribution
  }

  init(stream: AsyncThrowingStream<String, Error>, searchProviderID: String?) {
    self.init(
      stream: stream, attribution: FamoAskAttribution(searchProviderID: searchProviderID))
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
  /// TWO sets of top-level extras are merged onto the encoded request:
  ///   1. `FamoThinkingControl.offBody` — 强制关思考, applied to EVERY 任意提问 request (plain or
  ///      联网). This is the choke point for the whole ask lane: the providers' own field names
  ///      differ, so the dialect lives in one place instead of at each call site.
  ///   2. `extraBody` (联网搜索 — `FamoSearchControl.extraBody`), merged last so a search route can
  ///      override a thinking field if a provider ever needs a different value there.
  /// A provider with no known thinking switch and no search extras still gets a byte-identical
  /// plain-chat body (both dicts empty → merge skipped).
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
    var extras = FamoThinkingControl.offBody(providerID: routing.providerID, model: routing.model)
    extras.merge(extraBody) { _, search in search }
    request.httpBody = extras.isEmpty ? encoded : Self.merging(extras, into: encoded)
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

/// 一次可尝试的联网候选。两种形态在**怎么拿到网页**上根本不同，所以是类型而不是约定：
///   - `.grounded`：独立搜索服务先检索，结果注入后由**默认供应商**作答（豆包搜索 / Perplexity）；
///   - `.builtIn`：模型自己的联网工具，检索与作答在同一次请求里（百炼 / MiMo / 方舟 / OpenAI）。
private enum FamoAskAttempt {
  case grounded(
    backend: FamoWebSearchBackend,
    searchKey: String,
    query: String,
    routing: FamoCloudRouting,
    apiKey: String)
  case builtIn(FamoAskSearchRoute)

  /// 署名 chip 上写谁。`.grounded` 写的是**检索方**（作答的是默认供应商，那是另一回事）。
  var attributionID: String {
    switch self {
    case let .grounded(backend, _, _, _, _): return backend.attributionID
    case let .builtIn(route):                return route.providerID
    }
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
  /// The `/responses` transport. Qwen uses it for every generation; 豆包/OpenAI use it for their
  /// built-in-search routes. `webSearch` remains explicit, so plain skills never gain search by
  /// merely sharing the transport.
  private let responsesClient: FamoResponsesStreaming
  /// Resolves the active profile → routing + key (or a typed not-ready outcome). Built from the
  /// injected profile/secret/legacy closures so tests keep injecting exactly as before.
  private let gate: FamoProviderAuthGate
  /// Resolves the 任意提问 联网搜索 route (nil = search off / none configured → plain chat).
  /// Only `openAsk` consults it; `stream` (划词技能) never searches.
  private let searchResolver: FamoAskSearchResolver
  /// 解析当前生效的搜索后端 + 它的 Key。nil = 没配 → 走既有的模型内置联网路径。
  /// 后端与 Key 一起解析（而不是各取各的），否则切了后端却用着上一家的 Key 会静默 401。
  private let webSearchProvider: () -> (backend: FamoWebSearchBackend, apiKey: String)?
  /// 顺位候选（未选中的搜索后端）的 Key 查询。必须与 `webSearchProvider` 一样可注入：默认读真
  /// 钥匙串，测试不替换它的话，开发机上真配过的搜索 Key 会悄悄变成一条真实顺位路由——与
  /// `searchResolver` 注释里踩过的是同一个坑。
  private let webSearchKeyProvider: (FamoWebSearchBackend) -> String?
  /// 后端 → 客户端。可注入，测试不碰网络。
  private let webSearchClientFactory: (FamoWebSearchBackend) -> FamoWebSearching

  /// 每问取几条结果喂给模型。多了烧 token 也拖时延，少了容易漏掉答案所在的那一条。
  static let webSearchResultCount = 5

  init(
    client: FamoChatStreaming? = nil,
    responsesClient: FamoResponsesStreaming? = nil,
    profileProvider: @escaping () -> FamoProviderProfile? = { FamoProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try FamoProviderKeychain().secret(named: $0) },
    legacyKeyProvider: @escaping () throws -> String? = FamoCloudKeychain.readDeepSeekAPIKey,
    searchResolver: FamoAskSearchResolver? = nil,
    webSearchProvider: (() -> (backend: FamoWebSearchBackend, apiKey: String)?)? = nil,
    webSearchKeyProvider: ((FamoWebSearchBackend) -> String?)? = nil,
    webSearchClientFactory: ((FamoWebSearchBackend) -> FamoWebSearching)? = nil
  ) {
    self.client = client ?? FamoStreamingChatClient()
    self.responsesClient = responsesClient ?? FamoResponsesStreamingClient()
    self.gate = FamoProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider
    )
    self.searchResolver = searchResolver ?? FamoAskSearchResolver()
    self.webSearchProvider = webSearchProvider ?? {
      let backend = FamoWebSearchBackendSettings.backend
      guard let key = FamoWebSearchKeyStore.apiKey(for: backend) else { return nil }
      return (backend, key)
    }
    self.webSearchKeyProvider = webSearchKeyProvider ?? { FamoWebSearchKeyStore.apiKey(for: $0) }
    self.webSearchClientFactory = webSearchClientFactory ?? { $0.makeClient() }
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
      return .success(plainStream(messages: messages, routing: routing, apiKey: apiKey))
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
    let attempts = askAttempts(messages: messages)
    guard let first = attempts.first else {
      return stream(messages: messages).map {
        FamoAskStreamOpen(stream: $0, searchProviderID: nil)
      }
    }
    let attribution = FamoAskAttribution(searchProviderID: first.attributionID)
    // 第一家里**不需要 await** 的那种（模型内置联网）仍同步开，时序与加顺位之前逐字一致；
    // 需要先检索的独立搜索层只能在流内部的 Task 里开。
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

  /// 这一问可以依次尝试的联网候选。
  ///
  /// 顺序：**独立搜索层**（用户选中的后端优先，另一家配了 Key 就跟在后面）→ 各家模型内置的联网工具。
  /// 搜索层排前面是因为它与作答解耦，不受「这家模型能不能联网 / 账号有没有开通插件」的限制。
  /// 搜索层自己不作答，所以主模型没就绪时它整体掉出候选 —— 否则会先联网一趟、再报一个跟
  /// 「没配供应商」无关的错。
  private func askAttempts(messages: [FamoDeepSeekMessage]) -> [FamoAskAttempt] {
    guard FamoAskWebSearchSettings.isEnabled else { return [] }
    var attempts: [FamoAskAttempt] = []
    if let query = FamoWebSearchContext.query(from: messages),
       case let .ready(routing, apiKey) = readiness() {
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

  /// 已配好 Key 的搜索后端，选中的那个排第一 —— 与「联网模型」偏好同样的语义：偏好只排序，
  /// 没配 Key 的自然掉出，不占位。
  private func webSearchBackends() -> [(backend: FamoWebSearchBackend, apiKey: String)] {
    guard let selected = webSearchProvider() else { return [] }
    var out = [selected]
    for backend in FamoWebSearchBackend.allCases where backend != selected.backend {
      if let key = webSearchKeyProvider(backend) {
        out.append((backend, key))
      }
    }
    return out
  }

  /// 逐家尝试，直到有一家真的开始输出内容；全败则退回普通问答。
  ///
  /// 顺位的硬约束是**首个 delta 之前**：一旦有内容送进窗口，再换一家就会把两半答案拼在一起，所以
  /// 那之后的失败一律如实上报（哪怕是 401）。
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
        // 开流阶段就失败：检索被拒 / Key 无效 / 一条结果都没有。
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
          yieldedAnyContent = true
          continuation.yield(delta)
        }
        return continuation.finish()
      } catch {
        guard !yieldedAnyContent,
              FamoAskSearchFailover.shouldTryNextProvider(after: error) else {
          return continuation.finish(throwing: error)
        }
        lastError = error
      }
    }

    // 每一家联网都不可用 → 退回普通问答（设置页承诺的那条降级），署名同时撤掉联网。
    attribution.update(searchProviderID: nil)
    guard case let .success(plain) = stream(messages: messages) else {
      // 连普通问答都没配好：报最后一次联网失败，比报「未配置」贴近真相。
      return continuation.finish(throwing: lastError ?? FamoStreamingError.nonHTTPResponse)
    }
    do {
      for try await delta in plain {
        continuation.yield(delta)
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  /// 不需要 `await` 就能开的候选（模型内置联网）。nil = 这条得先检索，交给 `open(attempt:…)`。
  private func openImmediately(
    attempt: FamoAskAttempt,
    messages: [FamoDeepSeekMessage]
  ) -> AsyncThrowingStream<String, Error>? {
    guard case let .builtIn(route) = attempt else { return nil }
    return openSearch(route: route, messages: messages)
  }

  /// 开一条候选的流。检索失败原样 throw，由 `pump` 决定顺位还是上报。
  private func open(
    attempt: FamoAskAttempt,
    messages: [FamoDeepSeekMessage]
  ) async throws -> AsyncThrowingStream<String, Error> {
    switch attempt {
    case let .grounded(backend, searchKey, query, routing, apiKey):
      let results = try await webSearchClientFactory(backend).search(
        query: query, apiKey: searchKey, limit: Self.webSearchResultCount)
      // 0 条结果按失败处理：注入空资料等于凭训练记忆作答却署着「已联网」。
      guard !results.isEmpty else { throw FamoWebSearchError.noResults }
      return plainStream(
        messages: FamoWebSearchContext.injecting(results: results, into: messages),
        routing: routing,
        apiKey: apiKey)
    case let .builtIn(route):
      guard let stream = openSearch(route: route, messages: messages) else {
        throw FamoWebSearchError.invalidEndpoint
      }
      return stream
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
    case let .responses(dialect):
      return responsesClient.stream(
        messages: messages,
        routing: route.routing,
        apiKey: route.apiKey,
        dialect: dialect,
        webSearch: true
      )
    case .none:
      return nil
    }
  }

  /// Plain generation still selects transport by provider. Qwen 与豆包 run their whole Famo
  /// surface on Responses (store=false + 关思考 live in `FamoResponsesWire.body`); all other
  /// profiles retain their existing chat-completions wire.
  private func plainStream(
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
    return client.stream(messages: messages, routing: routing, apiKey: apiKey)
  }
}
