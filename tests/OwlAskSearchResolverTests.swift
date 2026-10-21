//
//  OwlAskSearchResolverTests.swift
//  OwltypeTests — 任意提问「联网搜索」路由解析（只走 DeepSeek）
//
//  Drives the resolver with FAKE profiles + a FAKE secret store (no Keychain, no store file, no
//  network). Every assertion checks the RESOLVED ROUTE (endpoint / model / key / providerID), not
//  just "did it return something" — a resolver that picks the right provider but routes to the
//  wrong endpoint is exactly the bug a boolean assertion would wave through.
//
//  Covered: toggle off; only DeepSeek profiles are candidates (other providers never search);
//  the active DeepSeek profile goes first; models that can't search are skipped; profiles with no
//  key are skipped; a Keychain throw skips that profile rather than failing the question; nothing
//  usable → nil (caller silently falls back to plain chat).
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class OwlAskSearchResolverTests: XCTestCase {

  // MARK: - Fixtures

  private func profile(
    _ providerID: String,
    id: String? = nil,
    host: String,
    model: String,
    isDefault: Bool = false
  ) -> OwlProviderProfile {
    let id = id ?? providerID
    return OwlProviderProfile(
      id: id,
      displayName: id,
      endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
      model: model,
      providerID: providerID,
      secretName: "owltype.provider.\(id).apiKey",
      isDefault: isDefault
    )
  }

  private func deepseek(
    id: String = "deepseek", model: String = "deepseek-v4-flash", isDefault: Bool = false
  ) -> OwlProviderProfile {
    profile("deepseek", id: id, host: "api.deepseek.com", model: model, isDefault: isDefault)
  }

  private func qwen(isDefault: Bool = false) -> OwlProviderProfile {
    profile("qwen", host: "dashscope.aliyuncs.com", model: "qwen3.6-flash", isDefault: isDefault)
  }

  private func doubao(isDefault: Bool = false) -> OwlProviderProfile {
    profile("doubao", host: "ark.cn-beijing.volces.com", model: "doubao-seed-1.6", isDefault: isDefault)
  }

  private func minimax(isDefault: Bool = false) -> OwlProviderProfile {
    profile("minimax", host: "api.minimax.cn", model: "MiniMax-M3.1-Flash", isDefault: isDefault)
  }

  /// A resolver over fixed profiles. `keys` maps `secretName` → stored key; anything absent reads
  /// as "no key stored". `enabled` drives the toggle without touching UserDefaults, so every test
  /// here is hermetic.
  private func makeResolver(
    enabled: Bool = true,
    profiles: [OwlProviderProfile],
    defaultProfile: OwlProviderProfile? = nil,
    keys: [String: String],
    secretThrows: Set<String> = []
  ) -> OwlAskSearchResolver {
    OwlAskSearchResolver(
      isEnabled: { enabled },
      profilesProvider: { profiles },
      defaultProfileProvider: { defaultProfile ?? profiles.first { $0.isDefault } },
      secretProvider: { name in
        if secretThrows.contains(name) { throw OwlProviderKeychainError.unexpectedStatus(-25300) }
        return keys[name]
      }
    )
  }

  // MARK: - Toggle

  func testToggleOffResolvesToNilEvenWithAConfiguredDeepSeekProfile() {
    let resolver = makeResolver(
      enabled: false,
      profiles: [deepseek(isDefault: true)],
      keys: ["owltype.provider.deepseek.apiKey": "sk-deepseek"]
    )
    XCTAssertNil(resolver.resolve(), "开关关闭时绝不联网，即便配好了 DeepSeek")
  }

  // MARK: - Only DeepSeek searches

  func testDeepSeekRouteCarriesTheDeepSeekResponsesDialect() {
    let resolver = makeResolver(
      profiles: [deepseek(isDefault: true)],
      keys: ["owltype.provider.deepseek.apiKey": "sk-deepseek"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "deepseek")
    XCTAssertEqual(route.routing.endpoint.host, "api.deepseek.com")
    XCTAssertEqual(route.routing.model, OwlSearchControl.searchModel, "官方端点联网作答固定用 flash")
    XCTAssertEqual(route.apiKey, "sk-deepseek")
    XCTAssertEqual(route.transport, .deepSeekSearchAPI)
    XCTAssertEqual(route.displayName, "DeepSeek")
  }

  func testOtherProvidersNeverSearchEvenWithKeys() {
    // 通义千问 / 豆包 / MiniMax 都配好了 Key，也不再承担任意提问的联网。
    let resolver = makeResolver(
      profiles: [qwen(isDefault: true), doubao(), minimax()],
      keys: [
        "owltype.provider.qwen.apiKey": "sk-qwen",
        "owltype.provider.doubao.apiKey": "sk-doubao",
        "owltype.provider.minimax.apiKey": "sk-minimax",
      ]
    )
    XCTAssertTrue(resolver.resolveAll().isEmpty, "只有 DeepSeek 联网")
  }

  func testNonDeepSeekActiveProfileStillSearchesThroughDeepSeek() {
    // 默认供应商是 MiniMax（不能联网）—— 联网与主模型解耦的意义所在：这一问仍交给 DeepSeek 搜。
    let resolver = makeResolver(
      profiles: [minimax(isDefault: true), deepseek()],
      keys: [
        "owltype.provider.minimax.apiKey": "sk-minimax",
        "owltype.provider.deepseek.apiKey": "sk-deepseek",
      ]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "deepseek")
    XCTAssertEqual(route.apiKey, "sk-deepseek")
  }

  func testActiveDeepSeekProfileGoesFirst() {
    let resolver = makeResolver(
      profiles: [deepseek(id: "ds-a"), deepseek(id: "ds-b", isDefault: true)],
      keys: [
        "owltype.provider.ds-a.apiKey": "sk-a",
        "owltype.provider.ds-b.apiKey": "sk-b",
      ]
    )
    XCTAssertEqual(resolver.resolveAll().map(\.apiKey), ["sk-b", "sk-a"], "活动档案在前，其余按存储顺序")
  }

  /// 官方端点上作答型号固定为 searchModel，与档案选的型号无关；Key 照用各自的。
  func testEveryDeepSeekProfileSearchesOnTheSearchModel() {
    let pro = makeResolver(
      profiles: [deepseek(model: "deepseek-v4-pro", isDefault: true)],
      keys: ["owltype.provider.deepseek.apiKey": "sk-deepseek"]
    )
    XCTAssertEqual(pro.resolve()?.routing.model, OwlSearchControl.searchModel)

    let mixed = makeResolver(
      profiles: [
        deepseek(id: "ds-pro", model: "deepseek-v4-pro", isDefault: true),
        deepseek(id: "ds-flash"),
      ],
      keys: [
        "owltype.provider.ds-pro.apiKey": "sk-pro",
        "owltype.provider.ds-flash.apiKey": "sk-flash",
      ]
    )
    XCTAssertEqual(mixed.resolveAll().map(\.apiKey), ["sk-pro", "sk-flash"], "活动档案在前，其余按存储顺序")
    XCTAssertEqual(Set(mixed.resolveAll().map(\.routing.model)), [OwlSearchControl.searchModel])
  }

  func testProxyEndpointKeepsItsOwnModel() {
    // 名字或 host 含 deepseek 的代理不一定提供 deepseek-flash，不能强换型号。
    let proxy = makeResolver(
      profiles: [profile("deepseek", host: "deepseek.proxy.example", model: "deepseek-v4-pro")],
      keys: ["owltype.provider.deepseek.apiKey": "sk-proxy"]
    )
    XCTAssertEqual(proxy.resolve()?.routing.model, "deepseek-v4-pro")
    XCTAssertEqual(proxy.resolve()?.routing.endpoint.host, "deepseek.proxy.example")
  }

  func testCustomProfileResolvesDeepSeekByHost() {
    // A profile whose providerID was never stamped still routes via its host.
    let custom = OwlProviderProfile(
      id: "custom-deepseek",
      displayName: "我的 DeepSeek",
      endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      model: "deepseek-v4-flash",
      secretName: "owltype.provider.custom-deepseek.apiKey",
      isDefault: true
    )
    let resolver = makeResolver(
      profiles: [custom],
      keys: ["owltype.provider.custom-deepseek.apiKey": "sk-custom"]
    )
    guard let route = resolver.resolve() else { return XCTFail("expected a resolved route") }
    XCTAssertEqual(route.providerID, "deepseek", "host 兜底推断出 DeepSeek")
    XCTAssertEqual(route.transport, .deepSeekSearchAPI)
  }

  // MARK: - Key availability

  func testSkipsProfileWithNoOrBlankKey() {
    let resolver = makeResolver(
      profiles: [deepseek(id: "ds-a"), deepseek(id: "ds-b"), deepseek(id: "ds-c")],
      keys: [
        "owltype.provider.ds-b.apiKey": "   ",
        "owltype.provider.ds-c.apiKey": "  sk-c  ",
      ]
    )
    XCTAssertEqual(resolver.resolveAll().map(\.apiKey), ["sk-c"], "无 Key、空白 Key 都不算已配置；Key 去空白")
  }

  func testKeychainFailureSkipsThatProfileInsteadOfFailingTheQuestion() {
    let resolver = makeResolver(
      profiles: [deepseek(id: "ds-a"), deepseek(id: "ds-b")],
      keys: ["owltype.provider.ds-b.apiKey": "sk-b"],
      secretThrows: ["owltype.provider.ds-a.apiKey"]
    )
    XCTAssertEqual(resolver.resolve()?.apiKey, "sk-b", "钥匙串读失败只淘汰这一份，不整问失败")
  }

  // MARK: - Silent fallback

  func testNoDeepSeekProfileResolvesToNil() {
    let resolver = makeResolver(
      profiles: [minimax(isDefault: true)],
      keys: ["owltype.provider.minimax.apiKey": "sk-minimax"]
    )
    XCTAssertNil(resolver.resolve(), "调用方退回普通问答，绝不报错")
  }

  func testNoProfilesAtAllResolvesToNil() {
    XCTAssertNil(makeResolver(profiles: [], keys: [:]).resolve())
  }

  // MARK: - Preference default

  func testWebSearchPreferenceDefaultsToOff() {
    OwlAskWebSearchSettings.resetForTesting()
    XCTAssertFalse(OwlAskWebSearchSettings.isEnabled, "联网搜索必须出厂关闭（opt-in）")
    OwlAskWebSearchSettings.isEnabled = true
    XCTAssertTrue(OwlAskWebSearchSettings.isEnabled)
    OwlAskWebSearchSettings.resetForTesting()
  }
}
