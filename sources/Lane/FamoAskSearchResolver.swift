//
//  FamoAskSearchResolver.swift
//  法墨输入法 (Famo) — 任意提问「联网搜索」的专属模型解析
//
//  开关开启时，把这一问路由到一个**可联网的专属供应商**（专用搜索凭据 豆包搜索/Perplexity，或已配好
//  密钥的 Qwen/MiMo/OpenAI），与主对话模型解耦 —— 主模型不支持联网时也能真搜到。若只在主模型请求里
//  拼搜索参数，主模型（常见是 DeepSeek）不支持联网时会被静默降级成普通问答、只答到训练截止，而用户
//  以为搜了。
//
//  一家都没配好密钥 → `resolveAll()` 返回空，调用方**静默退回**普通问答（`FamoProviderAuthGate`
//  那条既有路）。这是刻意的降级语义：联网是加分项，不是让提问失败的理由。
//
//  为什么返回的是**列表**而不是单个路由：配置期「有没有 Key」与运行期「这家肯不肯服务」是两回事 ——
//  方舟没开通内容插件是 404 `ToolNotOpen`、MiMo 的 Key 失效是 401，两者都只在请求发出后才知道。
//  `resolveAll()` 交出全部候选，`FamoStreamingChatService.openAsk` 在**首个 delta 之前**按
//  `FamoAskSearchFailover` 顺位到下一家，全败才退回普通问答 —— 与设置页「都没配密钥时会自动退回
//  普通问答」的用户预期同一条语义。
//
//  顺序规则（`orderedCandidates`）：用户在设置里显式选的「联网模型」排第一；没选（自动）时，
//  当前默认档案本身可联网就优先用它（省得另配一份密钥）；其余按 `FamoSearchControl.searchProviderIDs`
//  补齐。偏好**只影响顺序**：选中的那家没配密钥时照样顺位到下一家，而不是让这一问不联网 ——
//  与上面的静默降级同一条逻辑，且 AI 窗的署名 chip 会如实写出到底是谁答的（顺位/退回后会改写），
//  所以「以为用 A 实际用 B」是可见的，不是欺骗。
//
//  纯值解析：不发请求。唯一副作用是注入的 Keychain 读取，其失败被吞成「这家不可用」而继续
//  下一家（与 `FamoProviderAuthGate` 的「永不因钥匙串崩掉调用方」契约一致）。
//

import Foundation

// MARK: - Preference

/// 任意提问「联网搜索」总开关。默认 **关**（opt-in）：开启后这一问会发给该服务商的联网搜索工具。
enum FamoAskWebSearchSettings {
  static let key = "FamoAskWebSearchEnabled"

  /// Default false — a user must explicitly opt in before any question reaches a search tool.
  static var isEnabled: Bool {
    get { FamoDefaults.standard.object(forKey: key) as? Bool ?? false }
    set { FamoDefaults.standard.set(newValue, forKey: key) }
  }

  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: key)
  }
}

/// 任意提问「联网模型」偏好：用户显式指定由哪家联网作答。默认空 = 自动。
///
/// 偏好只影响 `FamoAskSearchResolver.orderedCandidates` 的**顺序**，不影响「没配密钥就跳过」——
/// 选了豆包却没填豆包 Key 时，这一问仍会顺位到下一家联网，而不是退回不联网的普通问答。
enum FamoAskSearchProviderSettings {
  static let key = "FamoAskSearchProvider"

  /// The stored raw value (`""` = 自动). This is what the settings mirror reads/writes; use
  /// `preferredProviderID` when you need the validated choice.
  static var rawValue: String {
    get { FamoDefaults.standard.string(forKey: key) ?? "" }
    set { FamoDefaults.standard.set(newValue, forKey: key) }
  }

  /// The user's explicit choice, or nil for 自动. A stored id that is not (or is no longer) a
  /// search-capable provider reads as 自动 rather than pinning the order to a dead entry.
  static var preferredProviderID: String? {
    let stored = rawValue
    return FamoSearchControl.searchProviderIDs.contains(stored) ? stored : nil
  }

  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: key)
  }
}

// MARK: - Resolved route

/// A resolved 联网搜索 route: which provider answers, how to reach it, and the key to use.
/// `providerID` drives both the request body (`FamoSearchControl.extraBody`) and the window's
/// 署名 chip, so the user can see WHO answered this question online.
struct FamoAskSearchRoute: Equatable {
  let routing: FamoCloudRouting
  let apiKey: String

  var providerID: String { routing.providerID }
  /// 面向用户的品牌名（通义千问 / MiMo / 豆包 / OpenAI），供 AI 窗署名 chip 使用。
  var displayName: String? { FamoSearchControl.displayName(for: providerID) }
  /// WHICH transport carries this route's search — `openAsk` picks its client from this rather
  /// than re-deriving it from the provider id.
  var transport: FamoSearchControl.Transport {
    FamoSearchControl.transport(providerID: providerID, host: routing.endpoint.host ?? "")
  }
  /// The provider-specific `/chat/completions` body fields that switch search on for this route.
  /// Empty for a `/responses` route — its search parameters live in `FamoResponsesWire.searchBody`.
  var extraBody: [String: Any] {
    FamoSearchControl.extraBody(providerID: providerID, host: routing.endpoint.host ?? "")
  }
}

// MARK: - Resolver

/// Resolves the 联网搜索 route from the toggle + the configured provider profiles. A `struct` of
/// injected closures (same DI idiom as `FamoProviderAuthGate` — one implementation, test fakes via
/// the closures). Deterministic given its inputs; no network.
@MainActor
struct FamoAskSearchResolver {
  /// The 联网搜索 toggle. Default = the live preference.
  var isEnabled: () -> Bool
  /// All configured provider profiles, in the store's stable order. Default = the live store.
  var profilesProvider: () -> [FamoProviderProfile]
  /// The active (default) profile — the 自动 rule prefers it when it can already search.
  var defaultProfileProvider: () -> FamoProviderProfile?
  /// The user's explicit「联网模型」choice (nil = 自动). Default = the live preference.
  var preferredProviderID: () -> String?
  /// Reads a profile's API key by `secretName`. Default = the live Keychain.
  var secretProvider: (String) throws -> String?

  init(
    isEnabled: @escaping () -> Bool = { FamoAskWebSearchSettings.isEnabled },
    profilesProvider: @escaping () -> [FamoProviderProfile] = { FamoProviderProfileStore.shared.profiles() },
    defaultProfileProvider: @escaping () -> FamoProviderProfile? = { FamoProviderProfileStore.shared.defaultProfile },
    preferredProviderID: @escaping () -> String? = { FamoAskSearchProviderSettings.preferredProviderID },
    secretProvider: @escaping (String) throws -> String? = { try FamoProviderKeychain().secret(named: $0) }
  ) {
    self.isEnabled = isEnabled
    self.profilesProvider = profilesProvider
    self.defaultProfileProvider = defaultProfileProvider
    self.preferredProviderID = preferredProviderID
    self.secretProvider = secretProvider
  }

  /// The first 联网搜索 route for this question, or nil → caller falls back to plain chat.
  /// nil covers all three "no search this time" cases: toggle off, no search-capable provider, or
  /// every search-capable provider still missing its key.
  func resolve() -> FamoAskSearchRoute? {
    resolveAll().first
  }

  /// EVERY configured 联网搜索 route, in `orderedCandidates()` order — the input to the runtime
  /// failover in `FamoStreamingChatService.openAsk`. Empty = no search this time (same three cases
  /// as `resolve()` returning nil).
  func resolveAll() -> [FamoAskSearchRoute] {
    guard isEnabled() else { return [] }
    let profiles = profilesProvider()
    return orderedCandidates().compactMap { route(for: $0, profiles: profiles) }
  }

  /// One candidate id → a usable route, or nil when its key is missing/unreadable.
  ///
  /// 两种候选来源：「联网搜索专用 Key」（`FamoSearchCredential`，端点与模型由凭据自己定死，不需要
  /// `providers.json` 里有对应档案）与内建搜索的对话供应商（从档案解析路由）。
  private func route(for providerID: String, profiles: [FamoProviderProfile]) -> FamoAskSearchRoute? {
    if let credential = FamoSearchCredential(providerID: providerID) {
      guard let apiKey = usableKey(named: credential.secretName) else { return nil }
      return FamoAskSearchRoute(routing: credential.routing, apiKey: apiKey)
    }
    guard let profile = profiles.first(where: {
      FamoLLMProviderCatalog.inferredProviderID(for: $0) == providerID
    }) else { return nil }
    guard let apiKey = usableKey(named: profile.secretName) else { return nil }
    return FamoAskSearchRoute(routing: FamoCloudRouting.resolve(profile: profile), apiKey: apiKey)
  }

  /// The order providers are tried in.
  ///
  /// 1. The user's explicit「联网模型」choice, when they made one — ONLY reordering, never gating:
  ///    `resolveAll()` still drops it if its key is missing, so a half-configured choice degrades to
  ///    the next provider instead of silently turning 联网 off.
  /// 2. Otherwise 自动: 「联网搜索专用 Key」两家保持在最前（没填 Key 时会在 `route(for:)` 里自然掉
  ///    出，不占位），随后才是活动档案本身（它可联网时优先，省得另配一份密钥），再是其余对话供应商。
  private func orderedCandidates() -> [String] {
    let base = FamoSearchControl.searchProviderIDs
    if let preferred = preferredProviderID(), base.contains(preferred) {
      return [preferred] + base.filter { $0 != preferred }
    }
    guard let active = defaultProfileProvider() else { return base }
    let activeID = FamoLLMProviderCatalog.inferredProviderID(for: active)
    guard base.contains(activeID) else { return base }
    let credentials = base.filter { FamoSearchCredential(providerID: $0) != nil }
    let chatProviders = base.filter { FamoSearchCredential(providerID: $0) == nil && $0 != activeID }
    return credentials + [activeID] + chatProviders
  }

  /// A non-empty stored key under `secretName`, or nil. An absent key and a Keychain read failure
  /// both mean "not usable" — skip to the next candidate rather than failing the whole question.
  private func usableKey(named secretName: String) -> String? {
    // `try?` flattens both failure modes into nil: a Keychain throw and a genuinely absent key.
    guard let raw = try? secretProvider(secretName) else { return nil }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
  }
}

// MARK: - 运行期顺位降级策略

/// 一次联网尝试失败后，该顺位到下一家、还是如实报错给用户。
///
/// 判据是「这家在当前配置下**拒绝服务**」还是「这次请求碰上了暂时的麻烦」：
///   - 顺位：4xx。方舟未开通内容插件是 404 `ToolNotOpen`、MiMo 的 Key 失效是 401、欠费/未授权是
///     402/403、参数被拒是 400 —— 换成同一家重试永远是同一个结果，只有换一家才可能出答案。
///     `invalidEndpoint`（端点改写不成 `/responses`）同理，是这条路由本身配不对。
///   - 报错：408 请求超时与 429 限流虽是 4xx 但**暂时**；5xx 是对方故障；`URLError`（断网、超时）
///     是用户自己那侧的真错误。这些一律如实上报 —— 把断网吞成「换一家」会让用户以为是我们坏了，
///     而且下一家同样连不上，只是把一个错误变成四个。
///   - 报错：`upstreamFailure`（2xx 之后的 `response.failed`）也不顺位：请求已被接受、模型已经开工，
///     这类失败换一家不会更好，而且可能已经有内容送到窗口了。
enum FamoAskSearchFailover {
  /// 4xx 里**不**触发顺位的两个：请求超时与限流，两者稍后重试同一家仍有可能成功。
  static let transientStatuses: Set<Int> = [408, 429]

  /// 该换下一家联网供应商吗？
  static func shouldTryNextProvider(after error: Error) -> Bool {
    switch error {
    case let streaming as FamoStreamingError:
      switch streaming {
      case let .badHTTPStatus(status):
        return isConfigurationRefusal(status: status)
      case .invalidEndpoint:
        return true
      case .nonHTTPResponse, .upstreamFailure:
        return false
      }
    case let retrieval as FamoWebRetrievalError:
      // 豆包搜索这类纯检索路由自己判（业务错误码会带着 HTTP 200 回来）——见 `isRouteUnusable`。
      return retrieval.isRouteUnusable
    default:
      // URLError（断网/超时/DNS）与一切未知错误：如实上报，绝不静默换家。
      return false
    }
  }

  /// 4xx 且不是 408/429 —— 「这家在当前配置下不会为你服务」。
  static func isConfigurationRefusal(status: Int) -> Bool {
    (400...499).contains(status) && !transientStatuses.contains(status)
  }
}
