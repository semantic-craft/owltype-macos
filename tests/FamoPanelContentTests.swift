//
//  FamoPanelContentTests.swift
//  FamoTests — candidate-panel content-value dedup (B5)
//
//  Locks the pure `FamoPanelContent` that lets the candidate panel skip its two SwiftUI
//  layout passes when an `update(...)` is byte-identical to the one already on screen. The
//  correctness contract: identical inputs → equal signature (→ early-out); flipping ANY single
//  field — preedit, EACH `CandidateViewModel` rendering field (id/label/text/comment/badge/
//  source/provenance), highlightedIndex, page, hasPrevPage, hasNextPage, isVertical, schemaID,
//  or the caret anchor — → unequal signature (→ full render). The dedup must NEVER skip a
//  visible change, so this field-by-field test is the safety net.
//
//  Limitation (documented, accepted — same as the seam ports): the panel-level early-out itself
//  (`if content == lastContent && prefs == lastPrefs && isVisible { orderFrontRegardless(); return }`) is NOT
//  headless-unit-testable — a non-activating `NSPanel`'s `isVisible`/`orderFront` can't be driven
//  deterministically without a window server / real machine. This signature-equality test (every
//  field flip → unequal) is the unit-level proof that the early-out only fires on a true no-op.
//

import AppKit
import XCTest
@testable import Famo

final class FamoPanelContentTests: XCTestCase {

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

  private func baseline() -> FamoPanelContent {
    FamoPanelContent(
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
  private func signature(candidates: [CandidateViewModel]) -> FamoPanelContent {
    let b = baseline()
    return FamoPanelContent(
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
    let other = FamoPanelContent(
      preedit: "nihaoa", cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testCursorChangeIsUnequal() {
    // A caret move (arrow keys editing the pinyin) with identical text + candidates must still
    // fall through to a full render so the blinking bar repaints at its new split point.
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor + 1, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHighlightSpanChangeIsUnequal() {
    // Moving the highlighted syllable (sel_start/sel_end) with identical text must repaint so the
    // active-syllable tint follows the caret.
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd + 1, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHighlightedIndexChangeIsUnequal() {
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: 1,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testPageChangeIsUnequal() {
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: 1, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHasPrevPageChangeIsUnequal() {
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: true, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testHasNextPageChangeIsUnequal() {
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: false,
      isVertical: b.isVertical, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testIsVerticalChangeIsUnequal() {
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: true, schemaID: b.schemaID, anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testSchemaIDChangeIsUnequal() {
    let b = baseline()
    let other = FamoPanelContent(
      preedit: b.preedit, cursor: b.cursor, selStart: b.selStart, selEnd: b.selEnd, candidates: b.candidates, highlightedIndex: b.highlightedIndex,
      page: b.page, hasPrevPage: b.hasPrevPage, hasNextPage: b.hasNextPage,
      isVertical: b.isVertical, schemaID: "wubi86_jidian", anchor: b.anchor)
    XCTAssertNotEqual(b, other)
  }

  func testAnchorChangeIsUnequal() {
    // Identical content at a MOVED caret must fall through to a full render so the panel
    // repositions — anchor is part of the signature by design (lazy-correct).
    let b = baseline()
    let other = FamoPanelContent(
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
    other.scrollRows = [FamoScrollRow(id: 1, candidates: [CandidateViewModel(id: 8, label: "", text: "后页")])]
    XCTAssertNotEqual(baseline(), other)
  }

  func testIdenticalScrollRowsAreEqual() {
    var a = baseline()
    var b = baseline()
    let rows = [FamoScrollRow(id: 1, candidates: [CandidateViewModel(id: 8, label: "", text: "后页")])]
    a.scrollRows = rows
    b.scrollRows = rows
    XCTAssertEqual(a, b)
  }

  func testReplacingAnchorPreservesScrollRows() {
    // `reposition(anchor:)` rewrites the cached content via `replacing(anchor:)`; dropping
    // the 后页行 there would make the NEXT dedup comparison wrongly unequal (or the panel
    // repaint without them). Lock the field through the copy.
    var content = baseline()
    content.scrollRows = [FamoScrollRow(id: 1, candidates: [CandidateViewModel(id: 8, label: "", text: "后页")])]
    let moved = content.replacing(anchor: NSRect(x: 5, y: 6, width: 1, height: 18))
    XCTAssertEqual(moved.scrollRows, content.scrollRows)
    XCTAssertEqual(moved.anchor, NSRect(x: 5, y: 6, width: 1, height: 18))
  }
}

// MARK: - FamoScrollRowsPlan (pure gate + chunking)

final class FamoScrollRowsPlanTests: XCTestCase {

  /// A snapshot with everything the plan reads set explicitly; visual fields pinned to
  /// defaults (they are irrelevant to the gate but required by the memberwise init).
  private func snapshot(orientation: FamoPanelOrientation = .scroll,
                        scrollRows: Int = 2) -> FamoPanelSnapshot {
    FamoPanelSnapshot(
      orientation: orientation,
      fontSize: .medium,
      fontDesign: .default,
      animationsEnabled: true,
      showPreedit: true,
      showPaging: true,
      candidateFormat: .full,
      theme: .shenda,
      appearance: .system,
      scrollRows: scrollRows)
  }

  private func cand(_ text: String) -> RimeCandidate {
    RimeCandidate(text: text, comment: nil)
  }

  // MARK: gate

  func testWantsRowsOnScrollMidListAfterPaging() {
    XCTAssertTrue(FamoScrollRowsPlan.wantsRows(
      prefs: snapshot(), didPage: true, lastPage: false, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  /// 翻页才展开（2026-07-28）：没翻过页的组字保持单行，即便选了卷轴、还有后页。
  func testNoPagingMeansNoRows() {
    XCTAssertFalse(FamoScrollRowsPlan.wantsRows(
      prefs: snapshot(), didPage: false, lastPage: false, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
    XCTAssertFalse(FamoScrollRowsPlan.wantsPrevRow(
      prefs: snapshot(), didPage: false, page: 1, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  func testLastPageNeverFetches() {
    XCTAssertFalse(FamoScrollRowsPlan.wantsRows(
      prefs: snapshot(), didPage: true, lastPage: true, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  func testEmptyPageNeverFetches() {
    XCTAssertFalse(FamoScrollRowsPlan.wantsRows(
      prefs: snapshot(), didPage: true, lastPage: false, candidateCount: 0,
      rimeVertical: false, schemaID: ""))
  }

  /// 非卷轴的三个方向都不取数——卷轴是唯一带前/后页行的形态（「预览后页」开关已被它吸收）。
  func testNonScrollOrientationsNeverFetch() {
    for orientation in [FamoPanelOrientation.auto, .horizontal, .vertical] {
      XCTAssertFalse(FamoScrollRowsPlan.wantsRows(
        prefs: snapshot(orientation: orientation), didPage: true, lastPage: false,
        candidateCount: 5, rimeVertical: false, schemaID: ""), "\(orientation) 不该预取后页行")
      XCTAssertFalse(FamoScrollRowsPlan.wantsPrevRow(
        prefs: snapshot(orientation: orientation), didPage: true, page: 1,
        candidateCount: 5, rimeVertical: false, schemaID: ""), "\(orientation) 不该预取前页行")
    }
  }

  /// 卷轴是横排的一种：即便 rime 方案自己要求竖排，选了卷轴仍按横排渲染并取数
  /// （`.scroll.isVertical` 恒为 false，与视图的渲染分支一致）。
  func testScrollIgnoresRimeVertical() {
    XCTAssertTrue(FamoScrollRowsPlan.wantsRows(
      prefs: snapshot(), didPage: true, lastPage: false, candidateCount: 5,
      rimeVertical: true, schemaID: ""))
  }

  /// 前页行：翻过页且不在第一页才有（末页也算——那时只剩前页行 + 主行）；
  /// 翻回第一页就没有「上一页」可保留。
  func testPrevRowNeedsANonFirstPage() {
    XCTAssertTrue(FamoScrollRowsPlan.wantsPrevRow(
      prefs: snapshot(), didPage: true, page: 1, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
    XCTAssertFalse(FamoScrollRowsPlan.wantsPrevRow(
      prefs: snapshot(), didPage: true, page: 0, candidateCount: 5,
      rimeVertical: false, schemaID: ""))
  }

  // MARK: chunking

  func testRowsChunksWholePages() {
    let rows = FamoScrollRowsPlan.rows(
      from: ["一", "二", "三", "四", "五", "六"].map(cand), pageSize: 3, startPage: 1)
    XCTAssertEqual(rows.map { $0.candidates.map(\.text) }, [["一", "二", "三"], ["四", "五", "六"]])
  }

  /// 行 id = librime 页号。这是卷轴动画的身份来源：翻页后同一页号的行必须仍是同一行，
  /// SwiftUI 才会把它动画成「上滚一格」而不是整块重建。
  func testRowIDIsThePageNumber() {
    let rows = FamoScrollRowsPlan.rows(
      from: ["一", "二", "三", "四"].map(cand), pageSize: 2, startPage: 3)
    XCTAssertEqual(rows.map(\.id), [3, 4])
  }

  /// 候选 id = 整张候选列表的绝对下标（页号 × 页大小 + 页内偏移），点击直接喂
  /// `select_candidate`。用页内偏移会选错词。
  func testCandidateIDsAreAbsolute() {
    let rows = FamoScrollRowsPlan.rows(
      from: ["一", "二", "三", "四"].map(cand), pageSize: 2, startPage: 3)
    XCTAssertEqual(rows.map { $0.candidates.map(\.id) }, [[6, 7], [8, 9]])
  }

  func testRowsKeepsPartialTailRow() {
    // 倒数第二页翻到尾部：后页不满一页也要整行显示（不丢、不补位）。
    let rows = FamoScrollRowsPlan.rows(
      from: ["一", "二", "三", "四"].map(cand), pageSize: 3, startPage: 1)
    XCTAssertEqual(rows.map { $0.candidates.map(\.text) }, [["一", "二", "三"], ["四"]])
  }

  func testRowsEmptyPeekMeansNoScrollRows() {
    XCTAssertTrue(FamoScrollRowsPlan.rows(from: [], pageSize: 5, startPage: 1).isEmpty)
  }

  func testRowsRenderTextWithComment() {
    // 前/后页行无序号（label 空）、无徽章/来源——序号只属于主行（数字键只选得中主行）；
    // 注释保留（码提示，2026-07-28 截图定案：信息密度与主行一致）。
    let rows = FamoScrollRowsPlan.rows(
      from: [RimeCandidate(text: "甲", comment: "wg"), cand("乙")], pageSize: 2, startPage: 1)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].candidates.map(\.label), ["", ""])
    XCTAssertEqual(rows[0].candidates.map(\.comment), ["wg", nil])
    XCTAssertEqual(rows[0].candidates.filter(\.badge), [])
  }

  func testRowsGuardsZeroPageSize() {
    XCTAssertTrue(FamoScrollRowsPlan.rows(from: [cand("甲")], pageSize: 0, startPage: 1).isEmpty)
  }
}
