//
//  OwlPanelContentTests.swift
//  OwltypeTests — candidate-panel content-value dedup (B5)
//
//  Locks the pure `OwlPanelContent` that lets the candidate panel skip its two SwiftUI
//  layout passes when an `update(...)` is byte-identical to the one already on screen. The
//  correctness contract: identical inputs → equal signature (→ early-out); flipping ANY single
//  field — preedit, EACH `CandidateViewModel` rendering field (id/label/text/comment/badge/
//  source/provenance), highlightedIndex, page, hasPrevPage, hasNextPage, isVertical, schemaID,
//  or the caret anchor — → unequal signature (→ full render). The dedup must NEVER skip a
//  visible change, so this field-by-field test is the safety net.
//
//  Limitation (documented, accepted — same as the seam ports): the panel-level early-out itself
//  (`content == lastContent && settings == lastSettings && isVisible`) is NOT
//  headless-unit-testable — a non-activating `NSPanel`'s `isVisible`/`orderFront` can't be driven
//  deterministically without a window server / real machine. This signature-equality test (every
//  field flip → unequal) is the unit-level proof that the early-out only fires on a true no-op.
//

import AppKit
import XCTest
@testable import Owltype

final class OwlPanelContentTests: XCTestCase {

  // A representative two-candidate page. Each `make…` helper below mutates exactly one field
  // off this baseline so each assertion isolates a single rendering input.
  private func baselineCandidates() -> [CandidateViewModel] {
    [
      CandidateViewModel(id: 1, label: "1", text: "你好", comment: "nǐ hǎo",
                         badge: false, source: nil, provenance: .personal),
      CandidateViewModel(id: 2, label: "2", text: "拟好", comment: nil,
                         badge: true, source: "《民法典》第1条", provenance: .verified),
    ]
  }

  private func baseline() -> OwlPanelContent {
    OwlPanelContent(
      preedit: "nihao",
      cursor: 2,
      selStart: 0,
      selEnd: 2,
      candidates: baselineCandidates(),
      highlightedIndex: 0,
      page: 0,
      hasPrevPage: false,
      hasNextPage: true,
      isVertical: false,
      schemaID: "rime_ice",
      anchor: NSRect(x: 100, y: 200, width: 1, height: 18)
    )
  }

  // Build a signature differing from baseline only in `candidates`.
  private func signature(candidates: [CandidateViewModel]) -> OwlPanelContent {
    let b = baseline()
    return OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
  }

  // MARK: identical → equal

  func testIdenticalInputsAreEqual() {
    // Two independently-built signatures from the same inputs must be equal so the early-out
    // fires on a true no-op re-push.
    XCTAssertEqual(baseline(), baseline())
  }

  func testIdenticalCandidateArraysAreEqual() {
    // Fresh candidate value types (not the same instances) with identical fields stay equal.
    XCTAssertEqual(signature(candidates: baselineCandidates()),
                   signature(candidates: baselineCandidates()))
  }

  // MARK: top-level fields → flipping makes unequal

  func testPreeditChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: "nihaoa", cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testCursorChangeIsUnequal() {
    // A caret move (arrow keys editing the pinyin) with identical text + candidates must still
    // fall through to a full render so the blinking bar repaints at its new split point.
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor + 1, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHighlightSpanChangeIsUnequal() {
    // Moving the highlighted syllable (sel_start/sel_end) with identical text must repaint so the
    // active-syllable tint follows the caret.
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd + 1, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHighlightedIndexChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: 1,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testPageChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: 1, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHasPrevPageChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: true, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHasNextPageChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: false,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testIsVerticalChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: true, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testSchemaIDChangeIsUnequal() {
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: "wubi86_jidian", anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testAnchorChangeIsUnequal() {
    // Identical content at a MOVED caret must fall through to a full render so the panel
    // repositions — anchor is part of the signature by design (lazy-correct).
    let b = baseline()
    let other = OwlPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID,
      anchor: NSRect(x: 101, y: 200, width: 1, height: 18))
    XCTAssertNotEqual(b, other)
  }

  // MARK: per-candidate fields → flipping ANY one makes unequal

  func testCandidateCountChangeIsUnequal() {
    var cands = baselineCandidates()
    cands.removeLast()
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateOrderChangeIsUnequal() {
    // Array equality is order-sensitive: a reordered page renders differently.
    let cands = baselineCandidates().reversed().map { $0 }
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateIDChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: 99, label: c.label, text: c.text, comment: c.comment,
                                  badge: c.badge, source: c.source, provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateLabelChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: "9", text: c.text, comment: c.comment,
                                  badge: c.badge, source: c.source, provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateTextChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: c.label, text: "您好", comment: c.comment,
                                  badge: c.badge, source: c.source, provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateCommentChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: c.label, text: c.text, comment: "ní hǎo",
                                  badge: c.badge, source: c.source, provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateCommentNilVsValueIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: c.label, text: c.text, comment: nil,
                                  badge: c.badge, source: c.source, provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateBadgeChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: c.label, text: c.text, comment: c.comment,
                                  badge: true, source: c.source, provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateSourceChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[1]
    cands[1] = CandidateViewModel(id: c.id, label: c.label, text: c.text, comment: c.comment,
                                  badge: c.badge, source: "《民法典》第2条", provenance: c.provenance)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateProvenanceChangeIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: c.label, text: c.text, comment: c.comment,
                                  badge: c.badge, source: c.source, provenance: .ai)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  func testCandidateProvenanceNilVsValueIsUnequal() {
    var cands = baselineCandidates()
    let c = cands[0]
    cands[0] = CandidateViewModel(id: c.id, label: c.label, text: c.text, comment: c.comment,
                                  badge: c.badge, source: c.source, provenance: nil)
    XCTAssertNotEqual(signature(candidates: baselineCandidates()), signature(candidates: cands))
  }

  // MARK: 卷轴后页行 → part of the dedup signature

  func testScrollRowsChangeIsUnequal() {
    // A page-peek refresh with identical current-page content must still re-render so the
    // 后页行 repaint (e.g. the next page's contents changed after a user-dict learn).
    var other = baseline()
    other.scrollRows = [OwlScrollRow(id: 1, candidates: [CandidateViewModel(id: 8, label: "", text: "后页")])]
    XCTAssertNotEqual(baseline(), other)
  }

  func testIdenticalScrollRowsAreEqual() {
    var a = baseline()
    var b = baseline()
    let rows = [OwlScrollRow(id: 1, candidates: [CandidateViewModel(id: 8, label: "", text: "后页")])]
    a.scrollRows = rows
    b.scrollRows = rows
    XCTAssertEqual(a, b)
  }

  func testReplacingAnchorPreservesScrollRows() {
    // `reposition(anchor:)` rewrites the cached content via `replacing(anchor:)`; dropping
    // the 后页行 there would make the NEXT dedup comparison wrongly unequal (or the panel
    // repaint without them). Lock the field through the copy.
    var content = baseline()
    content.scrollRows = [OwlScrollRow(id: 1, candidates: [CandidateViewModel(id: 8, label: "", text: "后页")])]
    let moved = content.replacing(anchor: NSRect(x: 5, y: 6, width: 1, height: 18))
    XCTAssertEqual(moved.scrollRows, content.scrollRows)
    XCTAssertEqual(moved.anchor, NSRect(x: 5, y: 6, width: 1, height: 18))
  }
}

// MARK: - OwlScrollRowsPlan (pure gate + chunking)

final class OwlScrollRowsPlanTests: XCTestCase {

  /// A snapshot with everything the plan reads set explicitly; visual fields pinned to
  /// defaults (they are irrelevant to the gate but required by the memberwise init).
  private func snapshot(orientation: OwlPanelOrientation = .scroll,
                        scrollRows: Int = 2) -> OwlCandidatePanelSettings.Snapshot {
    OwlCandidatePanelSettings.Snapshot(
      appearance: .system,
      skin: .deepred,
      font: .systemDefault,
      animationsEnabled: true,
      size: .medium,
      orientation: orientation,
      showPreedit: true,
      inlineCandidate: false,
      showPaging: true,
      showNotificationsWhen: .always,
      candidateFormat: .full,
      scrollRows: scrollRows
    )
  }

  private func cand(_ text: String) -> RimeCandidate {
    RimeCandidate(text: text, comment: nil)
  }

  // MARK: gate

  func testWantsRowsOnScrollMidListAfterPaging() {
    XCTAssertTrue(OwlScrollRowsPlan.wantsRows(
      settings: snapshot(), didPage: true, lastPage: false, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  /// 翻页才展开（2026-07-28）：没翻过页的组字保持单行，即便选了卷轴、还有后页。
  func testNoPagingMeansNoRows() {
    XCTAssertFalse(OwlScrollRowsPlan.wantsRows(
      settings: snapshot(), didPage: false, lastPage: false, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
    XCTAssertFalse(OwlScrollRowsPlan.wantsPrevRow(
      settings: snapshot(), didPage: false, page: 1, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  func testLastPageNeverFetches() {
    XCTAssertFalse(OwlScrollRowsPlan.wantsRows(
      settings: snapshot(), didPage: true, lastPage: true, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  func testEmptyPageNeverFetches() {
    XCTAssertFalse(OwlScrollRowsPlan.wantsRows(
      settings: snapshot(), didPage: true, lastPage: false, candidateCount: 0,
      rimeVertical: false, schemaID: ""))
  }

  /// 非卷轴的三个方向都不取数——卷轴是唯一带前/后页行的形态（「预览后页」开关已被它吸收）。
  func testNonScrollOrientationsNeverFetch() {
    for orientation in [OwlPanelOrientation.auto, .horizontal, .vertical] {
      XCTAssertFalse(OwlScrollRowsPlan.wantsRows(
        settings: snapshot(orientation: orientation), didPage: true, lastPage: false,
        candidateCount: 5, rimeVertical: false, schemaID: ""), "\(orientation) 不该预取后页行")
      XCTAssertFalse(OwlScrollRowsPlan.wantsPrevRow(
        settings: snapshot(orientation: orientation), didPage: true, page: 1,
        candidateCount: 5, rimeVertical: false, schemaID: ""), "\(orientation) 不该预取前页行")
    }
  }

  /// 卷轴是横排的一种：即便 rime 方案自己要求竖排，选了卷轴仍按横排渲染并取数
  /// （`.scroll.isVertical` 恒为 false，与视图的渲染分支一致）。
  func testScrollIgnoresRimeVertical() {
    XCTAssertTrue(OwlScrollRowsPlan.wantsRows(
      settings: snapshot(), didPage: true, lastPage: false, candidateCount: 5,
      rimeVertical: true, schemaID: ""))
  }

  /// 前页行：翻过页且不在第一页才有（末页也算——那时只剩前页行 + 主行）；
  /// 翻回第一页就没有「上一页」可保留。
  func testPrevRowNeedsANonFirstPage() {
    XCTAssertTrue(OwlScrollRowsPlan.wantsPrevRow(
      settings: snapshot(), didPage: true, page: 1, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
    XCTAssertFalse(OwlScrollRowsPlan.wantsPrevRow(
      settings: snapshot(), didPage: true, page: 0, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  // MARK: chunking

  func testRowsChunksWholePages() {
    let rows = OwlScrollRowsPlan.rows(
      from: ["一", "二", "三", "四", "五", "六"].map(cand), pageSize: 3, startPage: 1)
    XCTAssertEqual(rows.map { $0.candidates.map(\.text) }, [["一", "二", "三"], ["四", "五", "六"]])
  }

  /// 行 id = librime 页号。这是卷轴动画的身份来源：翻页后同一页号的行必须仍是同一行，
  /// SwiftUI 才会把它动画成「上滚一格」而不是整块重建。
  func testRowIDIsThePageNumber() {
    let rows = OwlScrollRowsPlan.rows(
      from: ["一", "二", "三", "四"].map(cand), pageSize: 2, startPage: 3)
    XCTAssertEqual(rows.map(\.id), [3, 4])
  }

  /// 候选 id = 整张候选列表的绝对下标（页号 × 页大小 + 页内偏移），点击直接喂
  /// `select_candidate`。用页内偏移会选错词。
  func testCandidateIDsAreAbsolute() {
    let rows = OwlScrollRowsPlan.rows(
      from: ["一", "二", "三", "四"].map(cand), pageSize: 2, startPage: 3)
    XCTAssertEqual(rows.map { $0.candidates.map(\.id) }, [[6, 7], [8, 9]])
  }

  func testRowsKeepsPartialTailRow() {
    // 倒数第二页翻到尾部：后页不满一页也要整行显示（不丢、不补位）。
    let rows = OwlScrollRowsPlan.rows(
      from: ["一", "二", "三", "四"].map(cand), pageSize: 3, startPage: 1)
    XCTAssertEqual(rows.map { $0.candidates.map(\.text) }, [["一", "二", "三"], ["四"]])
  }

  func testRowsEmptyPeekMeansNoScrollRows() {
    XCTAssertTrue(OwlScrollRowsPlan.rows(from: [], pageSize: 5, startPage: 1).isEmpty)
  }

  func testRowsRenderTextWithComment() {
    // 前/后页行无序号（label 空）、无徽章/来源——序号只属于主行（数字键只选得中主行）；
    // 注释保留（码提示，2026-07-28 截图定案：信息密度与主行一致）。
    let rows = OwlScrollRowsPlan.rows(
      from: [RimeCandidate(text: "甲", comment: "wg"), cand("乙")], pageSize: 2, startPage: 1)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].candidates.map(\.label), ["", ""])
    XCTAssertEqual(rows[0].candidates.map(\.comment), ["wg", nil])
    XCTAssertEqual(rows[0].candidates.filter(\.badge), [])
  }

  func testRowsGuardsZeroPageSize() {
    XCTAssertTrue(OwlScrollRowsPlan.rows(from: [cand("甲")], pageSize: 0, startPage: 1).isEmpty)
  }
}

// MARK: - 候选窗尺寸四档

/// 设置层只定义候选正文的四档点数；完整面板尺寸由 resolved geometry interface 验收。
final class OwlPanelSizeTests: XCTestCase {

  /// 四档点数 16 / 19 / 23 / 27。小/中/大三个值与四档化之前逐字相同——`.extraLarge` 是纯增补，
  /// rawValue 也没动，所以老用户存在 `"OwlPanelFontSize"` 里的选择不需要任何迁移。
  func testFourStepLadder() {
    XCTAssertEqual(OwlPanelFontSize.allCases.map(\.base), [16, 19, 23, 27])
    XCTAssertEqual(OwlPanelFontSize.allCases.map(\.rawValue),
                   ["small", "medium", "large", "extraLarge"])
  }

  /// 面板状态的默认字号就是中档：留白现在也从这个数派生，默认档一错整块面板的边距跟着错。
  func testPanelStateDefaultsToMediumStep() {
    XCTAssertEqual(CandidatePanelState().fontSize, OwlPanelFontSize.medium.base)
  }
}

// MARK: - 候选窗 resolved geometry

/// 这里锁的是视图实际消费的组合结果，而不是再次复述内部的缩放公式。
/// 每一档都同时覆盖字号、输入串/首候选对齐、选中块、最小宽度、翻页与展开 affordance。
final class OwlCandidatePanelGeometryTests: XCTestCase {

  private struct Expected {
    let size: OwlPanelFontSize
    let minimumWidth: CGFloat
    let selectionInset: CGFloat
    let selectionRadius: CGFloat
    let headerSpacing: CGFloat
    let headerLeading: CGFloat
    let headerTrailing: CGFloat
    let headerTop: CGFloat
    let headerBottom: CGFloat
    let rowSpacing: CGFloat
    let pagerSpacing: CGFloat
    let pillHorizontal: CGFloat
    let pillVertical: CGFloat
    let chevronFont: CGFloat
    let chevronHitPadding: CGFloat
    let collapseClearance: CGFloat
  }

  private let expected: [Expected] = [
    Expected(size: .small, minimumWidth: 177, selectionInset: 4, selectionRadius: 9,
             headerSpacing: 7, headerLeading: 11, headerTrailing: 7, headerTop: 8, headerBottom: 4,
             rowSpacing: 0, pagerSpacing: 5, pillHorizontal: 7, pillVertical: 6,
             chevronFont: 11, chevronHitPadding: 3, collapseClearance: 22),
    Expected(size: .medium, minimumWidth: 210, selectionInset: 5, selectionRadius: 8,
             headerSpacing: 8, headerLeading: 13, headerTrailing: 8, headerTop: 9, headerBottom: 5,
             rowSpacing: 0, pagerSpacing: 6, pillHorizontal: 8, pillVertical: 7,
             chevronFont: 14, chevronHitPadding: 4, collapseClearance: 28),
    Expected(size: .large, minimumWidth: 254, selectionInset: 6, selectionRadius: 7,
             headerSpacing: 10, headerLeading: 16, headerTrailing: 10, headerTop: 11, headerBottom: 6,
             rowSpacing: 0, pagerSpacing: 7, pillHorizontal: 10, pillVertical: 8,
             chevronFont: 18, chevronHitPadding: 5, collapseClearance: 35),
    Expected(size: .extraLarge, minimumWidth: 298, selectionInset: 7, selectionRadius: 6,
             headerSpacing: 11, headerLeading: 18, headerTrailing: 11, headerTop: 13, headerBottom: 7,
             rowSpacing: 0, pagerSpacing: 9, pillHorizontal: 11, pillVertical: 10,
             chevronFont: 22, chevronHitPadding: 6, collapseClearance: 43),
  ]

  func testFourSizesResolveTheCompleteHorizontalComposition() {
    for want in expected {
      let geometry = OwlCandidatePanelGeometry(
        candidateFontSize: want.size.base,
        panelCornerRadius: 13
      )

      XCTAssertEqual(geometry.minimumWidth, want.minimumWidth, want.size.rawValue)
      XCTAssertEqual(geometry.selectionInset, want.selectionInset, want.size.rawValue)
      XCTAssertEqual(geometry.selectionRadius, want.selectionRadius, want.size.rawValue)

      XCTAssertEqual(geometry.header.preeditFontSize, want.size.base - 3, want.size.rawValue)
      XCTAssertEqual(geometry.header.spacing, want.headerSpacing, want.size.rawValue)
      XCTAssertEqual(geometry.header.leadingPadding, want.headerLeading, want.size.rawValue)
      XCTAssertEqual(geometry.header.trailingPadding, want.headerTrailing, want.size.rawValue)
      XCTAssertEqual(geometry.header.topPadding, want.headerTop, want.size.rawValue)
      XCTAssertEqual(geometry.header.bottomPadding, want.headerBottom, want.size.rawValue)

      XCTAssertEqual(geometry.compactRow.inset, want.selectionInset, want.size.rawValue)
      XCTAssertEqual(geometry.mainRow.spacing, want.rowSpacing, want.size.rawValue)
      XCTAssertEqual(geometry.mainRow.pagerSpacing, want.pagerSpacing, want.size.rawValue)
      XCTAssertEqual(geometry.compactPill.candidateFontSize, want.size.base + 1, want.size.rawValue)
      XCTAssertEqual(geometry.compactPill.secondaryFontSize, want.size.base * 0.72, accuracy: 0.0001,
                     want.size.rawValue)
      XCTAssertEqual(geometry.compactPill.horizontalPadding, want.pillHorizontal, want.size.rawValue)
      XCTAssertEqual(geometry.compactPill.verticalPadding, want.pillVertical, want.size.rawValue)

      XCTAssertEqual(geometry.expandChevron.fontSize, want.chevronFont, want.size.rawValue)
      XCTAssertEqual(geometry.expandChevron.hitPadding, want.chevronHitPadding, want.size.rawValue)
      XCTAssertEqual(geometry.collapseClearance, want.collapseClearance, want.size.rawValue)
    }
  }

  func testHeaderAndAffordancesKeepTheirCompositionInvariants() {
    for size in OwlPanelFontSize.allCases {
      let geometry = OwlCandidatePanelGeometry(
        candidateFontSize: size.base,
        panelCornerRadius: 13
      )

      // 输入串和首候选文字从面板左壁起使用同一条 resolved 路径。
      XCTAssertEqual(
        geometry.header.leadingPadding,
        geometry.compactRow.inset + geometry.compactPill.horizontalPadding,
        size.rawValue
      )

      // HStack 为展开按钮保留完整命中宽与前导间距；overlay 形态还会额外保留右壁净空。
      XCTAssertEqual(
        geometry.expandChevronReservedWidth,
        geometry.mainRow.expandChevronLeadingPadding + geometry.expandChevron.hitWidth,
        size.rawValue
      )
      XCTAssertEqual(
        geometry.collapseClearance,
        geometry.expandChevron.hitWidth + geometry.verticalList.collapseTrailingPadding,
        size.rawValue
      )
    }
  }

  func testRowPillAndAffordanceSpacingStayOnTheFourSizeTable() {
    let contentSpacing: [CGFloat] = [4, 5, 6, 7]
    let dividerPadding: [CGFloat] = [4, 5, 6, 7]
    let chevronLeading: [CGFloat] = [3, 4, 5, 6]
    let pageDotsTrailing: [CGFloat] = [3, 4, 5, 6]
    let provenanceHorizontal: [CGFloat] = [3, 4, 5, 6]
    let provenanceVertical: [CGFloat] = [3, 3, 4, 4]

    for (index, size) in OwlPanelFontSize.allCases.enumerated() {
      let geometry = OwlCandidatePanelGeometry(
        candidateFontSize: size.base,
        panelCornerRadius: 13
      )
      XCTAssertEqual(geometry.compactPill.contentSpacing, contentSpacing[index], size.rawValue)
      XCTAssertEqual(geometry.mainRow.dividerHorizontalPadding, dividerPadding[index], size.rawValue)
      XCTAssertEqual(geometry.mainRow.expandChevronLeadingPadding, chevronLeading[index], size.rawValue)
      XCTAssertEqual(geometry.pageDots.trailingPadding, pageDotsTrailing[index], size.rawValue)
      XCTAssertEqual(
        geometry.compactPill.provenance.horizontalPadding,
        provenanceHorizontal[index],
        size.rawValue
      )
      XCTAssertEqual(
        geometry.compactPill.provenance.verticalPadding,
        provenanceVertical[index],
        size.rawValue
      )
    }
  }

  func testHairlineAndPagingHitAreaStayFixedAcrossAllSizes() {
    for size in OwlPanelFontSize.allCases {
      let geometry = OwlCandidatePanelGeometry(
        candidateFontSize: size.base,
        panelCornerRadius: 13
      )
      XCTAssertEqual(geometry.panel.spacing, 0, size.rawValue)
      XCTAssertEqual(geometry.panel.cornerRadius, 13, size.rawValue)
      XCTAssertEqual(geometry.panel.strokeWidth, 1, size.rawValue)
      XCTAssertEqual(geometry.mainRow.dividerWidth, 1, size.rawValue)
      XCTAssertEqual(geometry.mainRow.dividerHeight, size.base * 0.9, size.rawValue)
      XCTAssertEqual(geometry.pageDots.spacing, 0, size.rawValue)
      XCTAssertEqual(geometry.pageDots.hitSize, 18, size.rawValue)
      XCTAssertEqual(geometry.pageDots.dotDiameter, 5, size.rawValue)
      XCTAssertEqual(geometry.header.pieceSpacing, 0, size.rawValue)
      XCTAssertEqual(geometry.header.kerning, 0.4, size.rawValue)
      XCTAssertEqual(geometry.header.spacerMinimumLength, 2, size.rawValue)
      XCTAssertEqual(geometry.header.delimiterHorizontalPadding, 0, size.rawValue)
      XCTAssertEqual(geometry.verticalHeader.delimiterHorizontalPadding, 0, size.rawValue)
      XCTAssertEqual(geometry.header.caretHorizontalPadding, 0.5, size.rawValue)
      XCTAssertEqual(geometry.header.caret.cornerRadius, 1, size.rawValue)
      XCTAssertEqual(geometry.header.caret.width, 1.5, size.rawValue)
      XCTAssertEqual(geometry.header.caret.minimumHeight, 8, size.rawValue)
      XCTAssertEqual(geometry.compactPill.provenance.cornerRadius, 5, size.rawValue)
      XCTAssertEqual(geometry.listRow.badge.cornerRadius, 5, size.rawValue)
      XCTAssertEqual(geometry.listRow.provenance.cornerRadius, 5, size.rawValue)
    }
  }

  func testFourSizesResolveVerticalAndScrollCompositions() {
    let verticalMinimumWidth: [CGFloat] = [64, 76, 92, 108]
    let verticalHeaderLeading: [CGFloat] = [12, 14, 17, 20]
    let verticalHeaderTop: [CGFloat] = [6, 7, 8, 10]
    let verticalHeaderBottom: [CGFloat] = [5, 6, 7, 9]
    let listContentSpacing: [CGFloat] = [3, 3, 4, 4]
    let listItemSpacing: [CGFloat] = [6, 7, 8, 10]
    let listHorizontalPadding: [CGFloat] = [8, 9, 11, 13]
    let listVerticalPadding: [CGFloat] = [6, 7, 8, 10]
    let scrollStackSpacing: [CGFloat] = [4, 5, 6, 7]
    let collapseTopPadding: [CGFloat] = [2, 2, 2, 3]

    for (index, size) in OwlPanelFontSize.allCases.enumerated() {
      let geometry = OwlCandidatePanelGeometry(
        candidateFontSize: size.base,
        panelCornerRadius: 13
      )

      XCTAssertEqual(geometry.verticalList.minimumWidth, verticalMinimumWidth[index], size.rawValue)
      XCTAssertEqual(geometry.verticalList.spacing, 0, size.rawValue)
      XCTAssertEqual(geometry.verticalList.inset, geometry.selectionInset, size.rawValue)
      XCTAssertEqual(geometry.verticalList.hairlineHeight, 1, size.rawValue)
      XCTAssertEqual(geometry.verticalList.collapseTopPadding, collapseTopPadding[index], size.rawValue)

      XCTAssertEqual(geometry.verticalHeader.preeditFontSize, size.base - 3, size.rawValue)
      XCTAssertEqual(geometry.verticalHeader.leadingPadding, verticalHeaderLeading[index], size.rawValue)
      XCTAssertEqual(geometry.verticalHeader.topPadding, verticalHeaderTop[index], size.rawValue)
      XCTAssertEqual(geometry.verticalHeader.bottomPadding, verticalHeaderBottom[index], size.rawValue)

      XCTAssertEqual(geometry.listRow.contentSpacing, listContentSpacing[index], size.rawValue)
      XCTAssertEqual(geometry.listRow.itemSpacing, listItemSpacing[index], size.rawValue)
      XCTAssertEqual(geometry.listRow.candidateFontSize, size.base, size.rawValue)
      XCTAssertEqual(geometry.listRow.labelFontSize, size.base * 0.9, accuracy: 0.0001, size.rawValue)
      XCTAssertEqual(geometry.listRow.badge.fontSize, size.base * 0.68, accuracy: 0.0001,
                     size.rawValue)
      XCTAssertEqual(geometry.listRow.commentFontSize, size.base * 0.8, accuracy: 0.0001, size.rawValue)
      XCTAssertEqual(geometry.listRow.horizontalPadding, listHorizontalPadding[index], size.rawValue)
      XCTAssertEqual(geometry.listRow.verticalPadding, listVerticalPadding[index], size.rawValue)
      XCTAssertEqual(geometry.listRow.sourceLine.fontSize, size.base * 0.78, accuracy: 0.0001,
                     size.rawValue)

      XCTAssertEqual(geometry.scrollStack.spacing, scrollStackSpacing[index], size.rawValue)
      XCTAssertEqual(geometry.scrollStack.inset, geometry.selectionInset, size.rawValue)
      // 卷轴前/后页行与主行是同一张网格的相邻行：候选间隔差一点点都会逐列累加成错位，
      // 所以锁的是「与主行同值」这条不变式，而不是某个具体点数。
      XCTAssertEqual(geometry.scrollRow.spacing, geometry.mainRow.spacing, size.rawValue)
      XCTAssertEqual(geometry.scrollPill.contentSpacing, geometry.compactPill.contentSpacing,
                     size.rawValue)
      XCTAssertEqual(geometry.scrollPill.candidateFontSize, geometry.compactPill.candidateFontSize,
                     size.rawValue)
      XCTAssertEqual(geometry.scrollPill.secondaryFontSize, geometry.compactPill.secondaryFontSize,
                     accuracy: 0.0001, size.rawValue)
      XCTAssertEqual(geometry.scrollPill.horizontalPadding, geometry.compactPill.horizontalPadding,
                     size.rawValue)
      XCTAssertEqual(geometry.scrollPill.verticalPadding, geometry.compactPill.verticalPadding,
                     size.rawValue)

      // 序号槽是内容量出来的，不由字号解析：不传就是 0（= 本次不显示序号），传了原样带走。
      // 主行的序号和前/后页行的空槽都读这一个数，列才不会因为两处各自量算而错开。
      XCTAssertEqual(geometry.labelSlotWidth, 0, size.rawValue)
      XCTAssertEqual(
        OwlCandidatePanelGeometry(
          candidateFontSize: size.base, panelCornerRadius: 13, labelSlotWidth: 12.5
        ).labelSlotWidth,
        12.5,
        size.rawValue
      )
    }
  }

  func testVerticalHeaderSourceLineAndCollapseKeepClearanceInvariants() {
    for size in OwlPanelFontSize.allCases {
      let geometry = OwlCandidatePanelGeometry(
        candidateFontSize: size.base,
        panelCornerRadius: 13
      )

      // 输入串与候选文字从面板左壁起严格共线。
      XCTAssertEqual(
        geometry.verticalHeader.leadingPadding,
        geometry.verticalList.inset + geometry.listRow.horizontalPadding,
        size.rawValue
      )

      // 来源行从序号列之后起笔，不会压到序号；字号与行内组合一次解析。
      XCTAssertEqual(
        geometry.listRow.sourceLine.leadingPadding,
        geometry.listRow.labelFontSize + geometry.listRow.itemSpacing,
        accuracy: 0.0001,
        size.rawValue
      )

      // 收起按钮命中区之外仍保留一个 selectionInset，第一行选中块不会被 overlay 截走。
      XCTAssertEqual(
        geometry.collapseClearance,
        geometry.expandChevron.hitWidth + geometry.verticalList.collapseTrailingPadding,
        size.rawValue
      )
      let gap = geometry.verticalList.inset + geometry.collapseClearance
        - geometry.verticalList.collapseTrailingPadding - geometry.expandChevron.hitWidth
      XCTAssertEqual(gap, geometry.selectionInset, size.rawValue)
    }
  }
}

/// 序号槽宽度（方案 A 的对齐地基）。卷轴的前/后页行留出与主行序号同宽的空槽，各行
/// 候选文字才落在同一条左边界上；这里锁住那个宽度的取法。
final class OwlCandidateLabelSlotTests: XCTestCase {
  func testNoLabelsOrNoFontMeansNoSlot() {
    // 「仅候选」预设下视图传空数组：两侧都没有槽，照样对齐。
    XCTAssertEqual(OwlCandidateLabelSlot.width(labels: [], fontSize: 13.68), 0)
    XCTAssertEqual(OwlCandidateLabelSlot.width(labels: ["1", "2"], fontSize: 0), 0)
  }

  func testSlotTakesTheWidestLabel() {
    let digits = (1...8).map(String.init)
    // page_size ≤ 9 的常态：全是等宽数字，一位数就定下了槽宽。
    XCTAssertEqual(
      OwlCandidateLabelSlot.width(labels: digits, fontSize: 13.68),
      OwlCandidateLabelSlot.width(labels: ["8"], fontSize: 13.68)
    )
    // schema 自定义 select_labels 时按最宽的一个留，短的那些不会被挤出去。
    XCTAssertGreaterThan(
      OwlCandidateLabelSlot.width(labels: ["1", "wide"], fontSize: 13.68),
      OwlCandidateLabelSlot.width(labels: ["1"], fontSize: 13.68)
    )
  }

  func testSlotScalesWithFontSizeAndLandsOnWholePoints() {
    let small = OwlCandidateLabelSlot.width(labels: ["8"], fontSize: 11.52)   // 小档 16 * 0.72
    let large = OwlCandidateLabelSlot.width(labels: ["8"], fontSize: 19.44)   // 特大档 27 * 0.72
    XCTAssertGreaterThan(small, 0)
    XCTAssertGreaterThan(large, small)
    // 向上取整到整点：半点宽度会让主行序号和空槽落在不同的像素边界上。
    XCTAssertEqual(small, small.rounded(.up))
    XCTAssertEqual(large, large.rounded(.up))
  }
}
