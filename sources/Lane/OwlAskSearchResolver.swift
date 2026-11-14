//
//  OwlAskSearchResolver.swift
//  法墨输入法 (Owltype) — 任意提问「联网搜索」的路由解析
//
//  开关开启时，把这一问路由到一个**已配好密钥的 DeepSeek 档案**：先用它的 Key 调 DeepSeek Search
//  接口取回网页，再依据结果作答，与主对话模型解耦——主模型是别家时也能真搜到。
//
//  没有可用的 DeepSeek 档案 → 返回空，调用方**静默退回**普通问答（`OwlProviderAuthGate` 那条既有路）。
//  这是刻意的降级语义：联网是加分项，不是让提问失败的理由。
//
//  顺序规则（`candidateProfiles`）：当前默认档案是 DeepSeek 时排第一（省得另配一份密钥），其余
//  DeepSeek 档案按存储顺序补齐。官方端点上作答型号一律用 `OwlSearchControl.searchModel`。
//
//  纯值解析：不发请求。唯一副作用是注入的 Keychain 读取，其失败被吞成「这家不可用」而继续
//  下一家（与 `OwlProviderAuthGate` 的「永不因钥匙串崩掉调用方」契约一致）。
//

import Foundation

// MARK: - Preference

/// 任意提问「联网搜索」总开关。默认 **关**（opt-in）：开启后这一问会发给 DeepSeek 的联网搜索工具。
enum OwlAskWebSearchSettings {
  static let key = "OwlAskWebSearchEnabled"

  /// Default false — a user must explicitly opt in before any question reaches a search tool.
  static var isEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: key) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: key) }
  }

}

// MARK: - Resolved route

/// A resolved 联网搜索 route: which provider answers, how to reach it, and the key to use.
/// `providerID` drives the request body (via the route's transport) and the window's 署名 chip, so
/// the user can see WHO answered this question online.
struct OwlAskSearchRoute: Equatable {
  let routing: OwlCloudRouting
  let apiKey: String

  var providerID: String { routing.providerID }
  /// WHICH transport carries this route's search — the 任意提问 module picks its client from this rather
  /// than re-deriving it from the provider id.
  var transport: OwlSearchControl.Transport {
    OwlSearchControl.transport(providerID: providerID, host: routing.endpoint.host ?? "")
  }
}

// MARK: - Resolver

/// Resolves the 联网搜索 route from the toggle + the configured provider profiles. A `struct` of
/// injected closures (same DI idiom as `OwlProviderAuthGate` — one implementation, test fakes via
/// the closures). Deterministic given its inputs; no network.
@MainActor
struct OwlAskSearchResolver {
  /// The 联网搜索 toggle. Default = the live preference.
  var isEnabled: () -> Bool
  /// All configured provider profiles, in the store's stable order. Default = the live store.
  var profilesProvider: () -> [OwlProviderProfile]
  /// The active (default) profile — tried first when it is itself a DeepSeek profile.
  var defaultProfileProvider: () -> OwlProviderProfile?
  /// Reads a profile's API key by `secretName`. Default = the live Keychain.
  var secretProvider: (String) throws -> String?

  init(
    isEnabled: @escaping () -> Bool = { OwlAskWebSearchSettings.isEnabled },
    profilesProvider: @escaping () -> [OwlProviderProfile] = { OwlProviderProfileStore.shared.profiles() },
    defaultProfileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    secretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) }
  ) {
    self.isEnabled = isEnabled
    self.profilesProvider = profilesProvider
    self.defaultProfileProvider = defaultProfileProvider
    self.secretProvider = secretProvider
  }

  /// EVERY usable 联网搜索 route, in `candidateProfiles()` order — the input to the runtime
  /// failover in `OwlAskAnythingModule`.
  ///
  /// 为什么要**列表**而不是单个路由：配置期「有没有 Key」与运行期「这把 Key 肯不肯服务」是两回事 ——
  /// Key 失效是 401、欠费是 402，都只在请求发出后才知道。交出全部候选，调用方在首个 delta 之前
  /// 顺位，全败才退回普通问答。
  func resolveAll() -> [OwlAskSearchRoute] {
    guard isEnabled() else { return [] }
    return candidateProfiles().compactMap { profile in
      guard let apiKey = usableKey(for: profile) else { return nil }
      let base = OwlCloudRouting.resolve(profile: profile)
      // 官方端点用固定的作答型号；代理端点不一定提供它，保留档案型号。
      let model: String = OwlAIBusinessCore.call("searchModel", ["host": base.endpoint.host ?? "", "model": base.model])
      let route = OwlAskSearchRoute(
        routing: OwlCloudRouting(
          providerID: base.providerID,
          endpoint: base.endpoint,
          model: model,
          secretName: base.secretName,
          authHeaderStyle: base.authHeaderStyle),
        apiKey: apiKey)
      guard route.transport != .none else { return nil }
      return route
    }
  }

  /// DeepSeek profiles in the order they are tried: the active profile first when it is one,
  /// then the rest in the store's stable order.
  private func candidateProfiles() -> [OwlProviderProfile] {
    let profiles = profilesProvider()
    let ids: [String] = OwlAIBusinessCore.call("searchCandidates", [
      "profiles": profiles.map { ["id": $0.id, "providerID": OwlLLMProviderCatalog.inferredProviderID(for: $0)] },
      "activeID": defaultProfileProvider()?.id as Any? ?? NSNull()])
    return ids.compactMap { id in profiles.first { $0.id == id } }
  }

  /// A non-empty stored key for `profile`, or nil. A profile with no `secretName` (never happens for
  /// a stored profile, defensive) and a Keychain read failure both mean "not usable" — skip to the
  /// next candidate rather than failing the whole question.
  private func usableKey(for profile: OwlProviderProfile) -> String? {
    // `try?` flattens both failure modes into nil: a Keychain throw and a genuinely absent key.
    guard let raw = try? secretProvider(profile.secretName) else { return nil }
    let key: String = OwlAIBusinessCore.call("trim", ["text": raw])
    return key.isEmpty ? nil : key
  }
}

// MARK: - 运行期顺位降级策略

/// 一次联网尝试失败后，该顺位到下一家、还是如实报错给用户。
///
/// 判据是「这家在当前配置下**拒绝服务**」还是「无法确认能否安全换家」：
///   - 顺位：明确的鉴权/套餐配置状态。Key 失效是 401、欠费/未授权是 402/403、端点不存在是 404。
///   - 报错：其余状态、未知业务码、5xx 与 `URLError`。未知即顺位会把同一问题额外发送给其他供应商，
///     所以这里采取封闭列表；只有可以确认是配置拒绝的错误才允许在首个 delta 前换家。
enum OwlAskSearchFailover {
  static func facts(_ error: Error) -> [String: Any] {
    var status = 0
    var invalidEndpoint = false
    if let streaming = error as? OwlStreamingError {
      switch streaming {
      case let .badHTTPStatus(value, _): status = value
      case .invalidEndpoint: invalidEndpoint = true
      default: break
      }
    }
    return ["status": status, "invalidEndpoint": invalidEndpoint]
  }
}
