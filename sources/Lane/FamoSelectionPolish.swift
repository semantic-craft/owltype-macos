//
//  FamoSelectionPolish.swift
//  法墨输入法 (Famo) — B4 选中润色 (selected-text polish → clipboard)
//
//  ⚠️ PRIVACY ⚠️
//  B4 deliberately sends the user's SELECTED DOCUMENT TEXT to the cloud provider. That is
//  justified *only* by an explicit user action (the 划词菜单「润色」action) and is gated by every
//  privacy guard below. It has nothing to do with typing candidates: there is no composition
//  snapshot, no candidate lane, no broker, no 逐键 path. The result is a rewrite replaced in
//  place (or dropped onto the clipboard to ⌘V).
//
//  Enforced here (FamoSelectionPolishService.polishSelection):
//    - require FamoCloudPreferences.isEnabled;
//    - cap the selection length (reject > maxSelectionLength chars — never ship huge uploads);
//    - reuse the Keychain key + json_object contract + bounded retry + FamoNumberedRewriteParser;
//    - NEVER log the selected text or the rewrite (only request-shaped telemetry: model + token
//      counts via FamoCloudUsageTelemetry).
//

import Foundation

/// Errors specific to the B4 selection-polish op. They carry a user-facing message so the
/// controller can surface a precise reason without ever echoing the selected text.
enum FamoSelectionPolishError: Error, Equatable {
  case disabled
  case emptySelection
  case selectionTooLong(Int)
  case missingAPIKey

  var userMessage: String {
    switch self {
    case .disabled:
      return "云端 AI 未启用"
    case .emptySelection:
      return "未选中文本"
    case .selectionTooLong:
      return "选中文本过长，已取消润色"
    case .missingAPIKey:
      return "云端 AI 的 API Key 未配置"
    }
  }
}

/// Pure prompt + payload + length-policy for B4. Foundation-only so the contract is unit-testable
/// without the IME, the keychain, or the network. Uses the json_object {"candidates":[...]}
/// reply shape that `FamoNumberedRewriteParser` parses.
enum FamoSelectionPolish {
  /// Upper bound on selection size sent to the cloud. Selections beyond this are rejected rather
  /// than uploaded — a privacy + cost guard, not a model limit.
  static let maxSelectionLength = 2000

  /// System message (legacy alias): the v1 prompt now lives in `FamoPolishPromptCatalog` as the
  /// `v1-legacy` variant (issue #136 A/B registry); this constant stays so existing call sites and
  /// tests keep reading the same string. The active variant is resolved per request in
  /// `chatRequest` via `FamoPolishPromptCatalog.resolveActive()`.
  static let systemPrompt: String = FamoPolishPromptCatalog.legacySystemPrompt

  /// The user-message body. Selected text is the payload here — see the CodeOnly exception note at
  /// the top of this file. Encoded as a tiny JSON object so the model gets an unambiguous field.
  struct Payload: Codable, Equatable, Sendable {
    let text: String
  }

  /// Pure length / emptiness policy. Returns the error to surface, or `nil` if the selection is
  /// acceptable to send. Trimming mirrors the controller's emptiness check so a whitespace-only
  /// selection is treated as empty.
  static func rejectionReason(for selection: String) -> FamoSelectionPolishError? {
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .emptySelection }
    if selection.count > maxSelectionLength { return .selectionTooLong(selection.count) }
    return nil
  }

  /// Build the chat-shaped request payload for a selection (the Responses providers reuse its
  /// messages + temperature via `FamoResponsesWire`). Same json_object response format the parser
  /// expects. No snapshot involved — this is a standalone text op. The selected document text is
  /// sent verbatim (raw). System prompt + temperature come from the active A/B variant
  /// (issue #136); the default resolves `FamoExperimentalPreferences` per call so flipping the
  /// preference reaches the request body without restarts.
  static func chatRequest(
    for selection: String,
    model: String = FamoCloudPreferences.deepSeekModel,
    providerID: String = "",
    variant: FamoPolishPromptVariant = FamoPolishPromptCatalog.resolveActive()
  ) throws -> FamoDeepSeekChatRequest {
    let data = try JSONEncoder().encode(Payload(text: selection))
    let userContent = String(data: data, encoding: .utf8) ?? "{}"
    let messages = [
      FamoDeepSeekMessage(role: "system", content: variant.systemPrompt),
      FamoDeepSeekMessage(role: "user", content: userContent),
    ]
    // Interactive selection polish — disable hidden thinking so it returns in ~1s (see
    // FamoDeepSeekThinking). deepseek/mimo 沿用 Chat 的 `thinking:{disabled}` 形状
    // （FamoThinkingControl 的 deepSeekStyle）；下方 typed payload 保留旧 Chat 方言供
    // 非 Responses 供应商使用。真正的 Qwen / 豆包 请求会在 client 层改走 Responses，
    // 关思考由 FamoResponsesWire 统一带上（qwen `reasoning.effort:none`、方舟
    // `thinking.type:disabled`——方舟官方示例默认思考一句寒暄就烧 211 reasoning token）。
    // 混合思考模型默认开思考的代价（2026-07-20 实盘百炼旧基线）：润色一句话烧 948
    // reasoning token / 5.4s，直接把 8 秒交互超时打爆；关掉后 0.6s。别家两个字段都 nil
    // 省略。逐家形状由 FamoThinkingControl 单一真相给出：providerID 优先（自定义档案的
    // 模型名可能不带标准前缀，如百炼上托管的 deepseek-* 该走 enable_thinking），传空时
    // 退回 model 前缀判定。
    let thinkingOff = FamoThinkingControl.offFields(providerID: providerID, model: model)
    return FamoDeepSeekChatRequest(
      model: model,
      messages: messages,
      temperature: variant.temperature,
      stream: false,
      responseFormat: .jsonObject,
      thinking: thinkingOff.thinking,
      enableThinking: thinkingOff.enableThinking
    )
  }
}

/// Networking seam for B4 so the service can be unit-tested with a mock fetcher (no real
/// DeepSeek call).
@MainActor
protocol FamoSelectionPolishFetching {
  func fetchPolishedRewrites(for selection: String, apiKey: String) async throws -> [String]
}

/// DeepSeek-backed selection-polish fetcher. Reuses the shared cloud endpoint, timeout,
/// json_object response decoding, usage telemetry, and `FamoNumberedRewriteParser`. The payload
/// is the user's selected text (see the privacy header above).
struct FamoSelectionPolishClient: FamoSelectionPolishFetching {
  let endpoint: URL
  let model: String
  /// 活跃档案的供应商 id，用来选关思考的字段方言（见 `FamoThinkingControl`）。
  /// 默认空串 = 不知道档案 id，退回按 model 前缀判定。
  let providerID: String
  let authHeaderStyle: FamoProviderAuthHeaderStyle
  let urlSession: URLSession

  init(
    endpoint: URL = FamoCloudPreferences.deepSeekEndpoint,
    model: String = FamoCloudPreferences.deepSeekModel,
    providerID: String = "",
    authHeaderStyle: FamoProviderAuthHeaderStyle = .bearer,
    urlSession: URLSession = .shared
  ) {
    self.endpoint = endpoint
    self.model = model
    self.providerID = providerID
    self.authHeaderStyle = authHeaderStyle
    self.urlSession = urlSession
  }

  func fetchPolishedRewrites(for selection: String, apiKey: String) async throws -> [String] {
    let variant = FamoPolishPromptCatalog.resolveActive()
    // 请求侧观测（issue #136）：沿现有 trace 开关体系只落 variant id + model，绝不落选中文本。
    FamoLiveInputTrace.write { "selection-polish variant=\(variant.id) model=\(model)" }
    let payload = try FamoSelectionPolish.chatRequest(
      for: selection, model: model, providerID: providerID, variant: variant)
    let responsesDialect = FamoResponsesWire.dialect(
      providerID: providerID, model: model, endpoint: endpoint)
    let request: URLRequest
    if let responsesDialect {
      request = try FamoResponsesWire.request(
        endpoint: endpoint,
        model: model,
        messages: payload.messages,
        apiKey: apiKey,
        authHeaderStyle: authHeaderStyle,
        dialect: responsesDialect,
        stream: false,
        webSearch: false,
        // 与下方 chat 分支的 `payload.responseFormat = .jsonObject` 对等。只有 `.deepseek` 方言
        // 真的落 `text.format`：Qwen/豆包 当初迁 Responses 时就没带这一项，本次不动它们的请求体
        // （它们收不收这个字段没验过，不在本次范围内）。见 FamoResponsesWire。
        jsonObject: true,
        temperature: payload.temperature,
        timeout: FamoCloudPreferences.requestTimeout)
    } else {
      var chatRequest = URLRequest(url: endpoint)
      chatRequest.httpMethod = "POST"
      chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      authHeaderStyle.apply(to: &chatRequest, apiKey: apiKey)
      chatRequest.timeoutInterval = FamoCloudPreferences.requestTimeout
      chatRequest.httpBody = try JSONEncoder().encode(payload)
      request = chatRequest
    }

    let (data, response) = try await urlSession.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw FamoCloudRequestError.badHTTPStatus(http.statusCode)
    }
    if responsesDialect != nil {
      let decoded = try FamoResponsesWire.parse(data)
      if let usage = decoded.usage {
        FamoCloudUsageTelemetry.record(FamoCloudUsageSnapshot(
          model: decoded.model ?? model,
          completionTokens: usage.outputTokens,
          promptTokens: usage.inputTokens,
          promptCacheHitTokens: usage.cachedTokens,
          promptCacheMissTokens: max(0, usage.inputTokens - usage.cachedTokens),
          totalTokens: usage.totalTokens))
      }
      guard !decoded.text.isEmpty else { throw FamoCloudRequestError.emptyResponse }
      return FamoNumberedRewriteParser.parse(decoded.text)
    }

    let decoded = try JSONDecoder().decode(FamoDeepSeekClient.Response.self, from: data)
    if let usage = decoded.usage {
      // Telemetry only: model + token counts + cache hit/miss. NEVER the selected text or rewrite.
      FamoCloudUsageTelemetry.record(
        FamoCloudUsageSnapshot(
          model: decoded.model ?? model,
          completionTokens: usage.completionTokens,
          promptTokens: usage.promptTokens,
          promptCacheHitTokens: usage.promptCacheHitTokens ?? 0,
          promptCacheMissTokens: usage.promptCacheMissTokens ?? 0,
          totalTokens: usage.totalTokens
        )
      )
    }
    guard let content = decoded.choices.first?.message.content else {
      throw FamoCloudRequestError.emptyResponse
    }
    return FamoNumberedRewriteParser.parse(content)
  }
}

/// B4 service: applies the privacy guards, then fetches rewrites with the shared bounded
/// retry. Returns rewrites (best-first) or throws a `FamoSelectionPolishError` the controller can
/// surface. No `FamoCandidateStore`, no lane, no broker — this is a clipboard text op.
@MainActor
final class FamoSelectionPolishService {
  static let shared = FamoSelectionPolishService()

  /// Injected fetcher for tests; nil in production → a client is built per call from the active
  /// provider profile's routing (endpoint + model), via the shared `FamoProviderAuthGate`.
  private let injectedFetcher: FamoSelectionPolishFetching?
  /// Resolves the active profile → routing + key. Built from the injected profile/secret/legacy
  /// (`apiKeyProvider`) closures so tests keep injecting exactly as before. Polish keeps the legacy
  /// DeepSeek fallback (used when NO provider profile is active).
  private let gate: FamoProviderAuthGate

  init(
    fetcher: FamoSelectionPolishFetching? = nil,
    apiKeyProvider: @escaping () throws -> String? = FamoCloudKeychain.readDeepSeekAPIKey,
    profileProvider: @escaping () -> FamoProviderProfile? = { FamoProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try FamoProviderKeychain().secret(named: $0) }
  ) {
    self.injectedFetcher = fetcher
    self.gate = FamoProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: apiKeyProvider
    )
  }

  /// Polish the selected text. Guards run BEFORE any keychain / network touch:
  ///   1. isEnabled (default-off cloud gate);
  ///   2. length / emptiness policy (`FamoSelectionPolish.rejectionReason`).
  /// Only then is the active provider routed, its key read, and the bounded-retry fetch issued.
  func polishSelection(_ selection: String) async throws -> [String] {
    guard FamoCloudPreferences.isEnabled else { throw FamoSelectionPolishError.disabled }
    if let reason = FamoSelectionPolish.rejectionReason(for: selection) { throw reason }

    // FAMO-098: route through the active provider profile (its endpoint/model + per-profile key)
    // via the shared FamoProviderAuthGate, so 润色选中 works with whatever provider the user
    // configured (OpenAI / Gemini / 自定义 / …), falling back to the legacy DeepSeek key when no
    // profile is set (the gate's `legacyKeyProvider` == this service's `apiKeyProvider`).
    let routing: FamoCloudRouting
    let apiKey: String
    switch gate.resolve() {
    case let .ready(resolvedRouting, resolvedKey):
      routing = resolvedRouting
      apiKey = resolvedKey
    case .unconfigured, .missingKey:
      throw FamoSelectionPolishError.missingAPIKey
    }

    let fetcher = injectedFetcher
      ?? FamoSelectionPolishClient(
        endpoint: routing.endpoint,
        model: routing.model,
        providerID: routing.providerID,
        authHeaderStyle: routing.authHeaderStyle
      )
    return try await fetchWithRetry(fetcher: fetcher, selection: selection, apiKey: apiKey)
  }

  /// One bounded retry for transient failures, reusing the shared `FamoCloudRetry`
  /// policy (timeouts / dropped connections / 500 / 503 / empty content). No snapshot to re-check;
  /// the backoff is a suspension, never a block.
  private func fetchWithRetry(
    fetcher: FamoSelectionPolishFetching,
    selection: String,
    apiKey: String
  ) async throws -> [String] {
    var lastError: Error = FamoCloudRequestError.emptyResponse
    for attempt in 0..<FamoCloudRetry.maxAttempts {
      do {
        return try await fetcher.fetchPolishedRewrites(for: selection, apiKey: apiKey)
      } catch {
        lastError = error
        guard attempt + 1 < FamoCloudRetry.maxAttempts, FamoCloudRetry.isRetryable(error) else { throw error }
        try? await Task.sleep(nanoseconds: FamoCloudRetry.backoffNanoseconds)
      }
    }
    throw lastError
  }
}

// MARK: - Selection skill: source verification

enum FamoSourceVerificationError: Error, Equatable {
  case disabled
  case emptySelection
  case unsupportedProvider
  case missingAPIKey
  case invalidEndpoint
  case badHTTPStatus(Int)
  case emptyResponse
}

struct FamoVerifiedSource: Equatable, Sendable {
  let title: String
  let url: String
}

/// 结构化核验结果：摘要正文 + 抽到的来源列表。回执卡（#135）按锚点渲染进绿/橙卡；
/// 纯文本出口 `verify(_:)` 仍在（`render` 拼装），供无卡路径与既有测试复用。
struct FamoSourceVerificationOutcome: Equatable, Sendable {
  let content: String
  let sources: [FamoVerifiedSource]
}

@MainActor
final class FamoSourceVerificationService {
  static let shared = FamoSourceVerificationService()

  /// Product prompt surfaced for the live Responses-API evaluation. Keeping it here (rather than
  /// copying it into the test) makes the evaluated bytes the same bytes production sends.
  ///
  /// 2026-07-31 来源质量加固：明确一手官方来源优先。此前模型常拿聚合站/百科转载当来源，
  /// 用户要跳查的恰恰是「发布机关自己怎么说」。
  nonisolated static let systemPrompt =
    "你是来源核验助手。必须使用联网检索结果核验选中文本。不要凭常识补来源；没有可核 URL 时说明需要人工确认。"
    + "来源按权威优先：优先给出一手官方来源（发布机关、法院、政府官网或法规公报、标准原文页）；"
    + "确无一手来源时才用权威媒体或数据库转载，并注明系转载。"

  nonisolated static func userPrompt(for selectedText: String) -> String {
    "请核验以下选中文本，并返回判断、可核来源 URL、关键信息。选中文本：\n\(selectedText)"
  }

  private let urlSession: URLSession
  /// Kept for the `sourceSupport` capability gate (a profile-level check, run before auth).
  private let profileProvider: () -> FamoProviderProfile?
  /// Resolves the active profile → routing + key. `legacyKeyProvider: nil` — 来源核验 has NO legacy
  /// fallback (it needs a configured modern provider; a legacy DeepSeek key can't do web search).
  private let gate: FamoProviderAuthGate

  init(
    urlSession: URLSession = .shared,
    profileProvider: @escaping () -> FamoProviderProfile? = { FamoProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try FamoProviderKeychain().secret(named: $0) }
  ) {
    self.urlSession = urlSession
    self.profileProvider = profileProvider
    self.gate = FamoProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: nil
    )
  }

  func verify(_ selectedText: String) async throws -> String {
    let outcome = try await verifyStructured(selectedText)
    return Self.render(content: outcome.content, sources: outcome.sources)
  }

  func verifyStructured(_ selectedText: String) async throws -> FamoSourceVerificationOutcome {
    guard FamoCloudPreferences.isEnabled else { throw FamoSourceVerificationError.disabled }
    if let reason = FamoSelectionPolish.rejectionReason(for: selectedText) {
      switch reason {
      case .emptySelection: throw FamoSourceVerificationError.emptySelection
      case .selectionTooLong: throw FamoSourceVerificationError.emptySelection
      default: throw FamoSourceVerificationError.emptySelection
      }
    }

    let profile = profileProvider()
    guard FamoLLMProviderCatalog.sourceSupport(for: profile).supportsSourceVerification else {
      throw FamoSourceVerificationError.unsupportedProvider
    }
    // Auth via the shared gate (no legacy fallback — see `gate` init). A profile with no stored key
    // → `.missingKey`; both not-ready cases map to this service's `.missingAPIKey`.
    let routing: FamoCloudRouting
    let apiKey: String
    switch gate.resolve() {
    case let .ready(resolvedRouting, resolvedKey):
      routing = resolvedRouting
      apiKey = resolvedKey
    case .unconfigured, .missingKey:
      throw FamoSourceVerificationError.missingAPIKey
    }

    let request = try makeRequest(selectedText: selectedText, routing: routing, apiKey: apiKey)
    let (data, response) = try await urlSession.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw FamoSourceVerificationError.badHTTPStatus(http.statusCode)
    }
    let parsed = Self.parseResponse(data)
    guard !parsed.content.isEmpty || !parsed.sources.isEmpty else {
      throw FamoSourceVerificationError.emptyResponse
    }
    return FamoSourceVerificationOutcome(content: parsed.content, sources: parsed.sources)
  }

  nonisolated static func message(for error: Error) -> String {
    guard let error = error as? FamoSourceVerificationError else {
      return "来源核验失败"
    }
    switch error {
    case .disabled:
      return "云端 AI 未启用"
    case .emptySelection:
      return "未选中文本或选中文本过长"
    case .unsupportedProvider:
      return FamoSelectionSkillPrompts.unsupportedSourceVerificationMessage
    case .missingAPIKey:
      return "云端 AI 的 API Key 未配置"
    case .invalidEndpoint:
      return "当前供应商端点不支持来源核验"
    case .badHTTPStatus(let status):
      return "来源核验请求失败（\(status)）"
    case .emptyResponse:
      return "未找到可核来源。注意：这不等于事实不存在。"
    }
  }

  private func makeRequest(
    selectedText: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) throws -> URLRequest {
    let system = Self.systemPrompt
    let user = Self.userPrompt(for: selectedText)

    switch routing.providerID {
    case "mimo":
      return try makeChatSearchRequest(system: system, user: user, routing: routing, apiKey: apiKey)
    case "qwen", "doubao", "openai":
      return try makeResponsesSearchRequest(system: system, user: user, routing: routing, apiKey: apiKey)
    default:
      throw FamoSourceVerificationError.unsupportedProvider
    }
  }

  private func makeChatSearchRequest(
    system: String,
    user: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) throws -> URLRequest {
    var body: [String: Any] = [
      "model": routing.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "temperature": 0.2,
      "stream": false,
    ]
    if routing.providerID == "mimo" {
      body["thinking"] = ["type": "disabled"]
      body["tool_choice"] = "auto"
      body["tools"] = [[
        "type": "web_search",
        "max_keyword": 3,
        "force_search": true,
        "limit": 2,
      ]]
    }
    return try makeJSONRequest(url: routing.endpoint, body: body, routing: routing, apiKey: apiKey)
  }

  private func makeResponsesSearchRequest(
    system: String,
    user: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) throws -> URLRequest {
    guard let url = FamoResponsesWire.url(from: routing.endpoint) else {
      throw FamoSourceVerificationError.invalidEndpoint
    }
    // Shared with the streaming 任意提问 client (`FamoResponsesStreamingClient`) so the two
    // callers of `/responses` cannot drift apart.
    let dialect: FamoResponsesDialect = switch routing.providerID {
    case "qwen": .qwen
    case "openai": .openAI
    default: .ark
    }
    let body = FamoResponsesWire.body(
      model: routing.model,
      messages: [
        FamoDeepSeekMessage(role: "system", content: system),
        FamoDeepSeekMessage(role: "user", content: user),
      ],
      stream: false,
      dialect: dialect,
      webSearch: true,
      temperature: 0.2
    )
    return try makeJSONRequest(url: url, body: body, routing: routing, apiKey: apiKey)
  }

  private func makeJSONRequest(
    url: URL,
    body: [String: Any],
    routing: FamoCloudRouting,
    apiKey: String
  ) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    routing.authHeaderStyle.apply(to: &request, apiKey: apiKey)
    request.timeoutInterval = 90
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  // `/responses` 的 URL 改写与 input 消息形状已提取到 `FamoResponsesWire`（与流式 任意提问 共用）。

  nonisolated static func parseResponse(_ data: Data) -> (content: String, sources: [FamoVerifiedSource]) {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      return ("", [])
    }
    let content = firstContent(in: object).trimmingCharacters(in: .whitespacesAndNewlines)
    let sources = collectSources(in: object)
    return (content, sources)
  }

  nonisolated static func render(content: String, sources: [FamoVerifiedSource]) -> String {
    if !sources.isEmpty {
      let sourceLines = sources.prefix(8).map { source in
        "- \(source.title.isEmpty ? source.url : source.title)\n  \(source.url)"
      }.joined(separator: "\n")
      let summary = content.trimmingCharacters(in: .whitespacesAndNewlines)
      return """
      已找到可核来源

      \(summary.isEmpty ? "已通过联网检索取得来源 URL，请人工复核来源内容与原文主张是否完全对应。" : summary)

      来源：
      \(sourceLines)
      """
    }
    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return """
      需要人工确认

      模型返回了联网核验摘要，但没有返回可抽取的来源 URL。不要把下面内容当作已完成核验：

      \(content)
      """
    }
    return "未找到可核来源。注意：这不等于事实不存在。"
  }

  private nonisolated static func firstContent(in object: Any) -> String {
    if let dict = object as? [String: Any] {
      if let choices = dict["choices"] as? [[String: Any]],
         let message = choices.first?["message"] as? [String: Any],
         let content = message["content"] as? String {
        return content
      }
      if let output = dict["output"] as? [String: Any] {
        if let text = output["text"] as? String { return text }
        if let choices = output["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
          return content
        }
      }
      if let output = dict["output"] as? [[String: Any]] {
        for item in output {
          if let content = item["content"] as? [[String: Any]] {
            for part in content {
              if let text = part["text"] as? String { return text }
            }
          }
        }
      }
      for value in dict.values {
        let nested = firstContent(in: value)
        if !nested.isEmpty { return nested }
      }
    }
    if let array = object as? [Any] {
      for value in array {
        let nested = firstContent(in: value)
        if !nested.isEmpty { return nested }
      }
    }
    return ""
  }

  private nonisolated static func collectSources(in object: Any) -> [FamoVerifiedSource] {
    var out: [FamoVerifiedSource] = []
    var seen = Set<String>()
    collectSources(in: object, into: &out, seen: &seen)
    return out
  }

  private nonisolated static func collectSources(in object: Any, into out: inout [FamoVerifiedSource], seen: inout Set<String>) {
    if out.count >= 12 { return }
    if let dict = object as? [String: Any] {
      let url = (dict["url"] ?? dict["link"] ?? dict["source_url"] ?? dict["uri"]) as? String
      if let url, url.hasPrefix("http"), seen.insert(url).inserted {
        let title = (dict["title"] ?? dict["name"] ?? dict["site_name"]) as? String
        out.append(FamoVerifiedSource(title: title ?? "", url: url))
      }
      for value in dict.values {
        collectSources(in: value, into: &out, seen: &seen)
      }
    } else if let array = object as? [Any] {
      for value in array {
        collectSources(in: value, into: &out, seen: &seen)
      }
    }
  }
}
