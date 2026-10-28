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
    let capabilities = OwlProviderCapabilities(providerID: providerID, model: model)
    let thinkingOff = capabilities.thinkingOff
    return OwlDeepSeekChatRequest(
      model: model,
      messages: messages,
      temperature: capabilities.temperature(variant.temperature),
      stream: false,
      responseFormat: capabilities.sendsChatJSONMode ? .jsonObject : nil,
      thinking: thinkingOff.thinking,
      enableThinking: thinkingOff.enableThinking,
      reasoningEffort: thinkingOff.reasoningEffort,
      reasoningSplit: thinkingOff.reasoningSplit
    )
  }
}

/// Selection-polish request through the LLM gateway: the active variant's prompt, JSON-mode
/// candidates, and `OwlNumberedRewriteParser`. The payload is the user's selected text (see the
/// privacy header above).
struct OwlSelectionPolishClient {
  let routing: OwlCloudRouting
  let gateway: OwlLLMGateway

  init(routing: OwlCloudRouting, gateway: OwlLLMGateway = OwlLLMGateway()) {
    self.routing = routing
    self.gateway = gateway
  }

  func fetchPolishedRewrites(for selection: String, apiKey: String) async throws -> [String] {
    let variant = OwlPolishPromptCatalog.resolveActive()
    // 请求侧观测（issue #136）：沿现有 trace 开关体系只落 variant id + model，绝不落选中文本。
    OwlLiveInputTrace.write { "selection-polish variant=\(variant.id) model=\(routing.model)" }
    let payload = try OwlSelectionPolish.chatRequest(
      for: selection, model: routing.model, providerID: routing.providerID, variant: variant)
    let text = try await gateway.complete(
      payload, routing: routing, apiKey: apiKey, purpose: .interactiveRewrite)
    return OwlNumberedRewriteParser.parse(text)
  }
}

/// B4 service: applies the privacy guards, then fetches rewrites through the LLM gateway, which owns
/// the bounded retry. Returns rewrites (best-first) or throws a `OwlSelectionPolishError` the
/// controller can surface. No `OwlCandidateStore`, no lane, no broker — this is a clipboard text op.
@MainActor
final class OwlSelectionPolishService {
  static let shared = OwlSelectionPolishService()

  /// Tests inject a gateway over a recording transport; production uses URLSession.
  private let gateway: OwlLLMGateway
  /// Resolves the active profile → routing + key. Built from the injected profile/secret/legacy
  /// (`apiKeyProvider`) closures so tests keep injecting exactly as before. Polish keeps the legacy
  /// DeepSeek fallback (used when NO provider profile is active).
  private let gate: OwlProviderAuthGate

  init(
    gateway: OwlLLMGateway = OwlLLMGateway(),
    apiKeyProvider: @escaping () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
    profileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) }
  ) {
    self.gateway = gateway
    self.gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: apiKeyProvider
    )
  }

  /// Polish the selected text. Guards run BEFORE any keychain / network touch:
  ///   1. isEnabled (default-off cloud gate);
  ///   2. length / emptiness policy (`OwlSelectionPolish.rejectionReason`).
  /// Only then is the active provider routed, its key read, and the gateway call issued.
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

    return try await OwlSelectionPolishClient(routing: routing, gateway: gateway)
      .fetchPolishedRewrites(for: selection, apiKey: apiKey)
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

/// 来源核验：豆包搜索与 DeepSeek 搜索，配了哪个用哪个，都配了就并行一起搜。
///
///   - 检索：豆包搜索（单独的 Key）与 DeepSeek Search 接口（DeepSeek 档案的 Key，与任意提问联网
///     同一套解析）各取一份，按网址去重合并、统一编号。
///   - 判断：有 DeepSeek 档案时由 `deepseek-flash` 对照编号结果判断；它被拒（Key 失效 / 欠费）或
///     没有 DeepSeek 档案时交给默认供应商；都没有时只回来源列表，由用户复核。
///
/// 来源只来自搜索结果本身（标题 + URL），不让模型凭空补来源。
@MainActor
final class OwlSourceVerificationService {
  static let shared = OwlSourceVerificationService()

  /// 每一路检索取回的网页数。两路合并去重后最多 `2 × resultCount` 条。
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

  nonisolated static func userPrompt(
    for selectedText: String,
    results: [OwlWebSearchResult]
  ) -> String {
    """
    请核验以下选中文本，给出判断、支持判断的来源序号和关键信息。

    选中文本：
    \(selectedText)

    检索结果：
    \(OwlWebSearchGrounding.numbered(results))
    """
  }

  private let searchClient: OwlDoubaoSearching
  private let searchKeyProvider: () -> String?
  private let deepSeekSearchClient: OwlDeepSeekSearching
  private let deepSeekRoutesProvider: @MainActor () -> [OwlAskSearchRoute]
  private let gate: OwlProviderAuthGate
  private let transport: OwlAskAnythingTransporting

  /// 能用 DeepSeek 搜索核验的档案，顺序同任意提问联网。不看任意提问的联网开关：
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
    deepSeekSearchClient: OwlDeepSeekSearching = OwlDeepSeekSearchClient(),
    deepSeekRoutesProvider: @escaping @MainActor () -> [OwlAskSearchRoute] = {
      @MainActor in OwlSourceVerificationService.deepSeekSearchRoutes()
    },
    profileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    profileSecretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) },
    legacyKeyProvider: @escaping () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
    transport: OwlAskAnythingTransporting? = nil
  ) {
    self.searchClient = searchClient
    self.searchKeyProvider = searchKeyProvider
    self.deepSeekSearchClient = deepSeekSearchClient
    self.deepSeekRoutesProvider = deepSeekRoutesProvider
    self.gate = OwlProviderAuthGate(
      profileProvider: profileProvider,
      profileSecretProvider: profileSecretProvider,
      legacyKeyProvider: legacyKeyProvider
    )
    self.transport = transport ?? OwlAskAnythingTransportAdapter(
      chatClient: OwlStreamingChatClient(),
      responsesClient: OwlResponsesStreamingClient(),
      searchClient: deepSeekSearchClient)
  }

  func verifyStructured(_ selectedText: String) async throws -> OwlSourceVerificationOutcome {
    guard OwlCloudPreferences.isEnabled else { throw OwlSourceVerificationError.disabled }
    if OwlSelectionPolish.rejectionReason(for: selectedText) != nil {
      throw OwlSourceVerificationError.emptySelection
    }
    let searchKey = searchKeyProvider()
    let routes = deepSeekRoutesProvider()
    guard searchKey != nil || !routes.isEmpty else {
      throw OwlSourceVerificationError.missingSearchKey
    }

    async let doubao = Self.doubaoSearch(
      selectedText, apiKey: searchKey, client: searchClient)
    async let deepSeek = Self.deepSeekSearch(
      selectedText, routes: routes, client: deepSeekSearchClient)
    let (doubaoOutcome, deepSeekOutcome) = await (doubao, deepSeek)

    let results = Self.merged(deepSeekOutcome.results, doubaoOutcome.results)
    guard !results.isEmpty else {
      // 两路都没有结果：只配了豆包且它报错时如实说豆包；DeepSeek 被拒时带上状态码。
      if routes.isEmpty, let error = doubaoOutcome.error { throw OwlSourceVerificationError.search(error) }
      if let status = deepSeekOutcome.failedStatus { throw OwlSourceVerificationError.badHTTPStatus(status) }
      throw OwlSourceVerificationError.emptyResponse
    }
    let sources = results.map { OwlVerifiedSource(title: $0.title, url: $0.url) }
    let messages = [
      OwlDeepSeekMessage(role: "system", content: Self.systemPrompt),
      OwlDeepSeekMessage(
        role: "user", content: Self.userPrompt(for: selectedText, results: results)),
    ]

    // 判断：搜索接口认过这把 Key 的 DeepSeek 档案优先，被配置拒绝时退回默认供应商。
    if let route = deepSeekOutcome.route {
      do {
        return try await judge(
          messages, routing: route.routing, apiKey: route.apiKey, sources: sources)
      } catch OwlSourceVerificationError.badHTTPStatus(let status)
        where OwlAskSearchFailover.isConfigurationRefusal(status: status) {}
    }
    guard case let .ready(routing, apiKey) = gate.resolve() else {
      // 没配作答模型：来源仍然可跳查，判断留给用户（卡片会提示人工复核）。
      return OwlSourceVerificationOutcome(content: "", sources: sources)
    }
    return try await judge(messages, routing: routing, apiKey: apiKey, sources: sources)
  }

  private func judge(
    _ messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String,
    sources: [OwlVerifiedSource]
  ) async throws -> OwlSourceVerificationOutcome {
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

  private struct DoubaoOutcome {
    var results: [OwlWebSearchResult] = []
    var error: OwlDoubaoSearchError?
  }

  nonisolated private static func doubaoSearch(
    _ text: String, apiKey: String?, client: OwlDoubaoSearching
  ) async -> DoubaoOutcome {
    guard let apiKey else { return DoubaoOutcome() }
    do {
      return DoubaoOutcome(results: try await client.search(
        query: text, apiKey: apiKey, limit: resultCount))
    } catch let error as OwlDoubaoSearchError {
      return DoubaoOutcome(error: error)
    } catch {
      return DoubaoOutcome(error: .malformedResponse)
    }
  }

  private struct DeepSeekOutcome {
    var results: [OwlWebSearchResult] = []
    /// 搜索请求成功的档案：它的 Key 已被 DeepSeek 认过，判断也交给它。
    var route: OwlAskSearchRoute?
    var failedStatus: Int?
  }

  /// 档案逐个试，只在配置拒绝（401/402/403/404）时换下一个——与任意提问联网同一判据。
  nonisolated private static func deepSeekSearch(
    _ text: String, routes: [OwlAskSearchRoute], client: OwlDeepSeekSearching
  ) async -> DeepSeekOutcome {
    var outcome = DeepSeekOutcome()
    for route in routes {
      guard let endpoint = OwlDeepSeekSearchWire.endpoint(for: route.routing.endpoint) else { continue }
      do {
        outcome.results = try await client.search(
          query: text, endpoint: endpoint, apiKey: route.apiKey, limit: resultCount)
        outcome.route = route
        outcome.failedStatus = nil
        return outcome
      } catch OwlDeepSeekSearchError.badHTTPStatus(let status) {
        outcome.failedStatus = status
        guard OwlAskSearchFailover.isConfigurationRefusal(status: status) else { return outcome }
      } catch {
        return outcome
      }
    }
    return outcome
  }

  /// 按网址去重拼接，先到先得。
  nonisolated static func merged(
    _ first: [OwlWebSearchResult], _ second: [OwlWebSearchResult]
  ) -> [OwlWebSearchResult] {
    var seen = Set<String>()
    return (first + second).filter { seen.insert($0.url).inserted }
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
