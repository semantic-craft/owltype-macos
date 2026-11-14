//
//  OwlVerificationRoutingTests.swift
//  OwltypeTests — 来源核验跳库深链核心 (issue #133)
//
//  纯值逻辑：路由表逐源 URL 断言（含编码边界：裸 +、&、CJK）、知网专业检索式、
//  剪贴板纪律判定、链接安全闸。无网络、无剪贴板副作用、无引擎。
//  URL 模板逐字对齐 Responsay VerificationQueryRouter（docs/owl-responsay-alignment-spec.md §1）。
//

import Foundation
import XCTest
@testable import Owltype

final class OwlVerificationRoutingTests: XCTestCase {

  // MARK: - 路由表：direct 源逐字断言

  func testDirectSearchURLTable() {
    let cases: [(OwlVerificationSource, String)] = [
      (.cnki, "https://kns.cnki.net/kns8s/defaultresult/index?kw=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
      (.baiduScholar, "https://xueshu.baidu.com/s?wd=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
      (.webSearch, "https://www.baidu.com/s?wd=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
      (.bing, "https://www.bing.com/search?q=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
      (.itslaw, "https://www.itslaw.com/search?searchWord=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
      (.wanfang, "https://s.wanfangdata.com.cn/paper?q=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
      (.vip, "https://qikan.cqvip.com/Qikan/Search/Index?key=%E6%83%A9%E7%BD%9A%E6%80%A7%E8%B5%94%E5%81%BF%E7%A0%94%E7%A9%B6"),
    ]
    for (source, expected) in cases {
      let url = OwlVerificationQueryRouter.route(query: "惩罚性赔偿研究", source: source).url
      XCTAssertEqual(url?.absoluteString, expected, "\(source.rawValue) 直达 URL 必须逐字匹配")
    }
  }

  // MARK: - 路由表：bing site: 兜底四源

  func testBingSiteFallbackURLTable() {
    let cases: [(OwlVerificationSource, String)] = [
      (.pkulaw, "pkulaw.com"),
      (.govLaw, "flk.npc.gov.cn"),
      (.rmfyalk, "rmfyalk.court.gov.cn"),
      (.wenshu, "wenshu.court.gov.cn"),
    ]
    for (source, domain) in cases {
      let url = OwlVerificationQueryRouter.route(query: "《民法典》第五百七十七条", source: source).url
      let expectedPrefix = "https://www.bing.com/search?q=site:\(domain)%20"
      XCTAssertNotNil(url)
      XCTAssertTrue(url!.absoluteString.hasPrefix(expectedPrefix),
                    "\(source.rawValue) 必须走必应 site:\(domain) 兜底，实际 \(url!.absoluteString)")
    }
  }

  // MARK: - 编码：裸 + / & / = / ? / # 必须转义（Responsay issue 328）

  func testEncodeQueryValueEscapesPlusAndReservedChars() {
    XCTAssertEqual(
      OwlVerificationQueryRouter.route(query: "a+b", source: .bing).url?.absoluteString,
      "https://www.bing.com/search?q=a%2Bb")
    XCTAssertEqual(
      OwlVerificationQueryRouter.route(query: "a&b=c?d#e", source: .bing).url?.absoluteString,
      "https://www.bing.com/search?q=a%26b%3Dc%3Fd%23e")
    XCTAssertEqual(
      OwlVerificationQueryRouter.route(query: "民法 典", source: .bing).url?.absoluteString,
      "https://www.bing.com/search?q=%E6%B0%91%E6%B3%95%20%E5%85%B8")
  }

  func testDirectURLCarriesEscapedPlusInsideQuery() {
    let url = OwlVerificationQueryRouter.route(query: "民法典 第577条+违约", source: .bing).url
    XCTAssertEqual(url?.absoluteString,
                   "https://www.bing.com/search?q=%E6%B0%91%E6%B3%95%E5%85%B8%20%E7%AC%AC577%E6%9D%A1%2B%E8%BF%9D%E7%BA%A6")
  }

  // MARK: - route(kind:) 分派与默认源

  func testRouteKindsAndDefaultSources() {
    XCTAssertEqual(OwlVerificationQueryRouter.route(query: "q", source: .qwenSearch).kind, .modelSearch)
    XCTAssertNil(OwlVerificationQueryRouter.route(query: "q", source: .qwenSearch).url)
    XCTAssertEqual(OwlVerificationQueryRouter.route(query: "q", source: .manual).kind, .copyOnly)
    XCTAssertEqual(OwlVerificationQueryRouter.route(query: "q", source: .cnki).kind, .deepLink)
    XCTAssertNotNil(OwlVerificationQueryRouter.route(query: "q", source: .cnki).url)

    XCTAssertEqual(OwlVerificationQueryRouter.defaultSource(for: .scholarlyArticle), .baiduScholar)
    XCTAssertEqual(OwlVerificationQueryRouter.defaultSource(for: .caseLaw), .pkulaw)
    XCTAssertEqual(OwlVerificationQueryRouter.defaultSource(for: .law), .govLaw)
    XCTAssertEqual(OwlVerificationQueryRouter.defaultSource(for: .standard), .govLaw)
    XCTAssertEqual(OwlVerificationQueryRouter.defaultSource(for: .other), .baiduScholar)
  }

  // MARK: - 整段选区兜底：合并空白 + 截断 80 字

  func testNormalizeSelectionJoinsWhitespaceAndTruncates() {
    XCTAssertEqual(OwlVerificationQueryRouter.normalizeSelection("民法典\n  第五百七十七条\t违约责任"),
                   "民法典 第五百七十七条 违约责任")
    let long = String(repeating: "法", count: 120)
    XCTAssertEqual(OwlVerificationQueryRouter.normalizeSelection(long).count, 80)
  }

  // MARK: - 剪贴板纪律：URL 自带词 → 不动剪贴板；无参页 → 给出待粘贴词

  func testClipboardDisciplineOnlyPastesForNoParamPages() throws {
    let carried = OwlVerificationQueryRouter.route(query: "惩罚性赔偿研究", source: .cnki)
    XCTAssertNil(OwlSelectionVerifyClipboard.pasteQuery(openedRoutes: [carried]),
                 "URL 自带 kw= 检索词时绝不动用户剪贴板")

    let menu = OwlSelectionVerifyMenu.build(selectedText: "惩罚性赔偿研究")
    let advSearch = try XCTUnwrap(menu.first { $0.title == "文献" }?.items.first { $0.route.url?.query == nil }?.route)
    XCTAssertEqual(OwlSelectionVerifyClipboard.pasteQuery(openedRoutes: [carried, advSearch]),
                   "SU %= '惩罚性赔偿研究'",
                   "无参检索页必须给出待粘贴的检索式")

    let unopened = OwlVerificationRoute(kind: .copyOnly, source: .manual, query: "q", url: nil)
    XCTAssertNil(OwlSelectionVerifyClipboard.pasteQuery(openedRoutes: [unopened]),
                 "没有 URL 的 route 不参与判定")
  }

  // MARK: - 链接安全闸

  func testExternalLinkPolicy() {
    XCTAssertNotNil(OwlExternalLinkPolicy.safeWebURL("https://flk.npc.gov.cn/detail2.html?x=1"))
    XCTAssertNotNil(OwlExternalLinkPolicy.safeWebURL("  http://pkulaw.com  "))
    XCTAssertNil(OwlExternalLinkPolicy.safeWebURL("javascript:alert(1)"))
    XCTAssertNil(OwlExternalLinkPolicy.safeWebURL("file:///etc/passwd"))
    XCTAssertNil(OwlExternalLinkPolicy.safeWebURL("data:text/html,hi"))
    XCTAssertNil(OwlExternalLinkPolicy.safeWebURL("owltype://open"))
    XCTAssertNil(OwlExternalLinkPolicy.safeWebURL("https://trusted@evil.com/x"))
    XCTAssertNil(OwlExternalLinkPolicy.safeWebURL(""))
  }
}
