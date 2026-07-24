//
//  FamoVerificationRouting.swift
//  法墨输入法 (Famo) — 来源核验跳库深链核心 (issue #133)
//
//  1:1 移植自 Responsay `ResponsayCore/LegalBrain/Verification/VerificationQueryRouter.swift`
//  + `SelectionVerifyClipboard.swift` + `Security/ExternalLinkPolicy.swift`（体验对齐要求，
//  见主线仓 docs/famo-responsay-alignment-spec.md）。Core 只产出 route 描述；
//  打开 URL（用户默认浏览器，绝不用应用内 webview）与写剪贴板由 UI 层（#135）负责。
//
//  两种深链策略，按站选择：
//    · directSearch — 检索词进该站自己的检索 URL（知网 ?kw= / 百度学术 ?wd= / 必应 ?q= …），
//      地址栏带词、落地即结果页（已拍板第一优先，真机验收过）。
//    · bingSite     — 付费/JS/验证码站（北大法宝、国家法规库、人民法院案例库、裁判文书网）
//      自家搜索框带不了词，走「必应 site:域名 检索词」；必应可能弹人机验证，已拍板接受。
//

import Foundation

/// 待核锚点的坐标类型（#134 的抽取器产出同一枚举；此处先定义供路由默认源使用）。
enum FamoVerificationKind: String, Codable, Sendable, CaseIterable {
  case law
  case caseLaw
  case administrativeRule
  case standard
  case scholarlyArticle
  case date
  case money
  case officialDocument
  case other
}

/// 跳库来源。rawValue 与 Responsay `VerificationSourcePreference` 一致，便于两边文档互查。
enum FamoVerificationSource: String, Codable, Sendable, CaseIterable {
  case govLaw          // 国家法规库 flk.npc.gov.cn
  case pkulaw          // 北大法宝（付费 → Bing site:）
  case cnki            // 知网
  case vip             // 维普
  case wanfang         // 万方
  case baiduScholar    // 百度学术
  case itslaw          // 无讼
  case wenshu          // 裁判文书网（验证码 → Bing site:）
  case rmfyalk         // 人民法院案例库（JS 前端 → Bing site:）
  case bing            // 必应（直达 + site: 兜底承载引擎）
  case webSearch       // 百度网页兜底
  case qwenSearch      // 模型内置联网搜索（不走 URL）
  case manual          // 复制检索词

  /// 菜单/徽标显示名，逐字对齐 Responsay `VerificationSourceDisplay`。
  var displayName: String {
    switch self {
    case .govLaw: return "国家法规库"
    case .pkulaw: return "北大法宝"
    case .cnki: return "知网"
    case .vip: return "维普"
    case .wanfang: return "万方"
    case .baiduScholar: return "百度学术"
    case .itslaw: return "无讼"
    case .wenshu: return "裁判文书网"
    case .rmfyalk: return "人民法院案例库"
    case .bing: return "必应"
    case .webSearch: return "百度"
    case .qwenSearch: return "AI 联网搜索"
    case .manual: return "复制检索词"
    }
  }
}

enum FamoVerificationRouteKind: String, Sendable, Equatable {
  case deepLink      // 打开检索结果页（该站自己的，或必应 site:）
  case modelSearch   // 模型内置搜索 — 只带 query 不带 URL
  case copyOnly      // 手动 — 复制检索词，用户自己搜
}

struct FamoVerificationRoute: Sendable, Equatable {
  let kind: FamoVerificationRouteKind
  let source: FamoVerificationSource
  let query: String
  let url: URL?      // 仅 `.deepLink` 存在
}

/// 检索词 → 跳库 URL 的路由器。纯值逻辑，无网络、无副作用。
enum FamoVerificationQueryRouter {

  /// 必应检索基址 —— 直达 `.bing` 与所有 site: 兜底共用。
  static let bingSearchBase = "https://www.bing.com/search"

  /// 整段选区兜底检索词上限：超长 CJK 检索词会让站内引擎直接返回空（Responsay issue 328）。
  static let maxSelectionQueryLength = 80

  /// 整段选区 → 兜底检索词：合并空白后截断到上限。
  static func normalizeSelection(_ text: String) -> String {
    let joined = text
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
    return String(joined.prefix(maxSelectionQueryLength))
  }

  /// kind 的默认跳库来源（未显式选源时）。
  static func defaultSource(for kind: FamoVerificationKind) -> FamoVerificationSource {
    switch kind {
    case .scholarlyArticle: return .baiduScholar
    case .caseLaw: return .pkulaw
    case .law, .administrativeRule, .standard, .officialDocument: return .govLaw
    case .date, .money, .other: return .baiduScholar
    }
  }

  /// 把检索词路由到指定来源。
  static func route(query: String, source: FamoVerificationSource) -> FamoVerificationRoute {
    switch source {
    case .qwenSearch:
      return FamoVerificationRoute(kind: .modelSearch, source: source, query: query, url: nil)
    case .manual:
      return FamoVerificationRoute(kind: .copyOnly, source: source, query: query, url: nil)
    default:
      return FamoVerificationRoute(kind: .deepLink, source: source, query: query,
                                   url: searchURL(for: source, query: query))
    }
  }

  // MARK: - 逐源检索样式

  enum SearchStyle: Equatable {
    case directSearch(base: String, param: String)
    case bingSite(domain: String)
  }

  static func style(for source: FamoVerificationSource) -> SearchStyle? {
    switch source {
    case .baiduScholar: return .directSearch(base: "https://xueshu.baidu.com/s", param: "wd")
    case .cnki: return .directSearch(base: "https://kns.cnki.net/kns8s/defaultresult/index", param: "kw")
    case .webSearch: return .directSearch(base: "https://www.baidu.com/s", param: "wd")
    case .bing: return .directSearch(base: bingSearchBase, param: "q")
    case .itslaw: return .directSearch(base: "https://www.itslaw.com/search", param: "searchWord")
    case .wanfang: return .directSearch(base: "https://s.wanfangdata.com.cn/paper", param: "q")
    case .vip: return .directSearch(base: "https://qikan.cqvip.com/Qikan/Search/Index", param: "key")
    case .pkulaw: return .bingSite(domain: "pkulaw.com")             // 付费 → site:
    case .govLaw: return .bingSite(domain: "flk.npc.gov.cn")         // JS 前端检索 → site:
    case .rmfyalk: return .bingSite(domain: "rmfyalk.court.gov.cn")  // JS 前端检索 → site:
    case .wenshu: return .bingSite(domain: "wenshu.court.gov.cn")    // 验证码 → site:
    case .qwenSearch, .manual: return nil                            // 不走 URL
    }
  }

  static func searchURL(for source: FamoVerificationSource, query: String) -> URL? {
    switch style(for: source) {
    case let .directSearch(base, param):
      return makeURL(base: base, param: param, value: query)
    case let .bingSite(domain):
      return makeURL(base: bingSearchBase, param: "q", value: "site:\(domain) \(query)")
    case nil:
      return nil
    }
  }

  private static func makeURL(base: String, param: String, value: String) -> URL? {
    URL(string: "\(base)?\(param)=\(encodeQueryValue(value))")
  }

  /// RFC-3986 query-value 编码，且额外把 `+` 转义为 `%2B`：裸 `+` 会被百度/必应解成空格，
  /// 撕裂多词法律检索（Responsay issue 328 踩坑修复，必须逐字复刻）。空格→%20，CJK→百分号。
  static func encodeQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=?#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

/// 剪贴板纪律：只有当打开的深链 URL 不带 query 参数（无参检索页，用户必须手动粘贴，
/// 如知网专业检索 AdvSearch）时才返回待粘贴的检索词；每个已开 URL 都自带词时返回 nil，
/// **不动用户剪贴板**。先 open 后复制的时序由调用方保证。
enum FamoSelectionVerifyClipboard {
  static func pasteQuery(openedRoutes: [FamoVerificationRoute]) -> String? {
    openedRoutes.first { route in
      guard let url = route.url else { return false }   // 未打开的 route 不算
      return url.query?.isEmpty ?? true                 // 无 query 串 → 需要粘贴
    }?.query
  }
}

/// 链接安全闸：LLM 联网核验返回的 URL 字符串可被注入内容影响（`javascript:`、`file:`、
/// `data:`、自定义 scheme、`https://trusted@evil.com`），只有普通 http/https + 非空 host
/// + 无 userinfo 才允许成为可点链接；否则渲染为不可点纯文本。
enum FamoExternalLinkPolicy {
  static func safeWebURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    guard let host = url.host, !host.isEmpty else { return nil }
    guard url.user == nil else { return nil }   // 拒绝 userinfo 钓鱼
    return url
  }
}
