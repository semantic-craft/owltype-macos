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

    FamoAskSearchProviderSettings.rawValue = "doubao"
    XCTAssertEqual(FamoAskSearchProviderSettings.preferredProviderID, "doubao")

    // A provider that can't search (or a stale id from an older build) reads as 自动 rather than
    // pinning the order to a dead entry.
    FamoAskSearchProviderSettings.rawValue = "deepseek"
    XCTAssertNil(FamoAskSearchProviderSettings.preferredProviderID)
    FamoAskSearchProviderSettings.resetForTesting()
  }

  // MARK: - `/responses` providers (Qwen / 豆包 / OpenAI)

  func testDoubaoRouteCarriesTheResponsesTransportAndNoChatExtras() {
    let resolver = makeResolver(
      profiles: [doubao(isDefault: true)],
      keys: ["famo.provider.doubao.apiKey": "sk-doubao"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "doubao")
    XCTAssertEqual(route.transport, .responses(.ark), "豆包 必须走 /responses")
    XCTAssertTrue(route.extraBody.isEmpty, "它的搜索参数不在 chat/completions 顶层字段里")
    XCTAssertEqual(route.displayName, "豆包")
    XCTAssertEqual(route.apiKey, "sk-doubao")
  }

  func testOpenAIRouteCarriesTheOpenAIResponsesDialect() {
    let resolver = makeResolver(
      profiles: [openai(isDefault: true)],
      keys: ["famo.provider.openai.apiKey": "sk-openai"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.transport, .responses(.openAI))
    XCTAssertEqual(route.displayName, "OpenAI")
  }

  func testQwenRouteCarriesTheQwenResponsesDialect() {
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    XCTAssertEqual(resolver.resolve()?.transport, .responses(.qwen))
  }

  func testResponsesProvidersSitBehindTheChatOnesInTheAutoOrder() {
    // 自动顺序：一期两家（实机验证过）在前，二期两家在后。
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
    // Qwen's route carries its Responses dialect; chat extras must stay empty.
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true)],
      keys: ["famo.provider.qwen.apiKey": "sk-qwen"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.transport, .responses(.qwen))
    XCTAssertTrue(route.extraBody.isEmpty)
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
