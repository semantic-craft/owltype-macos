import Foundation

enum OwlCloudPreferences {
  private static let enabledKey = "OwlCloudLaneEnabled"
  private static let modelKey = "OwlDeepSeekModel"
  private static let endpointKey = "OwlDeepSeekEndpoint"

  static let defaultDeepSeekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
  static let defaultDeepSeekModel = "deepseek-flash"
  static let reasonerDeepSeekModel = "deepseek-v4-pro"

  static var requestTimeout: TimeInterval { OwlLLMCallPurpose.interactiveRewrite.timeout }

  static var isEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  static var deepSeekModel: String {
    get {
      let stored = OwlDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return canonicalDeepSeekModel(stored)
    }
    set { OwlDefaults.standard.set(canonicalDeepSeekModel(newValue), forKey: modelKey) }
  }

  static var deepSeekEndpoint: URL {
    get {
      guard let raw = OwlDefaults.standard.string(forKey: endpointKey),
            let url = URL(string: raw),
            url.scheme == "https" else {
        return defaultDeepSeekEndpoint
      }
      return url
    }
    set { OwlDefaults.standard.set(newValue.absoluteString, forKey: endpointKey) }
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: enabledKey)
    OwlDefaults.standard.removeObject(forKey: modelKey)
    OwlDefaults.standard.removeObject(forKey: endpointKey)
  }

  static func canonicalDeepSeekModel(_ raw: String?) -> String {
    OwlProviderCore.call("canonicalModel", ["model": raw ?? ""])
  }

  static func message(for error: Error) -> String {
    let status: Int
    let detail: OwlServerErrorDetail?
    switch error {
    case let OwlCloudRequestError.badHTTPStatus(code, body), let OwlStreamingError.badHTTPStatus(code, body):
      (status, detail) = (code, body)
    default: (status, detail) = (0, nil)
    }
    return OwlProviderCore.call("errorMessage", ["status": status, "code": detail?.code ?? ""])
  }
}

struct OwlDeepSeekMessage: Codable, Equatable, Sendable {
  let role: String
  let content: String
}

struct OwlDeepSeekResponseFormat: Codable, Equatable, Sendable {
  let type: String
  static let jsonObject = OwlDeepSeekResponseFormat(type: "json_object")
}

struct OwlDeepSeekThinking: Codable, Equatable, Sendable {
  let type: String
  static let disabled = OwlDeepSeekThinking(type: "disabled")
}

enum OwlThinkingControl {
  static func offBody(providerID: String, model: String) -> [String: Any] {
    offBody(offFields(providerID: providerID, model: model))
  }

  static func offBody(_ fields: Fields) -> [String: Any] {
    let data = try! JSONEncoder().encode(fields)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  struct Fields: Codable {
    var thinking: OwlDeepSeekThinking?
    var enableThinking: Bool?
    var reasoningEffort: String?
    var reasoningSplit: Bool?
    enum CodingKeys: String, CodingKey {
      case thinking
      case enableThinking = "enable_thinking", reasoningEffort = "reasoning_effort", reasoningSplit = "reasoning_split"
    }
  }
  static func offFields(providerID: String, model: String) -> Fields {
    OwlProviderCore.call("thinking", ["providerID": providerID, "model": model])
  }
}

enum OwlChatSamplingControl {
  static func temperature(_ value: Double, model: String) -> Double? {
    OwlProviderCore.call("temperature", ["model": model, "value": value])
  }
}

struct OwlDeepSeekChatRequest: Codable, Equatable, Sendable {
  let model: String
  let messages: [OwlDeepSeekMessage]
  let temperature: Double?
  let stream: Bool
  let responseFormat: OwlDeepSeekResponseFormat?
  let thinking: OwlDeepSeekThinking?
  let enableThinking: Bool?
  let reasoningEffort: String?
  let reasoningSplit: Bool?

  func encode(to encoder: Encoder) throws {
    let value: OwlJSONValue = OwlProviderCore.call("chatBody", [
      "model": model, "messages": OwlAppCore.payload(messages), "stream": stream,
      "temperature": temperature as Any? ?? NSNull(),
      "responseFormat": responseFormat.map(OwlAppCore.payload) ?? NSNull(),
      "thinking": thinking.map(OwlAppCore.payload) ?? NSNull(),
      "enableThinking": enableThinking as Any? ?? NSNull(),
      "reasoningEffort": reasoningEffort as Any? ?? NSNull(),
      "reasoningSplit": reasoningSplit as Any? ?? NSNull(),
    ])
    try value.encode(to: encoder)
  }

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature, stream, thinking
    case responseFormat = "response_format"
    case enableThinking = "enable_thinking"
    case reasoningEffort = "reasoning_effort"
    case reasoningSplit = "reasoning_split"
  }
}

enum OwlCloudRequestError: Error, Equatable {
  case disabled
  case missingAPIKey
  case unsupportedProvider
  case badHTTPStatus(Int, detail: OwlServerErrorDetail? = nil)
  case emptyResponse
}

struct OwlServerErrorDetail: Codable, Equatable, Sendable {
  let code: String?
  let message: String?

  static func parse(_ data: Data) -> OwlServerErrorDetail? {
    OwlProviderCore.call("errorDetail", ["bytes": Array(data)])
  }

  static func read(_ chunks: AsyncThrowingStream<String, Error>, limit: Int = 16_384) async -> OwlServerErrorDetail? {
    var body = ""
    do {
      for try await chunk in chunks {
        body += chunk
        if body.utf8.count >= limit { break }
      }
    } catch {}
    return parse(Data(body.utf8))
  }

  static func read(_ chunks: AsyncThrowingStream<Data, Error>, limit: Int = 16_384) async -> OwlServerErrorDetail? {
    var data = Data()
    do {
      for try await chunk in chunks {
        data.append(chunk.prefix(max(0, limit - data.count)))
        if data.count >= limit { break }
      }
    } catch {}
    return parse(data)
  }

  func sanitized(removing apiKey: String, maxLength: Int = 160) -> String {
    OwlProviderCore.call("sanitize", ["message": message ?? "", "key": apiKey, "limit": maxLength])
  }
}

enum OwlServerRefusal: String, Equatable {
  case invalidKey
  case modelUnavailable
  case insufficientBalance
  case quotaExhausted
  case rateLimited
  case contentBlocked

  init?(code: String?) {
    let raw: String? = OwlProviderCore.call("refusal", ["code": code ?? ""])
    guard let raw, let result = Self(rawValue: raw) else { return nil }
    self = result
  }
  var message: String { OwlProviderCore.call("refusalMessage", ["kind": rawValue]) }
}

struct OwlCloudRouting: Codable, Equatable, Sendable {
  let providerID: String
  let endpoint: URL
  let model: String
  let secretName: String?
  let authHeaderStyle: OwlProviderAuthHeaderStyle

  static func resolve(profile: OwlProviderProfile?) -> OwlCloudRouting {
    OwlProviderCore.call("routing", ["profile": profile.map(OwlAppCore.payload) ?? NSNull(),
      "legacyEndpoint": OwlCloudPreferences.deepSeekEndpoint.absoluteString,
      "legacyModel": OwlCloudPreferences.deepSeekModel])
  }
}

struct OwlCloudUsageSnapshot: Codable, Equatable, Sendable {
  let model: String
  let completionTokens: Int
  let promptTokens: Int
  let promptCacheHitTokens: Int
  let promptCacheMissTokens: Int
  let totalTokens: Int
}

enum OwlCloudUsageTelemetry {
  private static let lastUsageKey = "OwlCloudLastUsageTelemetry"

  static var lastUsage: OwlCloudUsageSnapshot? {
    guard let data = OwlDefaults.standard.data(forKey: lastUsageKey) else { return nil }
    return try? JSONDecoder().decode(OwlCloudUsageSnapshot.self, from: data)
  }

  static func record(_ usage: OwlCloudUsageSnapshot) {
    guard let data = try? JSONEncoder().encode(usage) else { return }
    OwlDefaults.standard.set(data, forKey: lastUsageKey)
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: lastUsageKey)
  }
}

enum OwlNumberedRewriteParser {
  static func parse(_ content: String) -> [String] {
    OwlProviderCore.call("numberedRewrite", ["text": content])
  }
}

enum OwlDeepSeekClient {
  struct Usage: Decodable {
    let completionTokens: Int
    let promptTokens: Int
    let promptCacheHitTokens: Int?
    let promptCacheMissTokens: Int?
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
      case completionTokens = "completion_tokens"
      case promptTokens = "prompt_tokens"
      case promptCacheHitTokens = "prompt_cache_hit_tokens"
      case promptCacheMissTokens = "prompt_cache_miss_tokens"
      case totalTokens = "total_tokens"
    }
  }

  struct Response: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        let content: String
      }

      let message: Message
    }

    let choices: [Choice]
    let model: String?
    let usage: Usage?
  }
}

enum OwlCloudRetry {
  static var maxAttempts: Int { OwlLLMCallPurpose.interactiveRewrite.maxAttempts }
  static var backoffNanoseconds: UInt64 { OwlProviderCore.call("retryDelay") }

  static func isRetryable(_ error: Error) -> Bool {
    var kind = "other"
    var status = 0
    switch error {
    case OwlCloudRequestError.emptyResponse: kind = "empty"
    case let OwlCloudRequestError.badHTTPStatus(value, _): kind = "http"; status = value
    case let value as URLError:
      switch value.code {
      case .timedOut: kind = "timeout"
      case .networkConnectionLost: kind = "connectionLost"
      default: break
      }
    default: break
    }
    return OwlProviderCore.call("retry", ["kind": kind, "status": status])
  }
}

/// What a provider profile's wire supports, resolved once from `(providerID, model, host)`.
/// Callers ask this value instead of re-deriving provider identity.
struct OwlProviderCapabilities {
  let dialect: OwlResponsesDialect?
  let thinkingOff: OwlThinkingControl.Fields
  let searchChannel: OwlSearchControl.Channel
  let model: String

  init(providerID: String, model: String, endpoint: URL? = nil) {
    self.dialect = OwlResponsesWire.dialect(providerID: providerID, model: model, endpoint: endpoint)
    self.thinkingOff = OwlThinkingControl.offFields(providerID: providerID, model: model)
    self.searchChannel = Self.searchChannel(providerID: providerID, host: endpoint?.host ?? "")
    self.model = model
  }

  init(routing: OwlCloudRouting) {
    self.init(providerID: routing.providerID, model: routing.model, endpoint: routing.endpoint)
  }

  var sendsChatJSONMode: Bool { OwlProviderCore.call("jsonMode", ["hasSplit": thinkingOff.reasoningSplit != nil]) }

  func temperature(_ value: Double) -> Double? {
    OwlChatSamplingControl.temperature(value, model: model)
  }

  var thinkingOffBody: [String: Any] { OwlThinkingControl.offBody(thinkingOff) }

  var searchTransport: OwlSearchControl.Transport {
    switch searchChannel {
    case .deepSeek: return .deepSeekSearchAPI
    case .none: return .none
    }
  }

  var searchDisplayName: String? { Self.searchDisplayName(searchChannel) }

  static let askSearch = OwlProviderCapabilities(
    providerID: OwlSearchControl.searchProviderID, model: OwlSearchControl.searchModel)

  static func searchDisplayName(providerID: String) -> String? {
    searchDisplayName(searchChannel(providerID: providerID, host: ""))
  }

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

enum OwlLLMCallPurpose: String {
  case interactiveRewrite
  case drafting
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

protocol OwlLLMTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, URLResponse)
  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource
}

extension OwlLLMTransport {
  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource {
    let (data, response) = try await send(request)
    let chunks = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(data); continuation.finish()
    }
    return OwlStreamingBytesSource(response: response as? HTTPURLResponse, dataChunks: chunks)
  }
}

struct OwlURLSessionTransport: OwlLLMTransport {
  final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  static let noRedirectDelegate = NoRedirectDelegate()

  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request, delegate: Self.noRedirectDelegate)
  }

  func openStream(_ request: URLRequest) async throws -> OwlStreamingBytesSource {
    let (bytes, response) = try await session.bytes(for: request, delegate: Self.noRedirectDelegate)
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      let task = Task {
        do {
          var chunk = Data()
          for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
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

struct OwlLLMGateway: Sendable {
  let transport: OwlLLMTransport
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

final class OwlProviderStream {
  private let session: OwlAppSession
  private struct Reply: Decodable { let deltas: [String]; let isFinished: Bool; let failure: String? }
  private var projection = Reply(deltas: [], isFinished: false, failure: nil)
  init(responses: Bool) { session = try! OwlAppSession("providerStream", args: ["responses": responses]) }
  var isFinished: Bool { projection.isFinished }
  var failure: String? { projection.failure }
  func consume(_ data: Data) -> [String] {
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

public final class OwlVoicePolisher: OwlVoicePolishServiceProtocol, @unchecked Sendable {
  public static let shared = OwlVoicePolisher()

  public let endpoint: URL
  public let model: String
  public let temperature: Double
  public let transport: OwlVoiceNetworkTransport
  public var requestTimeout: TimeInterval
  public var timeout: TimeInterval {
    get { requestTimeout }
    set { requestTimeout = newValue }
  }
  public let apiKeyProvider: @Sendable () throws -> String?
  public var isEnabledChecker: @Sendable () -> Bool

  public static let defaultSystemPrompt = """
  你是一个专业的中文语音输入后处理与润色引擎。你的任务是对语音转写的原始文本进行口语清理与纠偏，要求：
  1. 去除无意义口水词、停顿语气词（如“嗯”、“啊”、“那个”、“就是说”、“然后”、“这个”、“呃”）及口吃重复词。
  2. 根据 <personal_hotwords> 提供的个人专名热词列表与 <preceding_context> 光标前文语境，纠正同音或音近的错别字、专有名词、人名与产品名。
  3. 自动补全并规范缺失的中文标点符号（句号、逗号、问号、感叹号等），确保输出符合书面中文标点规范。
  4. 严格保真原意，切勿改写语气、添加额外主观观点或无端改动未读错的字句。
  5. 严禁回答问题、严禁续写解释、严禁输出对话式回复（如“好的”、“润色如下”等客套话），只输出最终润色完成的纯文本，绝不包裹任何 XML 标签或 Markdown 代码块。
  """

  static func resolveProviderKey(
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> String? {
    if let deepSeekKey = OwlVoiceSettings.readConfiguredProfileKey(
      forProviderID: "deepseek",
      store: store,
      secrets: secrets
    ) {
      return deepSeekKey
    }
    if let defaultProfile = store.defaultProfile,
       let raw = try? secrets.secret(named: defaultProfile.secretName) {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  public init(
    endpoint: URL = URL(string: "https://api.deepseek.com/chat/completions")!,
    model: String = "deepseek-chat",
    temperature: Double = 0.1,
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    requestTimeout: TimeInterval = 4.0,
    apiKeyProvider: (@Sendable () throws -> String?)? = nil,
    isEnabledChecker: (@Sendable () -> Bool)? = nil
  ) {
    self.endpoint = endpoint
    self.model = model
    self.temperature = temperature
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.apiKeyProvider = apiKeyProvider ?? {
      if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
        return env
      }
      return Self.resolveProviderKey()
    }
    self.isEnabledChecker = isEnabledChecker ?? { true }
  }

  public static func buildUserPrompt(rawTranscript: String, hotwords: [String], preContext: String?) -> String {
    let contextClean = preContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let contextTag = "<preceding_context>\(contextClean)</preceding_context>"
    let hotwordsClean = hotwords.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let hotwordsTag = "<personal_hotwords>\(hotwordsClean.joined(separator: "，"))</personal_hotwords>"
    let transcriptTag = "<asr_transcript>\(rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines))</asr_transcript>"
    return "\(contextTag)\n\(hotwordsTag)\n\(transcriptTag)"
  }

  public func polish(
    rawTranscript: String,
    hotwords: [String] = [],
    preContext: String? = nil
  ) async throws -> String {
    try Task.checkCancellation()

    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return rawTranscript }
    guard isEnabledChecker() else { return rawTranscript }

    do {
      let rawResult = try await polishWithTimeout(rawTranscript: trimmed, hotwords: hotwords, preContext: preContext)
      try Task.checkCancellation()

      let cleaned = Self.sanitize(polished: rawResult)
      guard Self.validate(raw: trimmed, polished: cleaned) else {
        return trimmed
      }
      return cleaned
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return trimmed
    }
  }

  public func polish(rawTranscript: String) async throws -> String {
    try await polish(rawTranscript: rawTranscript, hotwords: [], preContext: nil)
  }

  public func polishWithTimeout(
    rawTranscript: String,
    hotwords: [String] = [],
    preContext: String? = nil
  ) async throws -> String {
    try Task.checkCancellation()

    guard let apiKey = try apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
      throw OwlVoiceError.missingAPIKey
    }

    let timeoutSecs = self.timeout
    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await self.performNetworkRequest(
          rawTranscript: rawTranscript,
          hotwords: hotwords,
          preContext: preContext,
          apiKey: apiKey
        )
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeoutSecs * 1_000_000_000))
        try Task.checkCancellation()
        throw OwlVoiceError.networkTimeout
      }
      guard let first = try await group.next() else {
        throw OwlVoiceError.networkTimeout
      }
      group.cancelAll()
      return first
    }
  }

  public func performNetworkRequest(
    rawTranscript: String,
    hotwords: [String],
    preContext: String?,
    apiKey: String
  ) async throws -> String {
    let userPrompt = Self.buildUserPrompt(rawTranscript: rawTranscript, hotwords: hotwords, preContext: preContext)

    struct MessageDTO: Codable {
      let role: String
      let content: String
    }

    struct RequestDTO: Codable {
      let model: String
      let messages: [MessageDTO]
      let temperature: Double
      let stream: Bool
      let thinking: OwlDeepSeekThinking
    }

    let requestBody = RequestDTO(
      model: model,
      messages: [
        MessageDTO(role: "system", content: Self.defaultSystemPrompt),
        MessageDTO(role: "user", content: userPrompt)
      ],
      temperature: temperature,
      stream: false,
      thinking: .disabled
    )

    let encodedBody = try JSONEncoder().encode(requestBody)

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = encodedBody

    let (data, response) = try await transport.send(request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OwlVoiceError.badHTTPStatus(status: 0, message: "非 HTTP 协议响应")
    }

    if httpResponse.statusCode != 200 {
      let errorMsg = Self.parseErrorMessage(from: data, removing: apiKey)
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw OwlVoiceError.invalidToken(status: httpResponse.statusCode, message: errorMsg)
      } else {
        throw OwlVoiceError.badHTTPStatus(status: httpResponse.statusCode, message: errorMsg)
      }
    }

    struct ResponseDTO: Decodable {
      struct Choice: Decodable {
        struct Message: Decodable {
          let role: String?
          let content: String?
        }
        let message: Message
      }
      let choices: [Choice]
    }

    let decoded: ResponseDTO
    do {
      decoded = try JSONDecoder().decode(ResponseDTO.self, from: data)
    } catch {
      throw OwlVoiceError.decodingError(error.localizedDescription)
    }

    guard let choice = decoded.choices.first, let content = choice.message.content else {
      throw OwlVoiceError.emptyTranscript
    }

    return content
  }

  public static func validate(raw: String, polished: String) -> Bool {
    let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let maxAllowed = max(raw.count * 2 + 15, 30)
    return trimmed.count <= maxAllowed
  }

  public static func sanitize(polished: String) -> String {
    var text = polished.trimmingCharacters(in: .whitespacesAndNewlines)

    if text.hasPrefix("```") {
      let lines = text.components(separatedBy: .newlines)
      let filtered = lines.filter { !$0.hasPrefix("```") }
      text = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let prefixesToStrip = [
      "润色后：", "润色结果：", "润色：", "修改后：", "修改结果：",
      "以下是润色后的文本：", "以下是润色结果：", "优化后："
    ]
    for prefix in prefixesToStrip {
      if text.hasPrefix(prefix) {
        text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    let xmlTagPairs = [
      ("<asr_transcript>", "</asr_transcript>"),
      ("<raw_transcript>", "</raw_transcript>")
    ]
    for (opening, closing) in xmlTagPairs {
      if text.hasPrefix(opening) && text.hasSuffix(closing) {
        text = String(text.dropFirst(opening.count).dropLast(closing.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        if text.hasPrefix(opening) {
          text = String(text.dropFirst(opening.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasSuffix(closing) {
          text = String(text.dropLast(closing.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }
    for tag in ["<asr_transcript>", "</asr_transcript>", "<raw_transcript>", "</raw_transcript>"] {
      if text.contains(tag) {
        text = text.replacingOccurrences(of: tag, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func parseErrorMessage(from data: Data, removing apiKey: String = "") -> String {
    let raw: String?
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
        raw = msg
      } else if let msg = json["message"] as? String {
        raw = msg
      } else {
        raw = nil
      }
    } else {
      raw = nil
    }
    if let raw, !raw.isEmpty {
      let cleaned = OwlServerErrorDetail(code: nil, message: raw).sanitized(removing: apiKey, maxLength: 200)
      if !cleaned.isEmpty { return cleaned }
    }
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
      let cleaned = OwlServerErrorDetail(code: nil, message: text).sanitized(removing: apiKey, maxLength: 200)
      if !cleaned.isEmpty { return cleaned }
    }
    return "未知错误"
  }
}
