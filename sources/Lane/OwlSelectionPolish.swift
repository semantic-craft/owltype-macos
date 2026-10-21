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
    // OwlDeepSeekThinking). deepseek 沿用 Chat 的 `thinking:{disabled}` 形状
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
      temperature: OwlChatSamplingControl.temperature(variant.temperature, model: model),
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
  /// 来源核验靠联网搜索取来源；豆包搜索 Key 与能联网的 DeepSeek 档案都没配，就无从核验。
  case missingSearchKey
  case search(OwlDoubaoSearchError)
  case badHTTPStatus(Int)
  case emptyResponse
}

struct OwlVerifiedSource: Equatable, Sendable {
  let title: String
  let url: String
}

/// 结构化核验结果：判断正文 + 来源列表。回执卡（#135）按锚点渲染进绿/橙卡。
struct OwlSourceVerificationOutcome: Equatable, Sendable {
  let content: String
  let sources: [OwlVerifiedSource]
}

/// 来源核验：豆包搜索与 DeepSeek 内置联网搜索，配了哪个用哪个，都配了就一起用。
///
///   - 有能联网的 DeepSeek 档案（deepseek-v4-flash，与任意提问联网同一套解析）：DeepSeek 自己联网
///     检索并判断；配了豆包搜索时，豆包结果编号放进提示词一并参考。来源 = 豆包结果 + DeepSeek 搜到的。
///   - 只有豆包搜索：豆包取回网页，默认供应商对照判断；没配默认供应商时只回来源列表，由用户复核。
///
/// 来源只来自搜索结果本身（标题 + URL），不让模型凭空补来源。
@MainActor
final class OwlSourceVerificationService {
  static let shared = OwlSourceVerificationService()

  /// 每次核验取回的网页数。卡片最多展示 8 条，多取无益，还占模型上下文。
  static let resultCount = 8

  /// Product prompt surfaced for the live evaluation. Keeping it here (rather than copying it into
  /// the test) makes the evaluated bytes the same bytes production sends.
  ///
  /// 来源按权威优先：用户要跳查的恰恰是「发布机关自己怎么说」，聚合站/百科转载只能兜底。
  nonisolated static let systemPrompt =
    "你是来源核验助手。只依据给出的检索结果核验选中文本，不要凭常识补来源；"
    + "检索结果不足以判断时，直接说明需要人工确认。"
    + "来源按权威优先：优先引用一手官方来源（发布机关、法院、政府官网或法规公报、标准原文页）；"
    + "确无一手来源时才用权威媒体或数据库转载，并注明系转载。引用时用 [序号] 标注对应的检索结果。"

  /// DeepSeek 自带联网时的系统提示：检索结果多了它自己搜到的网页，其余口径与 `systemPrompt` 一致。
  nonisolated static let webSearchSystemPrompt =
    "你是来源核验助手。先联网检索，再只依据检索结果核验选中文本，不要凭常识补来源；"
    + "检索结果不足以判断时，直接说明需要人工确认。"
    + "来源按权威优先：优先引用一手官方来源（发布机关、法院、政府官网或法规公报、标准原文页）；"
    + "确无一手来源时才用权威媒体或数据库转载，并注明系转载。"
    + "引用给出的检索结果时用 [序号]；引用你自己搜到的网页时写成 [标题](网址)。"

  /// DeepSeek 联网检索单独作答（没有豆包结果）时的用户提示。
  nonisolated static func webSearchUserPrompt(for selectedText: String) -> String {
    """
    请联网检索并核验以下选中文本，给出判断、支持判断的来源（[标题](网址)）和关键信息。

    选中文本：
    \(selectedText)
    """
  }

  nonisolated static func userPrompt(
    for selectedText: String,
    results: [OwlDoubaoSearchResult]
  ) -> String {
    let body = results.enumerated().map { index, result in
      var lines = ["[\(index + 1)] \(result.title)"]
      if let host = result.hostname { lines.append("来源：\(host)") }
      if let published = result.publishedAt { lines.append("发布时间：\(published)") }
      lines.append("网址：\(result.url)")
      if !result.snippet.isEmpty { lines.append("摘要：\(result.snippet)") }
      return lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
    return """
      请核验以下选中文本，给出判断、支持判断的来源序号和关键信息。

      选中文本：
      \(selectedText)

      检索结果：
      \(body)
      """
  }

  /// DeepSeek 联网检索实测中位 16.6s（见 `OwlResponsesWire` 的 `.deepseek` 注释），普通请求的
  /// 8 秒超时会把它几乎全部掐掉。
  static let webSearchTimeout: TimeInterval = 90

  private let searchClient: OwlDoubaoSearching
  private let searchKeyProvider: () -> String?
  private let webSearchRoutesProvider: @MainActor () -> [OwlAskSearchRoute]
  private let webSearchFetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let gate: OwlProviderAuthGate
  private let transport: OwlAskAnythingTransporting

  /// 能用 DeepSeek 内置联网核验的档案，顺序同任意提问联网。不看任意提问的联网开关：
  /// 来源核验本身就是「要联网」的动作。
  static func deepSeekSearchRoutes() -> [OwlAskSearchRoute] {
    OwlAskSearchResolver(isEnabled: { true }).resolveAll()
  }

  /// 卡片据此决定要不要给「联网核验」按钮。
  static func isOnlineVerifyAvailable() -> Bool {
    OwlCloudPreferences.isEnabled
      && (OwlDoubaoSearchKeyStore.isConfigured() || !deepSeekSearchRoutes().isEmpty)
  }

  init(
    searchClient: OwlDoubaoSearching = OwlDoubaoSearchClient(),
    searchKeyProvider: @escaping () -> String? = { OwlDoubaoSearchKeyStore.apiKey() },
    webSearchRoutesProvider: @escaping @MainActor () -> [OwlAskSearchRoute] = {
      @MainActor in OwlSourceVerificationService.deepSeekSearchRoutes()
    },
    webSearchFetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
    profileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) },
    legacyKeyProvider: @escaping () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
    transport: OwlAskAnythingTransporting? = nil
  ) {
    self.searchClient = searchClient
    self.searchKeyProvider = searchKeyProvider
    self.webSearchRoutesProvider = webSearchRoutesProvider
    self.webSearchFetch = webSearchFetch ?? { try await URLSession.shared.data(for: $0) }
    self.gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider
    )
    self.transport = transport ?? OwlAskAnythingTransportAdapter(
      chatClient: OwlStreamingChatClient(),
      responsesClient: OwlResponsesStreamingClient())
  }

  func verifyStructured(_ selectedText: String) async throws -> OwlSourceVerificationOutcome {
    guard OwlCloudPreferences.isEnabled else { throw OwlSourceVerificationError.disabled }
    if OwlSelectionPolish.rejectionReason(for: selectedText) != nil {
      throw OwlSourceVerificationError.emptySelection
    }
    let searchKey = searchKeyProvider()
    let webSearchRoutes = webSearchRoutesProvider()
    guard searchKey != nil || !webSearchRoutes.isEmpty else {
      throw OwlSourceVerificationError.missingSearchKey
    }

    var results: [OwlDoubaoSearchResult] = []
    if let searchKey {
      do {
        results = try await searchClient.search(
          query: selectedText, apiKey: searchKey, limit: Self.resultCount)
      } catch let error as OwlDoubaoSearchError {
        // 还有 DeepSeek 联网兜底时，豆包这一路失败不挡核验；只有豆包一路时如实报错。
        guard !webSearchRoutes.isEmpty else { throw OwlSourceVerificationError.search(error) }
      }
    }
    let sources = results.map { OwlVerifiedSource(title: $0.title, url: $0.url) }

    if !webSearchRoutes.isEmpty {
      let refusedStatus: Int
      switch try await verifyWithWebSearch(
        selectedText, results: results, sources: sources, routes: webSearchRoutes) {
      case let .done(outcome):
        return outcome
      case let .refused(status):
        refusedStatus = status
      case .unsearched:
        refusedStatus = 0
      }
      // 每个 DeepSeek 档案都被明确拒绝（Key 失效 / 欠费），或没搜也没给出可用判断：有豆包结果
      // 就退回默认供应商判断；没有就如实报错——没搜过的链接不能当来源交给用户。
      guard !results.isEmpty else {
        throw refusedStatus == 0
          ? OwlSourceVerificationError.emptyResponse
          : OwlSourceVerificationError.badHTTPStatus(refusedStatus)
      }
    }
    guard !results.isEmpty else { throw OwlSourceVerificationError.emptyResponse }

    guard case let .ready(routing, apiKey) = gate.resolve() else {
      // 没配作答模型：来源仍然可跳查，判断留给用户（卡片会提示人工复核）。
      return OwlSourceVerificationOutcome(content: "", sources: sources)
    }
    let messages = [
      OwlDeepSeekMessage(role: "system", content: Self.systemPrompt),
      OwlDeepSeekMessage(
        role: "user", content: Self.userPrompt(for: selectedText, results: results)),
    ]
    var content = ""
    do {
      for try await delta in transport.streamPlain(
        messages: messages, routing: routing, apiKey: apiKey) {
        content += delta
      }
    } catch let OwlStreamingError.badHTTPStatus(status) {
      throw OwlSourceVerificationError.badHTTPStatus(status)
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return OwlSourceVerificationOutcome(
      content: trimmed, sources: Self.citedFirst(sources, in: trimmed))
  }

  private enum WebSearchAttempt {
    case done(OwlSourceVerificationOutcome)
    /// 所有档案都是配置拒绝（401/402/403/404），带最后一个状态码。
    case refused(Int)
    /// 没有豆包结果、响应里也没有一次 `web_search_call`（凭记忆写的），或干脆没回正文。
    case unsearched
  }

  /// DeepSeek `/responses` + 内置 `web_search`，非流式，好拿到它检索过的网页。档案逐个试，
  /// 只在配置拒绝时换下一个——与任意提问联网的顺位规则同一判据（`OwlAskSearchFailover`）。
  private func verifyWithWebSearch(
    _ selectedText: String,
    results: [OwlDoubaoSearchResult],
    sources: [OwlVerifiedSource],
    routes: [OwlAskSearchRoute]
  ) async throws -> WebSearchAttempt {
    let messages = [
      OwlDeepSeekMessage(role: "system", content: Self.webSearchSystemPrompt),
      OwlDeepSeekMessage(
        role: "user",
        content: results.isEmpty
          ? Self.webSearchUserPrompt(for: selectedText)
          : Self.userPrompt(for: selectedText, results: results)),
    ]
    var lastStatus = 0
    for route in routes {
      let request = try OwlResponsesWire.request(
        endpoint: route.routing.endpoint,
        model: route.routing.model,
        messages: messages,
        apiKey: route.apiKey,
        authHeaderStyle: route.routing.authHeaderStyle,
        dialect: .deepseek,
        stream: false,
        webSearch: true,
        timeout: Self.webSearchTimeout)
      let (data, response) = try await webSearchFetch(request)
      if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        guard OwlAskSearchFailover.isConfigurationRefusal(status: http.statusCode) else {
          throw OwlSourceVerificationError.badHTTPStatus(http.statusCode)
        }
        lastStatus = http.statusCode
        continue
      }
      guard let decoded = try? OwlResponsesWire.parse(data) else {
        throw OwlSourceVerificationError.emptyResponse
      }
      if let usage = decoded.usage {
        OwlCloudUsageTelemetry.record(OwlCloudUsageSnapshot(
          model: decoded.model ?? route.routing.model,
          completionTokens: usage.outputTokens,
          promptTokens: usage.inputTokens,
          promptCacheHitTokens: usage.cachedTokens,
          promptCacheMissTokens: max(0, usage.inputTokens - usage.cachedTokens),
          totalTokens: usage.totalTokens))
      }
      let searched = decoded.searchCallCount > 0
      // 没搜过的回答只在手里有豆包结果时可用：那时 `[序号]` 指向真取回的网页；它自己写的链接
      // 是凭记忆的，一条不收。没有豆包结果又没搜，就不算核验。
      guard searched || !results.isEmpty else { return .unsearched }
      let content = decoded.text
      guard !content.isEmpty else { return .unsearched }
      let found = searched
        ? decoded.sources.map { OwlVerifiedSource(title: $0.title, url: $0.url) }
          + Self.linkedSources(in: content)
        : []
      let merged = Self.mergedSources(Self.citedFirst(sources, in: content), found)
      guard !content.isEmpty || !merged.isEmpty else {
        throw OwlSourceVerificationError.emptyResponse
      }
      return .done(OwlSourceVerificationOutcome(content: content, sources: merged))
    }
    return .refused(lastStatus)
  }

  /// 正文里 `[标题](网址)` 形式的引用。2026-10-21 实测 DeepSeek 的 `web_search_call` 只带检索词、
  /// 正文 annotations 为空，来源只出现在正文链接里——这是 DeepSeek 一路的主来源，不是兜底。
  nonisolated static func linkedSources(in content: String) -> [OwlVerifiedSource] {
    content.matches(of: /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/).map {
      OwlVerifiedSource(title: String($0.1), url: String($0.2))
    }
  }

  /// 按 URL 去重拼接；标题为空时用站点域名顶上，卡片上不留空行。
  ///
  /// DeepSeek 的结构化来源在网址后挂 `#ws_call_id=…`（实测 2026-10-21），同一网页在正文链接里
  /// 却不带——不先剥掉就会同一条出现两次，跳过去的也不是干净网址。
  nonisolated static func mergedSources(
    _ first: [OwlVerifiedSource],
    _ second: [OwlVerifiedSource]
  ) -> [OwlVerifiedSource] {
    var seen = Set<String>()
    return (first + second).compactMap { source in
      var url = source.url
      if let marker = url.range(of: "#ws_call_id=") { url = String(url[..<marker.lowerBound]) }
      guard seen.insert(url).inserted else { return nil }
      let title = source.title.isEmpty ? (URL(string: url)?.host ?? url) : source.title
      return OwlVerifiedSource(title: title, url: url)
    }
  }

  /// 把判断里 `[序号]` 引到的来源按引用顺序提到前面。回执卡拿第一条当「核到的来源」，
  /// 它应当是模型据以判断的那条，而不是搜索排序碰巧第一的那条。
  nonisolated static func citedFirst(
    _ sources: [OwlVerifiedSource],
    in content: String
  ) -> [OwlVerifiedSource] {
    guard !sources.isEmpty else { return sources }
    var cited: [Int] = []
    let pattern = /\[(\d{1,2})\]/
    for match in content.matches(of: pattern) {
      if let number = Int(match.1), (1...sources.count).contains(number), !cited.contains(number - 1) {
        cited.append(number - 1)
      }
    }
    let rest = sources.indices.filter { !cited.contains($0) }
    return (cited + rest).map { sources[$0] }
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
    case .missingSearchKey:
      return OwlSelectionSkillPrompts.missingSourceSearchKeyMessage
    case let .search(searchError):
      switch searchError {
      case .missingAPIKey:
        return OwlSelectionSkillPrompts.missingSourceSearchKeyMessage
      case let .badHTTPStatus(status):
        return "豆包搜索请求失败（\(status)）"
      case let .serviceError(code, _) where code == "700901" || code == "10409":
        return "豆包搜索 Key 无效：需在火山引擎联网搜索控制台创建「按量后付费」Key（\(code)）"
      case let .serviceError(code, _):
        return "豆包搜索返回错误（\(code)）"
      case .malformedResponse:
        return "豆包搜索返回了无法解析的结果"
      }
    case .badHTTPStatus(let status):
      return "来源核验请求失败（\(status)）"
    case .emptyResponse:
      return "未找到可核来源。注意：这不等于事实不存在。"
    }
  }
}
