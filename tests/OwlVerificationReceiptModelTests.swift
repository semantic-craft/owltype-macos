//
//  OwlVerificationReceiptModelTests.swift
//  OwltypeTests — 核验回执卡状态模型 (issue #135, 方案三「朱印」)
//
//  断言真实行为（教训：只断写出的文本是假覆盖）：注入 verifier/openURL/pasteboard 闭包，
//  验证 ①案号准入闸真过滤 ②状态机真落盘（含取消丢弃迟到结果）③跳库「先 open 后复制」
//  的事件顺序与剪贴板纪律 ④toast 逐字 ⑤回执文本与计数 ⑥键盘焦点钳位。无网络、无真剪贴板。
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class OwlVerificationReceiptModelTests: XCTestCase {

  private enum Event: Equatable {
    case open(String)
    case copy(String)
  }

  private final class Recorder {
    var events: [Event] = []
  }

  private func makeModel(
    text: String = "根据《中华人民共和国民法典》第五百七十七条，参见（2025）粤03民终8964号。",
    onlineVerifyAvailable: Bool = true,
    verifier: @escaping (String) async throws -> OwlSourceVerificationOutcome = { _ in
      OwlSourceVerificationOutcome(content: "", sources: [])
    },
    recorder: Recorder = Recorder()
  ) -> (OwlVerificationReceiptModel, Recorder) {
    let anchors = OwlVerificationReceiptModel.admittedAnchors(from: text, currentYear: 2026)
    let model = OwlVerificationReceiptModel(
      selectedText: text,
      anchors: anchors,
      onlineVerifyAvailable: onlineVerifyAvailable,
      verifier: verifier,
      openURL: { recorder.events.append(.open($0.absoluteString)) },
      writePasteboard: { recorder.events.append(.copy($0)) },
      now: { Date(timeIntervalSince1970: 1_784_450_000) }
    )
    return (model, recorder)
  }

  // MARK: - 案号准入闸

  func testAdmittedAnchorsKeepLawAndValidCaseNumber() {
    let anchors = OwlVerificationReceiptModel.admittedAnchors(
      from: "根据《中华人民共和国民法典》第五百七十七条，参见（2025）粤03民终8964号。",
      currentYear: 2026)
    XCTAssertEqual(anchors.map(\.kind), [.law, .caseLaw])
    XCTAssertEqual(anchors[0].label, "《中华人民共和国民法典》第五百七十七条")
    XCTAssertEqual(anchors[1].label, "（2025）粤03民终8964号")
  }

  func testAdmittedAnchorsDropFabricatedCaseNumber() {
    // 年份 2077 > currentYear：形状对但年份非法 → 疑似杜撰 → 闸下（显示前必过）。
    let anchors = OwlVerificationReceiptModel.admittedAnchors(
      from: "参见（2077）粤03民终8964号；另见《个人信息保护法》第24条。",
      currentYear: 2026)
    XCTAssertEqual(anchors.map(\.kind), [.law], "疑似杜撰案号不得进待核清单")
  }

  // MARK: - 结果 → 行状态映射

  func testVerifyMapsNoSourcesAndEmptyResponseToNotFound() async {
    let (emptyModel, _) = makeModel(verifier: { _ in
      OwlSourceVerificationOutcome(content: "只有摘要没有来源", sources: [])
    })
    let emptyLaw = emptyModel.anchors[0]
    emptyModel.verify(emptyLaw)
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(emptyModel.state(for: emptyLaw), .notFound)

    let (missingModel, _) = makeModel(verifier: { _ in
      throw OwlSourceVerificationError.emptyResponse
    })
    let missingLaw = missingModel.anchors[0]
    missingModel.verify(missingLaw)
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(
      missingModel.state(for: missingLaw), .notFound,
      "搜不到 ≠ 不存在：emptyResponse 落 notFound 而非 error")
  }

  func testVerifyMapsOtherErrorsToError() async {
    let (model, _) = makeModel(verifier: { _ in
      throw OwlSourceVerificationError.badHTTPStatus(503)
    })
    let law = model.anchors[0]
    model.verify(law)
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(model.state(for: law), .error("来源核验请求失败（503）"))
  }

  // MARK: - 状态机（真落盘）

  func testVerifyCommitsSuccessAndExpandsGreenCard() async {
    let (model, _) = makeModel(verifier: { _ in
      OwlSourceVerificationOutcome(
        content: "已核验",
        sources: [OwlVerifiedSource(title: "民法典", url: "https://flk.npc.gov.cn/detail2.html?x")])
    })
    let law = model.anchors[0]
    model.verify(law)
    XCTAssertEqual(model.state(for: law), .loading)
    try? await Task.sleep(nanoseconds: 200_000_000)
    guard case .success(let source) = model.state(for: law) else {
      return XCTFail("verifier 返回来源后状态必须真落 success，实际 \(model.state(for: law))")
    }
    XCTAssertEqual(source.url, "https://flk.npc.gov.cn/detail2.html?x")
    XCTAssertEqual(source.provider, "flk.npc.gov.cn")
    XCTAssertEqual(source.snippet, "已核验")
    XCTAssertEqual(model.expanded[law.id], true, "绿卡默认展开")
    XCTAssertTrue(model.hasOutcome)
    XCTAssertEqual(model.verifiedCount, 1)
  }

  func testCancelDiscardsLateResult() async {
    let (model, _) = makeModel(verifier: { _ in
      try await Task.sleep(nanoseconds: 500_000_000)
      return OwlSourceVerificationOutcome(
        content: "", sources: [OwlVerifiedSource(title: "迟到", url: "https://x.com")])
    })
    let law = model.anchors[0]
    model.verify(law)
    model.cancel(law)
    XCTAssertEqual(model.state(for: law), .idle)
    try? await Task.sleep(nanoseconds: 700_000_000)
    XCTAssertEqual(model.state(for: law), .idle, "取消后的迟到结果不得覆盖视图")
  }

  func testVerifyDisabledWhenOnlineVerifyUnavailable() {
    let (model, _) = makeModel(onlineVerifyAvailable: false)
    model.verify(model.anchors[0])
    XCTAssertEqual(model.state(for: model.anchors[0]), .idle, "无联网核验能力时不得发起请求")
  }

  func testConfirmPromotesSuccessToConfirmed() async {
    let (model, _) = makeModel(verifier: { _ in
      OwlSourceVerificationOutcome(
        content: "", sources: [OwlVerifiedSource(title: "t", url: "https://flk.npc.gov.cn/a")])
    })
    let law = model.anchors[0]
    model.verify(law)
    try? await Task.sleep(nanoseconds: 200_000_000)
    model.confirm(law)
    guard case .confirmed = model.state(for: law) else {
      return XCTFail("确认[已核]后必须落 confirmed")
    }
  }

  // MARK: - 跳库：先 open 后复制 + 剪贴板纪律 + 逐字 toast

  func testOpenCNKIExpertRouteOpensThenCopiesWithVerbatimToast() {
    let (model, recorder) = makeModel()
    let route = OwlVerificationRoute(
      kind: .deepLink, source: .cnki,
      query: "SU %= '惩罚性赔偿'",
      url: URL(string: "https://kns.cnki.net/kns8s/AdvSearch")!)
    model.open(route)
    XCTAssertEqual(recorder.events, [
      .open("https://kns.cnki.net/kns8s/AdvSearch"),
      .copy("SU %= '惩罚性赔偿'"),
    ], "必须先 open 后复制")
    XCTAssertEqual(model.toastText, "知网检索式已复制，切到「专业检索」粘贴即可")
  }

  func testOpenDirectRouteLeavesClipboardUntouched() {
    let (model, recorder) = makeModel()
    let route = OwlVerificationQueryRouter.route(query: "惩罚性赔偿研究", source: .cnki)
    model.open(route)
    XCTAssertEqual(recorder.events.count, 1)
    guard case .open(let url) = recorder.events[0] else { return XCTFail("应只打开 URL") }
    XCTAssertTrue(url.hasPrefix("https://kns.cnki.net/kns8s/defaultresult/index?kw="))
    XCTAssertNil(model.toastText, "URL 自带词 → 不动剪贴板、不弹 toast")
  }

  func testOpenAllForManualVerifyCopiesThenOpensTwoTabsPerAnchor() {
    let (model, recorder) = makeModel()
    model.openAllForManualVerify()
    // 每锚点：①复制检索词 ②百度学术 direct ③法宝 bing site:（spec §1.7）。
    XCTAssertEqual(recorder.events.count, model.anchors.count * 3)
    guard case .copy(let firstQuery) = recorder.events[0] else { return XCTFail("先复制") }
    XCTAssertEqual(firstQuery, model.anchors[0].query)
    guard case .open(let scholar) = recorder.events[1] else { return XCTFail("再开百度学术") }
    XCTAssertTrue(scholar.hasPrefix("https://xueshu.baidu.com/s?wd="))
    guard case .open(let pkulaw) = recorder.events[2] else { return XCTFail("后开法宝") }
    XCTAssertTrue(pkulaw.hasPrefix("https://www.bing.com/search?q=site:pkulaw.com%20"),
                  "法宝必须走必应 site: 兜底，实际 \(pkulaw)")
  }

  // MARK: - 分组源菜单 / chips

  func testJumpGroupsUseAnchorCoordinateForMatchingGroup() {
    let (model, _) = makeModel()
    let law = model.anchors[0]
    let groups = model.jumpGroups(for: law)
    XCTAssertEqual(groups.map(\.title), ["法规", "案例", "文献", "兜底"])
    let lawGroup = groups[0]
    XCTAssertTrue(lawGroup.items.allSatisfy { $0.route.query == law.query },
                  "法规组必须用法条坐标当检索词")
  }

  func testManualChipItemsIncludeRelatedGroupPlusBingFallback() {
    let (model, _) = makeModel()
    let law = model.anchors[0]
    let titles = model.manualChipItems(for: law).map(\.title)
    XCTAssertEqual(titles, ["国家法规库", "北大法宝", "必应"])
  }

  // MARK: - 回执文本与副标题

  func testReceiptTextCarriesBadgesAndCounts() async {
    let (model, _) = makeModel(verifier: { query in
      query.contains("民法典")
        ? OwlSourceVerificationOutcome(
            content: "", sources: [OwlVerifiedSource(title: "民法典", url: "https://flk.npc.gov.cn/a")])
        : OwlSourceVerificationOutcome(content: "", sources: [])
    })
    model.verifyAll()
    try? await Task.sleep(nanoseconds: 300_000_000)
    let text = model.receiptText()
    XCTAssertTrue(text.contains("[已核] 《中华人民共和国民法典》第五百七十七条（法条）"))
    XCTAssertTrue(text.contains("[待核] （2025）粤03民终8964号（案例） — 未能通过联网核实（搜不到 ≠ 不存在）"))
    XCTAssertTrue(text.contains("已核 1 · 待核 1 · 疑似杜撰 0"))
  }

  func testSubtitleFollowsStateFlow() async {
    let (model, _) = makeModel(verifier: { _ in
      try await Task.sleep(nanoseconds: 150_000_000)
      return OwlSourceVerificationOutcome(content: "", sources: [])
    })
    XCTAssertEqual(model.subtitle, "已抽取 2 个待核锚点 · 右键更多源")
    model.verifyAll()
    XCTAssertEqual(model.subtitle, "正在联网核验…")
    try? await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertTrue(model.subtitle.hasPrefix("核验完成 · "), "结果态副标题：\(model.subtitle)")
    XCTAssertTrue(model.subtitle.hasSuffix("已核 0 / 待核 2"))
  }

  func testLawNotFoundCountsAsSuspected() async {
    let (model, _) = makeModel(verifier: { _ in
      OwlSourceVerificationOutcome(content: "", sources: [])
    })
    model.verifyAll()
    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(model.suspectedCount, 1, "法条搜不到 → 疑似杜撰计数")
  }

  // MARK: - 键盘焦点

  func testMoveFocusClampsToAnchorRange() {
    let (model, _) = makeModel()
    XCTAssertEqual(model.focusedIndex, 0)
    model.moveFocus(-1)
    XCTAssertEqual(model.focusedIndex, 0)
    model.moveFocus(1)
    XCTAssertEqual(model.focusedIndex, 1)
    model.moveFocus(1)
    XCTAssertEqual(model.focusedIndex, 1)
  }
}
