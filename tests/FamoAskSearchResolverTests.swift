//
//  FamoAskSearchResolverTests.swift
//  FamoTests — 任意提问「联网搜索」专属模型解析
//
//  Drives the resolver with FAKE profiles + a FAKE secret store (no Keychain, no store file, no
//  network). Every assertion checks the RESOLVED ROUTE (endpoint / model / key / providerID), not
//  just "did it return something" — a resolver that picks the right provider but routes to the
//  wrong endpoint is exactly the bug a boolean assertion would wave through.
//
//  Covered: toggle off; 自动 prefers the active profile when it can already search; priority order
//  otherwise; profiles with no key are skipped; a Keychain throw skips that provider rather than
//  failing the question; nothing configured → nil (caller silently falls back to plain chat).
//

import Foundation
import XCTest
@testable import Famo

@MainActor
final class FamoAskSearchResolverTests: XCTestCase {

  // MARK: - Fixtures

  private func profile(
    _ providerID: String,
    host: String,
    model: String,
    isDefault: Bool = false
  ) -> FamoProviderProfile {
    FamoProviderProfile(
      id: providerID,
      displayName: providerID,
      endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
      model: model,
      providerID: providerID,
      secretName: "famo.provider.\(providerID).apiKey",
      isDefault: isDefault
    )
  }

  private func qwen(isDefault: Bool = false) -> FamoProviderProfile {
    profile("qwen", host: "dashscope.aliyuncs.com", model: "qwen3.6-flash", isDefault: isDefault)
  }

  private func mimo(isDefault: Bool = false) -> FamoProviderProfile {
    profile("mimo", host: "api.xiaomimimo.com", model: "mimo-v2.5", isDefault: isDefault)
  }

  private func deepseek(isDefault: Bool = true) -> FamoProviderProfile {
    profile("deepseek", host: "api.deepseek.com", model: "deepseek-v4-flash", isDefault: isDefault)
  }

  private func doubao(isDefault: Bool = false) -> FamoProviderProfile {
    profile("doubao", host: "ark.cn-beijing.volces.com", model: "doubao-seed-1.6", isDefault: isDefault)
  }

  private func openai(isDefault: Bool = false) -> FamoProviderProfile {
    profile("openai", host: "api.openai.com", model: "gpt-5.1", isDefault: isDefault)
  }

  /// A resolver over fixed profiles. `keys` maps `secretName` → stored key; anything absent reads
  /// as "no key stored". `enabled` / `preferred` drive the toggle and the「联网模型」choice without
  /// touching UserDefaults, so every test here is hermetic.
  private func makeResolver(
    enabled: Bool = true,
    profiles: [FamoProviderProfile],
    defaultProfile: FamoProviderProfile? = nil,
    preferred: String? = nil,
    keys: [String: String],
    secretThrows: Set<String> = []
  ) -> FamoAskSearchResolver {
    FamoAskSearchResolver(
      isEnabled: { enabled },
      profilesProvider: { profiles },
      defaultProfileProvider: { defaultProfile ?? profiles.first { $0.isDefault } },
      preferredProviderID: { preferred },
      secretProvider: { name in
        if secretThrows.contains(name) { throw FamoProviderKeychainError.unexpectedStatus(-25300) }
        return keys[name]
      }
    )
  }

  // MARK: - Toggle

  func testToggleOffResolvesToNilEvenWithAConfiguredSearchProvider() {
    let resolver = makeResolver(
      enabled: false,
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    XCTAssertNil(resolver.resolve(), "开关关闭时绝不联网，即便配好了可联网供应商")
  }

  // MARK: - 自动 preference

  func testActiveSearchCapableProfileWinsOverThePriorityOrder() {
    // MiMo is the active profile and can already search → use it, even though Qwen (higher in the
    // default order) also has a key. Saves the user configuring a second provider.
    let resolver = makeResolver(
      profiles: [qwen(), mimo(isDefault: true)],
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "mimo")
    XCTAssertEqual(route.routing.model, "mimo-v2.5")
    XCTAssertEqual(route.routing.endpoint.host, "api.xiaomimimo.com")
    XCTAssertEqual(route.apiKey, "sk-mimo")
  }

  func testNonSearchActiveProfileFallsToThePriorityOrder() {
    // The active profile is DeepSeek (cannot search) — the whole reason for decoupling. The
    // question must still route to a search-capable provider instead of silently not searching.
    let resolver = makeResolver(
      profiles: [deepseek(), doubao(), mimo()],
      keys: [
        "famo.provider.deepseek.apiKey": "sk-deepseek",
        "famo.provider.doubao.apiKey": "sk-doubao",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "mimo", "qwen 未配置 → 顺位到 mimo")
    XCTAssertEqual(route.routing.endpoint.host, "api.xiaomimimo.com")
    XCTAssertEqual(route.apiKey, "sk-mimo")
  }

  func testPriorityOrderPrefersQwenWhenNothingIsActive() {
    let resolver = makeResolver(
      profiles: [mimo(), doubao(), qwen()],
      defaultProfile: nil,
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.doubao.apiKey": "sk-doubao",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "qwen", "无活动档案时按 searchProviderIDs 顺序")
    XCTAssertEqual(route.apiKey, "sk-qwen")
  }

  // MARK: - 「联网模型」偏好（Picker）

  func testPreferredProviderWinsOverBothTheActiveProfileAndThePriorityOrder() {
    // 用户显式选了 MiMo：既压过 searchProviderIDs 的默认顺序（qwen 在前），也压过「活动档案可联网
    // 就优先」的自动规则（豆包 是默认档案）。
    let resolver = makeResolver(
      profiles: [qwen(), doubao(isDefault: true), mimo()],
      preferred: "mimo",
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.doubao.apiKey": "sk-doubao",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "mimo")
    XCTAssertEqual(route.apiKey, "sk-mimo")
  }

  func testPreferredProviderWithoutAKeyFallsThroughToTheNextCandidate() {
    // 拍板的产品语义：偏好只影响顺序，不影响「没密钥就跳过」。选了豆包但没填豆包 Key →
    // 仍然联网（顺位到已配好的那家），而不是让这一问退回不联网。
    let resolver = makeResolver(
      profiles: [qwen(), doubao()],
      preferred: "doubao",
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "qwen", "选中的那家没 Key → 顺位，不是放弃联网")
    XCTAssertEqual(route.apiKey, "sk-qwen")
  }

  func testPreferredProviderIsIgnoredWhenTheToggleIsOff() {
    let resolver = makeResolver(
      enabled: false,
      profiles: [qwen()],
      preferred: "qwen",
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    XCTAssertNil(resolver.resolve(), "总开关关闭时，选了谁都不联网")
  }

  func testProviderPreferenceDefaultsToAutoAndRejectsUnknownValues() {
    FamoAskSearchProviderSettings.resetForTesting()
    XCTAssertEqual(FamoAskSearchProviderSettings.rawValue, "")
    XCTAssertNil(FamoAskSearchProviderSettings.preferredProviderID, "出厂＝自动")

    FamoAskSearchProviderSettings.rawValue = "mimo"
    XCTAssertEqual(FamoAskSearchProviderSettings.preferredProviderID, "mimo")

    // A provider that can't search (or a stale id from an older build — 豆包方舟 was a candidate
    // before it moved to the standalone 豆包搜索 API) reads as 自动 rather than pinning the order
    // to a dead entry.
    FamoAskSearchProviderSettings.rawValue = "deepseek"
    XCTAssertNil(FamoAskSearchProviderSettings.preferredProviderID)
    FamoAskSearchProviderSettings.rawValue = "doubao"
    XCTAssertNil(FamoAskSearchProviderSettings.preferredProviderID, "旧版存下的方舟选择读成自动")
    FamoAskSearchProviderSettings.resetForTesting()
  }

  // MARK: - `/responses` providers (OpenAI) 与退役的方舟

  func testArkProfileNoLongerResolvesAsAnAskSearchRoute() {
    // 方舟的 web_search 要单独开通内容插件，没开通时 404 ToolNotOpen —— 与其让每一问都先撞一次墙，
    // 不如不把它列为候选；豆包这条线由独立的「豆包搜索」检索 API 承担。
    let resolver = makeResolver(
      profiles: [doubao(isDefault: true)],
      keys: ["famo.provider.doubao.apiKey": "sk-doubao"]
    )
    XCTAssertNil(resolver.resolve(), "方舟档案配了 Key 也不再作为任意提问的联网候选")
  }

  // MARK: - 联网搜索专用 Key

  func testDoubaoSearchCredentialResolvesToTheRetrievalTransport() {
    let resolver = makeResolver(
      profiles: [deepseek()],
      keys: [
        "famo.provider.deepseek.apiKey": "sk-deepseek",
        FamoSearchCredential.doubaoSearch.secretName: "sk-doubao-search",
      ]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "doubao_search")
    XCTAssertEqual(route.transport, .retrieval, "豆包搜索只检索，答案仍由主模型写")
    XCTAssertEqual(route.routing.endpoint.host, "open.feedcoopapi.com")
    XCTAssertEqual(route.apiKey, "sk-doubao-search", "用的是专用 Key，不是方舟模型 Key")
    XCTAssertEqual(route.displayName, "豆包搜索")
  }

  func testPerplexityCredentialResolvesToChatCompletionsWithNoExtras() {
    let resolver = makeResolver(
      profiles: [deepseek()],
      keys: [FamoSearchCredential.perplexity.secretName: "pplx-key"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "perplexity")
    XCTAssertEqual(route.transport, .chatCompletions)
    XCTAssertEqual(route.routing.endpoint.host, "api.perplexity.ai")
    XCTAssertTrue(route.extraBody.isEmpty, "Perplexity 默认就联网，多加字段反而可能被拒")
    XCTAssertEqual(route.apiKey, "pplx-key")
  }

  func testDedicatedSearchKeyOutranksASearchCapableActiveProfile() {
    // 「活动档案能联网就优先」是为了省一份密钥；用户既然专门为联网填了 Key，那就是更明确的意图。
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true)],
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        FamoSearchCredential.doubaoSearch.secretName: "sk-doubao-search",
      ]
    )
    XCTAssertEqual(resolver.resolve()?.providerID, "doubao_search")
  }

  func testCredentialsWithoutKeysDoNotBlockTheChatProviders() {
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    XCTAssertEqual(
      resolver.resolve()?.providerID, "qwen",
      "专用 Key 没填时只是空位，不该把联网整个挡住")
  }

  // MARK: - resolveAll（运行期顺位的输入）

  func testResolveAllReturnsEveryConfiguredCandidateInOrder() {
    let resolver = makeResolver(
      profiles: [qwen(), mimo(), openai(), deepseek(isDefault: true)],
      keys: [
        FamoSearchCredential.perplexity.secretName: "pplx-key",
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.mimo.apiKey": "sk-mimo",
        "famo.provider.openai.apiKey": "sk-openai",
        "famo.provider.deepseek.apiKey": "sk-deepseek",
      ]
    )
    XCTAssertEqual(
      resolver.resolveAll().map(\.providerID), ["perplexity", "qwen", "mimo", "openai"],
      "顺位降级要拿到全部候选；不能搜的 deepseek 不在其中")
    XCTAssertEqual(resolver.resolve()?.providerID, "perplexity", "resolve() 就是第一名")
  }

  func testResolveAllSkipsCandidatesWithoutKeysAndHonoursThePreference() {
    let resolver = makeResolver(
      profiles: [qwen(), mimo(), openai()],
      preferred: "mimo",
      keys: [
        "famo.provider.mimo.apiKey": "sk-mimo",
        "famo.provider.openai.apiKey": "sk-openai",
      ]
    )
    XCTAssertEqual(
      resolver.resolveAll().map(\.providerID), ["mimo", "openai"],
      "选中的排第一，没配密钥的 qwen 直接不在候选里")
  }

  func testResolveAllIsEmptyWhenTheToggleIsOff() {
    let resolver = makeResolver(
      enabled: false,
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    XCTAssertTrue(resolver.resolveAll().isEmpty)
  }

  // MARK: - 顺位判据（4xx 换家 / 真错误上报）

  func testConfigurationRefusalsTriggerFailover() {
    // 方舟未开通插件 404 ToolNotOpen、MiMo 密钥失效 401 —— 这两条就是 2026-07-27 实机撞到的。
    for status in [400, 401, 402, 403, 404, 422] {
      XCTAssertTrue(
        FamoAskSearchFailover.shouldTryNextProvider(after: FamoStreamingError.badHTTPStatus(status)),
        "HTTP \(status) 换同一家重试永远是同样结果，必须顺位")
    }
    XCTAssertTrue(
      FamoAskSearchFailover.shouldTryNextProvider(after: FamoStreamingError.invalidEndpoint))
  }

  func testTransientAndRealFailuresAreReportedInsteadOfSwallowed() {
    for status in [408, 429, 500, 502, 503] {
      XCTAssertFalse(
        FamoAskSearchFailover.shouldTryNextProvider(after: FamoStreamingError.badHTTPStatus(status)),
        "HTTP \(status) 是暂时/对方故障，顺位只会把一个错误变成好几个")
    }
    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextProvider(after: URLError(.notConnectedToInternet)),
      "用户断网必须如实报错，不能伪装成「换一家」")
    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextProvider(after: URLError(.timedOut)),
      "超时同上")
    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextProvider(after: FamoStreamingError.upstreamFailure("x")),
      "2xx 之后模型自己中断，换一家不会更好")
  }

  func testOpenAIRouteCarriesTheOpenAIResponsesDialect() {
    let resolver = makeResolver(
      profiles: [openai(isDefault: true)],
      keys: ["famo.provider.openai.apiKey": "sk-openai"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.transport, .responses(isOpenAI: true))
    XCTAssertEqual(route.displayName, "OpenAI")
  }

  func testChatCompletionsRouteStillCarriesTheChatTransport() {
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    XCTAssertEqual(resolver.resolve()?.transport, .chatCompletions)
  }

  func testResponsesProvidersSitBehindTheChatOnesInTheAutoOrder() {
    // 自动顺序：`/chat/completions` 那几家（实机验证过）在前，`/responses` 的 OpenAI 在后；
    // 方舟档案（doubao）已不是候选，配了 Key 也不参与排序。
    let resolver = makeResolver(
      profiles: [doubao(), openai(), mimo()],
      defaultProfile: nil,
      keys: [
        "famo.provider.doubao.apiKey": "sk-doubao",
        "famo.provider.openai.apiKey": "sk-openai",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )
    XCTAssertEqual(resolver.resolve()?.providerID, "mimo")
  }

  // MARK: - Key availability

  func testSkipsSearchCapableProfileWithNoStoredKey() {
    // Qwen is configured as a profile but has no key yet → fall through to the next candidate.
    let resolver = makeResolver(
      profiles: [qwen(), mimo()],
      keys: ["famo.provider.mimo.apiKey": "sk-mimo"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "mimo")
    XCTAssertEqual(route.apiKey, "sk-mimo")
  }

  func testSkipsProfileWhoseStoredKeyIsBlank() {
    let resolver = makeResolver(
      profiles: [qwen(), mimo()],
      keys: [
        "famo.provider.qwen.apiKey": "   ",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )
    XCTAssertEqual(resolver.resolve()?.providerID, "mimo", "空白 key 不算已配置")
  }

  func testKeychainFailureSkipsThatProviderInsteadOfFailingTheQuestion() {
    let resolver = makeResolver(
      profiles: [qwen(), mimo()],
      keys: ["famo.provider.mimo.apiKey": "sk-mimo"],
      secretThrows: ["famo.provider.qwen.apiKey"]
    )
    XCTAssertEqual(resolver.resolve()?.providerID, "mimo", "钥匙串读失败只淘汰这一家，不整问失败")
  }

  // MARK: - Silent fallback

  func testNoSearchCapableProfileResolvesToNil() {
    // Only DeepSeek configured → nil, and the CALLER falls back to plain chat (never an error).
    let resolver = makeResolver(
      profiles: [deepseek()],
      keys: ["famo.provider.deepseek.apiKey": "sk-deepseek"]
    )
    XCTAssertNil(resolver.resolve())
  }

  func testSearchCapableProfilesWithoutAnyKeyResolveToNil() {
    let resolver = makeResolver(profiles: [qwen(), mimo()], keys: [:])
    XCTAssertNil(resolver.resolve(), "配了档案但一把钥匙都没有 → 退回普通问答")
  }

  func testNoProfilesAtAllResolvesToNil() {
    XCTAssertNil(makeResolver(profiles: [], keys: [:]).resolve())
  }

  // MARK: - Route → request fields

  func testResolvedRouteCarriesItsProvidersSearchFields() {
    // The route's extraBody is what actually reaches the wire; assert it is the provider's real
    // search payload rather than an empty dict (which would mean "searched" without searching).
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.extraBody["enable_search"] as? Bool, true)
    XCTAssertEqual(route.displayName, "通义千问")
  }

  func testCustomProfileResolvesSearchFieldsByHost() {
    // A profile whose providerID was never stamped still gets the right wire format via its host.
    let custom = FamoProviderProfile(
      id: "custom-mimo",
      displayName: "我的 MiMo",
      endpoint: URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!,
      model: "mimo-v2.5",
      secretName: "famo.provider.custom-mimo.apiKey",
      isDefault: true
    )
    let resolver = makeResolver(
      profiles: [custom],
      keys: ["famo.provider.custom-mimo.apiKey": "sk-custom"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "mimo", "host 兜底推断出 MiMo")
    XCTAssertEqual(route.extraBody["tool_choice"] as? String, "auto")
  }

  // MARK: - Preference default

  func testWebSearchPreferenceDefaultsToOff() {
    FamoAskWebSearchSettings.resetForTesting()
    XCTAssertFalse(FamoAskWebSearchSettings.isEnabled, "联网搜索必须出厂关闭（opt-in）")
    FamoAskWebSearchSettings.isEnabled = true
    XCTAssertTrue(FamoAskWebSearchSettings.isEnabled)
    FamoAskWebSearchSettings.resetForTesting()
  }
}
