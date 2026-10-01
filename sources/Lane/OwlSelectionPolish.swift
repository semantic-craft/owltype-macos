//
//  OwlSelectionPolish.swift
//  猫头鹰输入法 (Owltype) — B4 选中润色 (selected-text polish → clipboard)
//
//  ⚠️ PRIVACY ⚠️
//  B4 deliberately sends the user's SELECTED DOCUMENT TEXT to the cloud provider. That is
//  justified *only* by an explicit user action (the 划词菜单「润色」action) and is gated by every
//  privacy guard below. It has nothing to do with typing candidates: there is no composition
//  snapshot, no candidate lane, no broker, no 逐键 path. The result is a rewrite replaced in
//  place (or dropped onto the clipboard to ⌘V).
//
//  Enforced here (OwlSelectionPolishService.polishSelection):
//    - require OwlCloudPreferences.isEnabled;
//    - cap the selection length (reject > maxSelectionLength chars — never ship huge uploads);
//    - reuse the Keychain key + json_object contract + bounded retry + OwlNumberedRewriteParser;
//    - NEVER log the selected text or the rewrite (only request-shaped telemetry: model + token
//      counts via OwlCloudUsageTelemetry).
//

import Foundation

/// Errors specific to the B4 selection-polish op. They carry a user-facing message so the
/// controller can surface a precise reason without ever echoing the selected text.
enum OwlSelectionPolishError: Error, Equatable {
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
/// reply shape that `OwlNumberedRewriteParser` parses.
enum OwlSelectionPolish {
  /// Upper bound on selection size sent to the cloud. Selections beyond this are rejected rather
  /// than uploaded — a privacy + cost guard, not a model limit.
  static let maxSelectionLength = 2000

  /// System message (legacy alias): the v1 prompt now lives in `OwlPolishPromptCatalog` as the
  /// `v1-legacy` variant (issue #136 A/B registry); this constant stays so existing call sites and
  /// tests keep reading the same string. The active variant is resolved per request in
  /// `chatRequest` via `OwlPolishPromptCatalog.resolveActive()`.
  static let systemPrompt: String = OwlPolishPromptCatalog.legacySystemPrompt

  /// The user-message body. Selected text is the payload here — see the CodeOnly exception note at
  /// the top of this file. Encoded as a tiny JSON object so the model gets an unambiguous field.
  struct Payload: Codable, Equatable, Sendable {
    let text: String
  }

  /// Pure length / emptiness policy. Returns the error to surface, or `nil` if the selection is
  /// acceptable to send. Trimming mirrors the controller's emptiness check so a whitespace-only
  /// selection is treated as empty.
  static func rejectionReason(for selection: String) -> OwlSelectionPolishError? {
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .emptySelection }
    if selection.count > maxSelectionLength { return .selectionTooLong(selection.count) }
    return nil
  }

  /// Build the chat-shaped request payload for a selection (the Responses providers reuse its
  /// messages + temperature via `OwlResponsesWire`). Same json_object response format the parser
  /// expects. No snapshot involved — this is a standalone text op. The selected document text is
  /// sent verbatim (raw). System prompt + temperature come from the active A/B variant
  /// (issue #136); the default resolves `OwlExperimentalPreferences` per call so flipping the
  /// preference reaches the request body without restarts.
  static func chatRequest(
    for selection: String,
    model: String = OwlCloudPreferences.deepSeekModel,
    providerID: String = "",
    variant: OwlPolishPromptVariant = OwlPolishPromptCatalog.resolveActive()
  ) throws -> OwlDeepSeekChatRequest {
    let data = try JSONEncoder().encode(Payload(text: selection))
    let userContent = String(data: data, encoding: .utf8) ?? "{}"
    let messages = [
      OwlDeepSeekMessage(role: "system", content: variant.systemPrompt),
      OwlDeepSeekMessage(role: "user", content: userContent),
    ]
    // Interactive selection polish — disable hidden thinking so it returns in ~1s (see
    // OwlDeepSeekThinking). deepseek/mimo 沿用 Chat 的 `thinking:{disabled}` 形状
    // （OwlThinkingControl 的 deepSeekStyle）；下方 typed payload 保留旧 Chat 方言供
    // 非 Responses 供应商使用。真正的 Qwen / 豆包 请求会在 client 层改走 Responses，
    // 关思考由 OwlResponsesWire 统一带上（qwen `reasoning.effort:none`、方舟
    // `thinking.type:disabled`——方舟官方示例默认思考一句寒暄就烧 211 reasoning token）。
    // 混合思考模型默认开思考的代价（2026-07-20 实盘百炼旧基线）：润色一句话烧 948
    // reasoning token / 5.4s，直接把 8 秒交互超时打爆；关掉后 0.6s。别家两个字段都 nil
    // 省略。逐家形状由 OwlThinkingControl 单一真相给出：providerID 优先（自定义档案的
    // 模型名可能不带标准前缀，如百炼上托管的 deepseek-* 该走 enable_thinking），传空时
    // 退回 model 前缀判定。
    let thinkingOff = OwlThinkingControl.offFields(providerID: providerID, model: model)
    return OwlDeepSeekChatRequest(
      model: model,
      messages: messages,
      temperature: variant.temperature,
      stream: false,
      // MiniMax documents no JSON mode; keep prompt + local validation as the contract.
      responseFormat: thinkingOff.reasoningSplit == nil ? .jsonObject : nil,
      thinking: thinkingOff.thinking,
      enableThinking: thinkingOff.enableThinking,
      reasoningEffort: thinkingOff.reasoningEffort,
      reasoningSplit: thinkingOff.reasoningSplit
    )
  }
}

/// Networking seam for B4 so the service can be unit-tested with a mock fetcher (no real
/// DeepSeek call).
@MainActor
protocol OwlSelectionPolishFetching {
  func fetchPolishedRewrites(for selection: String, apiKey: String) async throws -> [String]
}

/// DeepSeek-backed selection-polish fetcher. Reuses the shared cloud endpoint, timeout,
/// json_object response decoding, usage telemetry, and `OwlNumberedRewriteParser`. The payload
/// is the user's selected text (see the privacy header above).
struct OwlSelectionPolishClient: OwlSelectionPolishFetching {
  let endpoint: URL
  let model: String
  /// 活跃档案的供应商 id，用来选关思考的字段方言（见 `OwlThinkingControl`）。
  /// 默认空串 = 不知道档案 id，退回按 model 前缀判定。
  let providerID: String
  let authHeaderStyle: OwlProviderAuthHeaderStyle
  let urlSession: URLSession

  init(
    endpoint: URL = OwlCloudPreferences.deepSeekEndpoint,
    model: String = OwlCloudPreferences.deepSeekModel,
    providerID: String = "",
    authHeaderStyle: OwlProviderAuthHeaderStyle = .bearer,
    urlSession: URLSession = .shared
  ) {
    self.endpoint = endpoint
    self.model = model
    self.providerID = providerID
    self.authHeaderStyle = authHeaderStyle
    self.urlSession = urlSession
  }

  func fetchPolishedRewrites(for selection: String, apiKey: String) async throws -> [String] {
    let variant = OwlPolishPromptCatalog.resolveActive()
    // 请求侧观测（issue #136）：沿现有 trace 开关体系只落 variant id + model，绝不落选中文本。
    OwlLiveInputTrace.write { "selection-polish variant=\(variant.id) model=\(model)" }
    let payload = try OwlSelectionPolish.chatRequest(
      for: selection, model: model, providerID: providerID, variant: variant)
    let responsesDialect = OwlResponsesWire.dialect(
      providerID: providerID, model: model, endpoint: endpoint)
    let request: URLRequest
    if let responsesDialect {
      request = try OwlResponsesWire.request(
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
        // （它们收不收这个字段没验过，不在本次范围内）。见 OwlResponsesWire。
        jsonObject: true,
        temperature: payload.temperature,
        timeout: OwlCloudPreferences.requestTimeout)
    } else {
      var chatRequest = URLRequest(url: endpoint)
      chatRequest.httpMethod = "POST"
      chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      authHeaderStyle.apply(to: &chatRequest, apiKey: apiKey)
      chatRequest.timeoutInterval = OwlCloudPreferences.requestTimeout
      chatRequest.httpBody = try JSONEncoder().encode(payload)
      request = chatRequest
    }

    let (data, response) = try await urlSession.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw OwlCloudRequestError.badHTTPStatus(http.statusCode)
    }
    if responsesDialect != nil {
      let decoded = try OwlResponsesWire.parse(data)
      if let usage = decoded.usage {
        OwlCloudUsageTelemetry.record(OwlCloudUsageSnapshot(
          model: decoded.model ?? model,
          completionTokens: usage.outputTokens,
          promptTokens: usage.inputTokens,
          promptCacheHitTokens: usage.cachedTokens,
          promptCacheMissTokens: max(0, usage.inputTokens - usage.cachedTokens),
          totalTokens: usage.totalTokens))
      }
      guard !decoded.text.isEmpty else { throw OwlCloudRequestError.emptyResponse }
      return OwlNumberedRewriteParser.parse(decoded.text)
    }

    let decoded = try JSONDecoder().decode(OwlDeepSeekClient.Response.self, from: data)
    if let usage = decoded.usage {
      // Telemetry only: model + token counts + cache hit/miss. NEVER the selected text or rewrite.
      OwlCloudUsageTelemetry.record(
        OwlCloudUsageSnapshot(
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
      throw OwlCloudRequestError.emptyResponse
    }
    return OwlNumberedRewriteParser.parse(content)
  }
}

/// B4 service: applies the privacy guards, then fetches rewrites with the shared bounded
/// retry. Returns rewrites (best-first) or throws a `OwlSelectionPolishError` the controller can
/// surface. No `OwlCandidateStore`, no lane, no broker — this is a clipboard text op.
@MainActor
final class OwlSelectionPolishService {
  static let shared = OwlSelectionPolishService()

  /// Injected fetcher for tests; nil in production → a client is built per call from the active
  /// provider profile's routing (endpoint + model), via the shared `OwlProviderAuthGate`.
  private let injectedFetcher: OwlSelectionPolishFetching?
  /// Resolves the active profile → routing + key. Built from the injected profile/secret/legacy
  /// (`apiKeyProvider`) closures so tests keep injecting exactly as before. Polish keeps the legacy
  /// DeepSeek fallback (used when NO provider profile is active).
  private let gate: OwlProviderAuthGate

  init(
    fetcher: OwlSelectionPolishFetching? = nil,
    apiKeyProvider: @escaping () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
    profileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) }
  ) {
    self.injectedFetcher = fetcher
    self.gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: apiKeyProvider
    )
  }

  /// Polish the selected text. Guards run BEFORE any keychain / network touch:
  ///   1. isEnabled (default-off cloud gate);
  ///   2. length / emptiness policy (`OwlSelectionPolish.rejectionReason`).
  /// Only then is the active provider routed, its key read, and the bounded-retry fetch issued.
  func polishSelection(_ selection: String) async throws -> [String] {
    guard OwlCloudPreferences.isEnabled else { throw OwlSelectionPolishError.disabled }
    if let reason = OwlSelectionPolish.rejectionReason(for: selection) { throw reason }

    // OWL-098: route through the active provider profile (its endpoint/model + per-profile key)
    // via the shared OwlProviderAuthGate, so 润色选中 works with whatever provider the user
    // configured (OpenAI / Gemini / 自定义 / …), falling back to the legacy DeepSeek key when no
    // profile is set (the gate's `legacyKeyProvider` == this service's `apiKeyProvider`).
    let routing: OwlCloudRouting
    let apiKey: String
    switch gate.resolve() {
    case let .ready(resolvedRouting, resolvedKey):
      routing = resolvedRouting
      apiKey = resolvedKey
    case .unconfigured, .missingKey:
      throw OwlSelectionPolishError.missingAPIKey
    }

    let fetcher = injectedFetcher
      ?? OwlSelectionPolishClient(
        endpoint: routing.endpoint,
        model: routing.model,
        providerID: routing.providerID,
        authHeaderStyle: routing.authHeaderStyle
      )
    return try await fetchWithRetry(fetcher: fetcher, selection: selection, apiKey: apiKey)
  }

  /// One bounded retry for transient failures, reusing the shared `OwlCloudRetry`
  /// policy (timeouts / dropped connections / 500 / 503 / empty content). No snapshot to re-check;
  /// the backoff is a suspension, never a block.
  private func fetchWithRetry(
    fetcher: OwlSelectionPolishFetching,
    selection: String,
    apiKey: String
  ) async throws -> [String] {
    var lastError: Error = OwlCloudRequestError.emptyResponse
    for attempt in 0..<OwlCloudRetry.maxAttempts {
      do {
        return try await fetcher.fetchPolishedRewrites(for: selection, apiKey: apiKey)
      } catch {
        lastError = error
        guard attempt + 1 < OwlCloudRetry.maxAttempts, OwlCloudRetry.isRetryable(error) else { throw error }
        try? await Task.sleep(nanoseconds: OwlCloudRetry.backoffNanoseconds)
      }
    }
    throw lastError
  }
}

// MARK: - Selection skill: source verification

enum OwlSourceVerificationError: Error, Equatable {
  case disabled
  case emptySelection
  case unsupportedProvider
  case missingAPIKey
  case invalidEndpoint
  case badHTTPStatus(Int)
  case emptyResponse
}

struct OwlVerifiedSource: Equatable, Sendable {
  let title: String
  let url: String
}

/// 结构化核验结果：摘要正文 + 抽到的来源列表。回执卡（#135）按锚点渲染进绿/橙卡；
/// 纯文本出口 `verify(_:)` 仍在（`render` 拼装），供无卡路径与既有测试复用。
struct OwlSourceVerificationOutcome: Equatable, Sendable {
  let content: String
  let sources: [OwlVerifiedSource]
}

@MainActor
final class OwlSourceVerificationService {
  static let shared = OwlSourceVerificationService()

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
  private let profileProvider: () -> OwlProviderProfile?
  /// Resolves the active profile → routing + key. `legacyKeyProvider: nil` — 来源核验 has NO legacy
  /// fallback (it needs a configured modern provider; a legacy DeepSeek key can't do web search).
  private let gate: OwlProviderAuthGate

  init(
    urlSession: URLSession = .shared,
    profileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) }
  ) {
    self.urlSession = urlSession
    self.profileProvider = profileProvider
    self.gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: nil
    )
  }

  func verify(_ selectedText: String) async throws -> String {
    let outcome = try await verifyStructured(selectedText)
    return Self.render(content: outcome.content, sources: outcome.sources)
  }

  func verifyStructured(_ selectedText: String) async throws -> OwlSourceVerificationOutcome {
    guard OwlCloudPreferences.isEnabled else { throw OwlSourceVerificationError.disabled }
    if let reason = OwlSelectionPolish.rejectionReason(for: selectedText) {
      switch reason {
      case .emptySelection: throw OwlSourceVerificationError.emptySelection
      case .selectionTooLong: throw OwlSourceVerificationError.emptySelection
      default: throw OwlSourceVerificationError.emptySelection
      }
    }

    let profile = profileProvider()
    guard OwlLLMProviderCatalog.sourceSupport(for: profile).supportsSourceVerification else {
      throw OwlSourceVerificationError.unsupportedProvider
    }
    // Auth via the shared gate (no legacy fallback — see `gate` init). A profile with no stored key
    // → `.missingKey`; both not-ready cases map to this service's `.missingAPIKey`.
    let routing: OwlCloudRouting
    let apiKey: String
    switch gate.resolve() {
    case let .ready(resolvedRouting, resolvedKey):
      routing = resolvedRouting
      apiKey = resolvedKey
    case .unconfigured, .missingKey:
      throw OwlSourceVerificationError.missingAPIKey
    }

    let request = try makeRequest(selectedText: selectedText, routing: routing, apiKey: apiKey)
    let (data, response) = try await urlSession.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw OwlSourceVerificationError.badHTTPStatus(http.statusCode)
    }
    let parsed = Self.parseResponse(data)
    guard !parsed.content.isEmpty || !parsed.sources.isEmpty else {
      throw OwlSourceVerificationError.emptyResponse
    }
    return OwlSourceVerificationOutcome(content: parsed.content, sources: parsed.sources)
  }

  nonisolated static func message(for error: Error) -> String {
    guard let error = error as? OwlSourceVerificationError else {
      return "来源核验失败"
    }
    switch error {
    case .disabled:
      return "云端 AI 未启用"
    case .emptySelection:
      return "未选中文本或选中文本过长"
    case .unsupportedProvider:
      return OwlSelectionSkillPrompts.unsupportedSourceVerificationMessage
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
    routing: OwlCloudRouting,
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
      throw OwlSourceVerificationError.unsupportedProvider
    }
  }

  private func makeChatSearchRequest(
    system: String,
    user: String,
    routing: OwlCloudRouting,
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
    routing: OwlCloudRouting,
    apiKey: String
  ) throws -> URLRequest {
    guard let url = OwlResponsesWire.url(from: routing.endpoint) else {
      throw OwlSourceVerificationError.invalidEndpoint
    }
    // Shared with the streaming 任意提问 client (`OwlResponsesStreamingClient`) so the two
    // callers of `/responses` cannot drift apart.
    let dialect: OwlResponsesDialect = switch routing.providerID {
    case "qwen": .qwen
    case "openai": .openAI
    default: .ark
    }
    let body = OwlResponsesWire.body(
      model: routing.model,
      messages: [
        OwlDeepSeekMessage(role: "system", content: system),
        OwlDeepSeekMessage(role: "user", content: user),
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
    routing: OwlCloudRouting,
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

  // `/responses` 的 URL 改写与 input 消息形状已提取到 `OwlResponsesWire`（与流式 任意提问 共用）。

  nonisolated static func parseResponse(_ data: Data) -> (content: String, sources: [OwlVerifiedSource]) {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      return ("", [])
    }
    let content = firstContent(in: object).trimmingCharacters(in: .whitespacesAndNewlines)
    let sources = collectSources(in: object)
    return (content, sources)
  }

  nonisolated static func render(content: String, sources: [OwlVerifiedSource]) -> String {
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

  private nonisolated static func collectSources(in object: Any) -> [OwlVerifiedSource] {
    var out: [OwlVerifiedSource] = []
    var seen = Set<String>()
    collectSources(in: object, into: &out, seen: &seen)
    return out
  }

  private nonisolated static func collectSources(in object: Any, into out: inout [OwlVerifiedSource], seen: inout Set<String>) {
    if out.count >= 12 { return }
    if let dict = object as? [String: Any] {
      let url = (dict["url"] ?? dict["link"] ?? dict["source_url"] ?? dict["uri"]) as? String
      if let url, url.hasPrefix("http"), seen.insert(url).inserted {
        let title = (dict["title"] ?? dict["name"] ?? dict["site_name"]) as? String
        out.append(OwlVerifiedSource(title: title ?? "", url: url))
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
