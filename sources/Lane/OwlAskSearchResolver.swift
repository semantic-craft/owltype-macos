//
//  OwlAskSearchResolver.swift
//  猫头鹰输入法 (Owltype) — 任意提问「联网搜索」的路由解析
//
//  开关开启时，把这一问路由到一个**已配好密钥、能联网的 DeepSeek 档案**，与主对话模型解耦 ——
//  主模型是别家（或 DeepSeek Pro 这种不能联网的型号）时也能真搜到。若只在主模型请求里拼搜索参数，
//  不支持联网的主模型会被静默降级成普通问答、只答到训练截止，而用户以为搜了。
//
//  没有可用的 DeepSeek 档案 → 返回空，调用方**静默退回**普通问答（`OwlProviderAuthGate` 那条既有路）。
//  这是刻意的降级语义：联网是加分项，不是让提问失败的理由。
//
//  顺序规则（`candidateProfiles`）：当前默认档案是 DeepSeek 时排第一（省得另配一份密钥），其余
//  DeepSeek 档案按存储顺序补齐。联网一律改用 `OwlSearchControl.searchModel`，档案选的作答型号
//  只管普通问答——能搜的型号与日常作答的型号不是同一个。
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

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: key)
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
  /// 面向用户的品牌名（DeepSeek），供 AI 窗署名 chip 使用。
  var displayName: String? { OwlSearchControl.displayName(for: providerID) }
  /// WHICH transport carries this route's search — the 任意提问 module picks its client from this rather
  /// than re-deriving it from the provider id.
  var transport: OwlSearchControl.Transport {
    // 带上型号：只有 `OwlSearchControl.searchModel` 真会执行搜索。
    OwlSearchControl.transport(
      providerID: providerID, host: routing.endpoint.host ?? "", model: routing.model)
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

  /// The 联网搜索 route for this question, or nil → caller falls back to plain chat.
  /// nil covers all three "no search this time" cases: toggle off, no search-capable DeepSeek
  /// profile, or every such profile still missing its key.
  func resolve() -> OwlAskSearchRoute? {
    resolveAll().first
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
      // 换成能搜的型号：档案选的 flash 收下 web_search 却不搜，交出去用户会以为搜过了。
      let route = OwlAskSearchRoute(
        routing: OwlCloudRouting(
          providerID: base.providerID,
          endpoint: base.endpoint,
          model: OwlSearchControl.searchModel,
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
    let deepSeek = profilesProvider().filter {
      OwlLLMProviderCatalog.inferredProviderID(for: $0) == OwlSearchControl.searchProviderID
    }
    guard let active = defaultProfileProvider(),
          let index = deepSeek.firstIndex(where: { $0.id == active.id }) else { return deepSeek }
    var ordered = deepSeek
    ordered.insert(ordered.remove(at: index), at: 0)
    return ordered
  }

  /// A non-empty stored key for `profile`, or nil. A profile with no `secretName` (never happens for
  /// a stored profile, defensive) and a Keychain read failure both mean "not usable" — skip to the
  /// next candidate rather than failing the whole question.
  private func usableKey(for profile: OwlProviderProfile) -> String? {
    // `try?` flattens both failure modes into nil: a Keychain throw and a genuinely absent key.
    guard let raw = try? secretProvider(profile.secretName) else { return nil }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
  /// 这些状态能确认是当前候选的固定配置问题，而不是这次请求的内容/网络问题。
  static let configurationRefusalStatuses: Set<Int> = [401, 402, 403, 404]

  /// 该换下一条联网尝试吗？首个 delta 是不可逆边界：一旦已有输出，即使随后收到明确的
  /// 401/404，也必须原样上报，不能把两家答案拼在一起。
  static func shouldTryNextAttempt(after error: Error, hasYieldedDelta: Bool) -> Bool {
    guard !hasYieldedDelta else { return false }
    switch error {
    case let streaming as OwlStreamingError:
      switch streaming {
      case let .badHTTPStatus(status):
        return isConfigurationRefusal(status: status)
      case .invalidEndpoint:
        // Responses URL 连改写都做不到，请求尚未发出；这是候选配置不可用，不是运行期故障。
        return true
      default:
        // 非 HTTP 响应 / 2xx 之后才失败：请求已被接受、模型已开工，换一家不会更好。
        return false
      }
    default:
      // URLError（断网/超时/DNS）与一切未知错误：如实上报，绝不静默换家。
      return false
    }
  }

  /// 明确的配置拒绝。451、422 等语义可能与问题内容有关，不能据此跨供应商追加请求。
  static func isConfigurationRefusal(status: Int) -> Bool {
    configurationRefusalStatuses.contains(status)
  }
}
