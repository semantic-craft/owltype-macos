//
//  OwlAskSearchResolver.swift
//  法墨输入法 (Owltype) — 任意提问「联网搜索」的专属模型解析
//
//  开关开启时，把这一问路由到一个**可联网的专属供应商**（用户已配好密钥的 Qwen/MiMo/豆包/OpenAI），
//  与主对话模型解耦 —— 主模型不支持联网时也能真搜到。若只在主模型请求里拼搜索参数，主模型
//  （常见是 DeepSeek）不支持联网时会被静默降级成普通问答、只答到训练截止，而用户以为搜了。
//
//  一家都没配好密钥 → 返回 nil，调用方**静默退回**普通问答（`OwlProviderAuthGate` 那条既有路）。
//  这是刻意的降级语义：联网是加分项，不是让提问失败的理由。
//
//  顺序规则（`orderedCandidates`）：用户在设置里显式选的「联网模型」排第一；没选（自动）时，
//  当前默认档案本身可联网就优先用它（省得另配一份密钥）；其余按 `OwlSearchControl.searchProviderIDs`
//  补齐。偏好**只影响顺序**：选中的那家没配密钥时照样顺位到下一家，而不是让这一问不联网 ——
//  与上面的静默降级同一条逻辑，且 AI 窗的署名 chip 会如实写出到底是谁答的，所以「以为用 A 实际用 B」
//  是可见的，不是欺骗。
//
//  纯值解析：不发请求。唯一副作用是注入的 Keychain 读取，其失败被吞成「这家不可用」而继续
//  下一家（与 `OwlProviderAuthGate` 的「永不因钥匙串崩掉调用方」契约一致）。
//

import Foundation

// MARK: - Preference

/// 任意提问「联网搜索」总开关。默认 **关**（opt-in）：开启后这一问会发给该服务商的联网搜索工具。
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

/// 任意提问「联网模型」偏好：用户显式指定由哪家联网作答。默认空 = 自动。
///
/// 偏好只影响 `OwlAskSearchResolver.orderedCandidates` 的**顺序**，不影响「没配密钥就跳过」——
/// 选了豆包却没填豆包 Key 时，这一问仍会顺位到下一家联网，而不是退回不联网的普通问答。
enum OwlAskSearchProviderSettings {
  static let key = "OwlAskSearchProvider"

  /// The stored raw value (`""` = 自动). This is what the settings mirror reads/writes; use
  /// `preferredProviderID` when you need the validated choice.
  static var rawValue: String {
    get { OwlDefaults.standard.string(forKey: key) ?? "" }
    set { OwlDefaults.standard.set(newValue, forKey: key) }
  }

  /// The user's explicit choice, or nil for 自动. A stored id that is not (or is no longer) a
  /// search-capable provider reads as 自动 rather than pinning the order to a dead entry.
  static var preferredProviderID: String? {
    let stored = rawValue
    return OwlSearchControl.searchProviderIDs.contains(stored) ? stored : nil
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: key)
  }
}

// MARK: - Resolved route

/// A resolved 联网搜索 route: which provider answers, how to reach it, and the key to use.
/// `providerID` drives both the request body (`OwlSearchControl.extraBody`) and the window's
/// 署名 chip, so the user can see WHO answered this question online.
struct OwlAskSearchRoute: Equatable {
  let routing: OwlCloudRouting
  let apiKey: String

  var providerID: String { routing.providerID }
  /// 面向用户的品牌名（通义千问 / MiMo / 豆包 / OpenAI），供 AI 窗署名 chip 使用。
  var displayName: String? { OwlSearchControl.displayName(for: providerID) }
  /// WHICH transport carries this route's search — the 任意提问 module picks its client from this rather
  /// than re-deriving it from the provider id.
  var transport: OwlSearchControl.Transport {
    // 带上型号：DeepSeek 的 `/responses` 只收 deepseek-v4-flash，配着 pro 的档案不能搜。
    OwlSearchControl.transport(
      providerID: providerID, host: routing.endpoint.host ?? "", model: routing.model)
  }
  /// The provider-specific `/chat/completions` body fields that switch search on for this route.
  /// Empty for a `/responses` route — its search parameters live in `OwlResponsesWire.body`.
  var extraBody: [String: Any] {
    OwlSearchControl.extraBody(providerID: providerID, host: routing.endpoint.host ?? "")
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
  /// The active (default) profile — the 自动 rule prefers it when it can already search.
  var defaultProfileProvider: () -> OwlProviderProfile?
  /// The user's explicit「联网模型」choice (nil = 自动). Default = the live preference.
  var preferredProviderID: () -> String?
  /// Reads a profile's API key by `secretName`. Default = the live Keychain.
  var secretProvider: (String) throws -> String?

  init(
    isEnabled: @escaping () -> Bool = { OwlAskWebSearchSettings.isEnabled },
    profilesProvider: @escaping () -> [OwlProviderProfile] = { OwlProviderProfileStore.shared.profiles() },
    defaultProfileProvider: @escaping () -> OwlProviderProfile? = { OwlProviderProfileStore.shared.defaultProfile },
    preferredProviderID: @escaping () -> String? = { OwlAskSearchProviderSettings.preferredProviderID },
    secretProvider: @escaping (String) throws -> String? = { try OwlProviderKeychain().secret(named: $0) }
  ) {
    self.isEnabled = isEnabled
    self.profilesProvider = profilesProvider
    self.defaultProfileProvider = defaultProfileProvider
    self.preferredProviderID = preferredProviderID
    self.secretProvider = secretProvider
  }

  /// The 联网搜索 route for this question, or nil → caller falls back to plain chat.
  /// nil covers all three "no search this time" cases: toggle off, no search-capable profile, or
  /// every search-capable profile still missing its key.
  func resolve() -> OwlAskSearchRoute? {
    resolveAll().first
  }

  /// EVERY configured 联网搜索 route, in `orderedCandidates()` order — the input to the runtime
  /// failover in `OwlAskAnythingModule`.
  ///
  /// 为什么要**列表**而不是单个路由：配置期「有没有 Key」与运行期「这家肯不肯服务」是两回事 ——
  /// 方舟没开通内容插件是 404 `ToolNotOpen`、MiMo 的 Key 失效是 401，两者都只在请求发出后才知道。
  /// 交出全部候选，调用方在首个 delta 之前顺位，全败才退回普通问答。
  func resolveAll() -> [OwlAskSearchRoute] {
    guard isEnabled() else { return [] }
    let profiles = profilesProvider()
    return orderedCandidates().compactMap { providerID in
      guard let profile = profiles.first(where: {
        OwlLLMProviderCatalog.inferredProviderID(for: $0) == providerID
      }) else { return nil }
      guard let apiKey = usableKey(for: profile) else { return nil }
      let route = OwlAskSearchRoute(
        routing: OwlCloudRouting.resolve(profile: profile), apiKey: apiKey)
      // 顺位表是按 providerID 排的，但「这家能不能搜」还可能取决于**型号**：DeepSeek 的
      // `/responses` 只收 deepseek-v4-flash，配着 pro 的档案交出去只会换来一个 400。
      // 在这里提前过滤，避免发出一次已知无效请求后才进入运行期顺位。
      guard route.transport != .none else { return nil }
      return route
    }
  }

  /// The order providers are tried in.
  ///
  /// 1. The user's explicit「联网模型」choice, when they made one — ONLY reordering, never gating:
  ///    the loop in `resolve()` still skips it if its key is missing, so a half-configured choice
  ///    degrades to the next provider instead of silently turning 联网 off.
  /// 2. Otherwise 自动: the active profile's provider first when it can already search (no extra
  ///    key to configure), then the standard priority order with that provider removed.
  private func orderedCandidates() -> [String] {
    let base = OwlSearchControl.searchProviderIDs
    if let preferred = preferredProviderID(), base.contains(preferred) {
      return [preferred] + base.filter { $0 != preferred }
    }
    guard let active = defaultProfileProvider() else { return base }
    let activeID = OwlLLMProviderCatalog.inferredProviderID(for: active)
    guard base.contains(activeID) else { return base }
    return [activeID] + base.filter { $0 != activeID }
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
///   - 顺位：明确的鉴权/套餐/插件配置状态。方舟未开通内容插件是 404 `ToolNotOpen`、MiMo 的
///     Key 失效是 401、欠费/未授权是 402/403。
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
    case let search as OwlWebSearchError:
      // 独立搜索层自己判——它的业务错误会带着 HTTP 200 回来。
      return search.isRouteUnusable
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
