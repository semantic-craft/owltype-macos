//
//  FamoVerificationAnchorsTests.swift
//  FamoTests — 来源核验锚点数据层 (issue #134)
//
//  纯值逻辑：坐标抽取（法条/案号/文件号/标准/日期/金额、去重、引导词剥离）、
//  案号准入闸表驱动用例、分组源菜单模型（组序/知网双入口/精准坐标优先/整段兜底）。
//

import Foundation
import XCTest
@testable import Famo

final class FamoVerificationAnchorsTests: XCTestCase {

  // MARK: - 坐标抽取

  func testExtractsLawAndCaseAnchorsFromComplaint() {
    let text = "根据《中华人民共和国民法典》第五百七十七条，被告应当承担违约责任；同类裁判可参见（2025）粤03民终8964号民事判决书。"
    let anchors = FamoFactCoordinateExtractor.extract(from: text)
    XCTAssertEqual(anchors.count, 2)
    XCTAssertEqual(anchors[0].label, "《中华人民共和国民法典》第五百七十七条")
    XCTAssertEqual(anchors[0].kind, .law)
    XCTAssertEqual(anchors[0].status, .pending)
    XCTAssertEqual(anchors[0].query, anchors[0].label, "锚点 query = 坐标原文，逐字进跳库")
    XCTAssertEqual(anchors[0].preferredSources, [.govLaw, .pkulaw])
    XCTAssertEqual(anchors[1].label, "（2025）粤03民终8964号")
    XCTAssertEqual(anchors[1].kind, .caseLaw)
  }

  func testExtractNormalizesWhitespaceAndDedupes() {
    let text = "《个保法》第 24 条与《个保法》第24条重复；依据国发〔2007〕19号文件执行。"
    let anchors = FamoFactCoordinateExtractor.extract(from: text)
    let labels = anchors.map(\.label)
    XCTAssertEqual(labels.filter { $0 == "《个保法》第24条" }.count, 1, "空格差异合并后按 label 去重")
    XCTAssertTrue(labels.contains("国发〔2007〕19号"), "引导词「依据」必须剥离，实际 \(labels)")
    let doc = anchors.first { $0.kind == .officialDocument }
    XCTAssertEqual(doc?.label, "国发〔2007〕19号")
  }

  func testExtractsStandardDateMoneyAndGuidingCase() {
    let text = "按 GB/T 39335-2020 于2021年1月1日验收，费用 5000元；参照指导案例24号。"
    let anchors = FamoFactCoordinateExtractor.extract(from: text)
    let byKind = Dictionary(grouping: anchors, by: \.kind)
    XCTAssertEqual(byKind[.standard]?.first?.label, "GB/T39335-2020")
    XCTAssertEqual(byKind[.date]?.first?.label, "2021年1月1日")
    XCTAssertEqual(byKind[.money]?.first?.label, "5000元")
    XCTAssertEqual(byKind[.law]?.first?.label, "指导案例24号", "指导案例归 law 规则")
    XCTAssertTrue(anchors.allSatisfy { $0.status == .pending }, "抽取器永不宣称已核")
  }

  // MARK: - 案号准入闸（表驱动）

  func testCaseNumberVerifierTable() {
    let verifier = FamoCaseNumberVerifier(currentYear: 2026)
    // ✅ 完整：用户举例
    let complete = verifier.verify("（2025）粤03民终8964号")
    XCTAssertEqual(complete.status, .complete)
    XCTAssertEqual(complete.disposition, .admit)
    XCTAssertEqual(complete.caseNumber?.year, 2025)
    XCTAssertEqual(complete.caseNumber?.courtCode, "粤03")
    XCTAssertEqual(complete.caseNumber?.caseType, .civilSecondInstance)
    XCTAssertEqual(complete.caseNumber?.sequence, 8964)
    // ✅ 半角括号兼容
    XCTAssertEqual(verifier.verify("(2021)京01民初1234号").status, .complete)
    // ✅ 入库编号（人民法院案例库）
    let library = verifier.verify("入库编号2024-07-2-084-011")
    XCTAssertEqual(library.status, .complete)
    XCTAssertEqual(library.caseNumber?.caseType, .caseLibrary)
    // ❓ 形状对但年份非法 → 疑似虚构
    XCTAssertEqual(verifier.verify("（2077）粤03民终8964号").status, .suspectedFabricated)
    XCTAssertEqual(verifier.verify("（2077）粤03民终8964号").disposition, .discard)
    // ❓ 形似案号的壳（类型字编造）
    XCTAssertEqual(verifier.verify("（2024）某某某判字99号").status, .suspectedFabricated)
    // ⚠️ 真词干但缺完整编号
    XCTAssertEqual(verifier.verify("参见粤03民终案件的裁判思路").status, .partial)
    XCTAssertEqual(verifier.verify("粤03民终").disposition, .attemptCompleteElseDiscard)
    // ❌ 无案号信号；「执行/执法」普通词不误报
    XCTAssertEqual(verifier.verify("本案应继续执行和解协议。").status, .missing)
    XCTAssertEqual(verifier.verify("被告应当承担违约责任。").status, .missing)
  }

  // MARK: - 分组源菜单模型

  func testMenuGroupsOrderAndCNKIDualEntries() {
    let text = "根据《中华人民共和国民法典》第五百七十七条，参见（2025）粤03民终8964号。"
    let anchors = FamoFactCoordinateExtractor.extract(from: text)
    let menu = FamoSelectionVerifyMenu.build(selectedText: text, anchors: anchors)

    XCTAssertEqual(menu.map(\.title), ["法规", "案例", "文献", "兜底"], "组序即菜单序")
    XCTAssertEqual(menu[0].items.map(\.title), ["国家法规库", "北大法宝"])
    XCTAssertEqual(menu[1].items.map(\.title), ["北大法宝", "无讼", "裁判文书网", "人民法院案例库"])
    XCTAssertEqual(menu[2].items.map(\.title),
                   ["知网·关键词", "知网·专业检索式", "维普", "万方", "百度学术"],
                   "知网双入口且关键词直达排首位（已拍板）")
    XCTAssertEqual(menu[3].items.map(\.title), ["必应", "百度"])

    // 法规组用法条锚点精准坐标；案例组用案号锚点
    XCTAssertEqual(menu[0].items[0].route.query, "《中华人民共和国民法典》第五百七十七条")
    XCTAssertEqual(menu[1].items[0].route.query, "（2025）粤03民终8964号")
    // 文献组无文献锚点 → 整段兜底（合并空白截断）
    XCTAssertEqual(menu[2].items[0].route.query,
                   FamoVerificationQueryRouter.normalizeSelection(text))

    // 知网·关键词 URL 必须带词（地址栏可见）；专业检索式 URL 必须无参、query 为检索式
    let kw = menu[2].items[0].route
    XCTAssertEqual(kw.url?.host, "kns.cnki.net")
    XCTAssertTrue(kw.url!.absoluteString.contains("?kw="), "知网关键词直达必须带词")
    let expert = menu[2].items[1].route
    XCTAssertEqual(expert.url, FamoCNKIExpertQueryBuilder.professionalSearchURL)
    XCTAssertNil(expert.url?.query)
    XCTAssertTrue(expert.query.hasPrefix("SU %= '"), "专业检索式经剪贴板交付")
    XCTAssertEqual(FamoSelectionVerifyClipboard.pasteQuery(openedRoutes: [kw, expert]), expert.query)

    // 法宝走必应 site: 兜底
    XCTAssertTrue(menu[0].items[1].route.url!.absoluteString.hasPrefix(
      "https://www.bing.com/search?q=site:pkulaw.com%20"))
  }

  func testMenuFallsBackToSelectionWithoutAnchorsAndEmptySelectionYieldsNothing() {
    let menu = FamoSelectionVerifyMenu.build(selectedText: "网络暴力的平台责任", anchors: [])
    XCTAssertEqual(menu.count, 4)
    XCTAssertTrue(menu.allSatisfy { group in
      group.items.allSatisfy { $0.route.query.contains("网络暴力的平台责任") }
    }, "无锚点时每组回退整段选区")
    XCTAssertTrue(FamoSelectionVerifyMenu.build(selectedText: "  \n ", anchors: []).isEmpty)
  }

  // MARK: - 徽标与状态归并

  func testOutcomeTagsAndKindBadges() {
    XCTAssertEqual(FamoVerificationOutcome.pending.tag, "[待核]")
    XCTAssertEqual(FamoVerificationOutcome.verified.tag, "[已核]")
    XCTAssertEqual(FamoVerificationOutcome.rejected.tag, "[已驳]")
    XCTAssertEqual(FamoVerificationOutcome(.verifiedLaw), .verified)
    XCTAssertEqual(FamoVerificationOutcome(.userConfirmed), .verified)
    XCTAssertEqual(FamoVerificationOutcome(.pending), .pending)
    XCTAssertEqual(FamoVerificationKind.law.badgeLabel, "法条")
    XCTAssertEqual(FamoVerificationKind.caseLaw.badgeLabel, "案例")
    XCTAssertEqual(FamoVerificationKind.scholarlyArticle.badgeLabel, "文献")
    XCTAssertEqual(FamoVerificationKind.officialDocument.badgeLabel, "文件")
  }
}
