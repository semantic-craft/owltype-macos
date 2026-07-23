//
//  RimeCompositionRendererTests.swift
//  FamoTests — C3 (task 07-05-famo-composition-render-seam)
//
//  Characterization tests for `RimeCompositionRenderer.markedText`, the pure byte→UTF-16 +
//  inline-candidate-preview math moved VERBATIM out of `FamoInputController+RimeUpdate`.
//  Pure: feed a fabricated `RimeComposition`, assert the `RimeMarkedText` — no NSPanel, no
//  librime. Expected values are hand-computed from the librime byte offsets; they lock the
//  extraction so a future regression in the index math fails here.
//
//  The four branches are `inlineCandidate × inlinePreedit`. Two cases deliberately make
//  `caretPos` (into the shown candidate preview) diverge from `preeditCaretUTF16` (into the
//  raw preedit, for the Snapshot cursor) — the reason the renderer returns both.
//

import Foundation
import XCTest
@testable import Famo

final class RimeCompositionRendererTests: XCTestCase {

  /// Composition with only the fields `markedText` reads; candidates/labels are irrelevant here.
  private func comp(preedit: String, selStart: Int, selEnd: Int, cursorPos: Int,
                    commitTextPreview: String? = nil) -> RimeComposition {
    RimeComposition(
      preedit: preedit, selStart: selStart, selEnd: selEnd, cursorPos: cursorPos,
      commitTextPreview: commitTextPreview, candidates: [], labels: [],
      pageNo: 0, pageSize: 5, isLastPage: true, highlightedIndex: 0, numCandidates: 0)
  }

  // MARK: - Branch: !inlineCandidate && inlinePreedit (raw preedit as marked text)

  func test_pureASCII_inlinePreedit() {
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "nihao", selStart: 0, selEnd: 5, cursorPos: 5),
      inlinePreedit: true, inlineCandidate: false)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "nihao", selRange: NSRange(location: 0, length: 5),
                                     caretPos: 5, preeditCaretUTF16: 5,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 5))
  }

  func test_CJK_byteToUTF16_inlinePreedit() {
    // "你好" = 6 UTF-8 bytes, 2 UTF-16 units. selEnd/cursor byte-6 → UTF-16 offset 2.
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "你好", selStart: 0, selEnd: 6, cursorPos: 6),
      inlinePreedit: true, inlineCandidate: false)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "你好", selRange: NSRange(location: 0, length: 2),
                                     caretPos: 2, preeditCaretUTF16: 2,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  func test_CJKLatinMix_selectionInUTF16() {
    // "你好a": 你(bytes0-2) 好(3-5) a(6). Select 你好 (bytes 0..6) → UTF-16 (0,2), caret 2.
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "你好a", selStart: 0, selEnd: 6, cursorPos: 6),
      inlinePreedit: true, inlineCandidate: false)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "你好a", selRange: NSRange(location: 0, length: 2),
                                     caretPos: 2, preeditCaretUTF16: 2,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  // MARK: - Branch: !inlineCandidate && !inlinePreedit (full-shape space placeholder)

  func test_nonInlinePreedit_fullShapeSpace() {
    // Shown preedit collapses to U+3000; but the Snapshot cursor still tracks the raw preedit.
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "ceshi", selStart: 0, selEnd: 5, cursorPos: 5),
      inlinePreedit: false, inlineCandidate: false)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "　", selRange: NSRange(location: 0, length: 0),
                                     caretPos: 0, preeditCaretUTF16: 5,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 5))
  }

  func test_emptyPreedit_nonInline() {
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "", selStart: 0, selEnd: 0, cursorPos: 0),
      inlinePreedit: false, inlineCandidate: false)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "", selRange: NSRange(location: 0, length: 0),
                                     caretPos: 0, preeditCaretUTF16: 0,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 0))
  }

  // MARK: - Branch: inlineCandidate && inlinePreedit (candidate preview + appended remaining code)

  func test_inlineCandidate_inlinePreedit_appendsRemainingCode_caretDiverges() {
    // preedit "abXY": select ab (0..2), caret at byte 2 (before remaining "XY"), preview "C".
    // → candidatePreview "C" + "XY" = "CXY"; caret re-anchors to end of preview ("C" → offset 1);
    //   Snapshot cursor stays at the raw-preedit caret (offset 2). caretPos(1) ≠ preeditCaretUTF16(2).
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "abXY", selStart: 0, selEnd: 2, cursorPos: 2, commitTextPreview: "C"),
      inlinePreedit: true, inlineCandidate: true)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "CXY", selRange: NSRange(location: 0, length: 3),
                                     caretPos: 1, preeditCaretUTF16: 2,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  func test_inlineCandidate_caretBeforeSelection_noAppend() {
    // caret at start (byte 0) → append guard false; caret stays at preview start.
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "ab", selStart: 0, selEnd: 2, cursorPos: 0, commitTextPreview: "CD"),
      inlinePreedit: true, inlineCandidate: true)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "CD", selRange: NSRange(location: 0, length: 2),
                                     caretPos: 0, preeditCaretUTF16: 0,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  func test_inlineCandidate_nilPreview_appendsRemaining_caretDiverges() {
    // nil commitTextPreview → preview "" ; inlinePreedit appends "XY". caret → end of "" (0);
    // Snapshot cursor at raw caret (2). Another caretPos(0) ≠ preeditCaretUTF16(2).
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "abXY", selStart: 0, selEnd: 2, cursorPos: 2, commitTextPreview: nil),
      inlinePreedit: true, inlineCandidate: true)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "XY", selRange: NSRange(location: 0, length: 2),
                                     caretPos: 0, preeditCaretUTF16: 2,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  // MARK: - Branch: inlineCandidate && !inlinePreedit (preview only, no remaining-code append)

  func test_inlineCandidate_nonInlinePreedit_noAppend() {
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "abXY", selStart: 0, selEnd: 2, cursorPos: 2, commitTextPreview: "CD"),
      inlinePreedit: false, inlineCandidate: true)
    XCTAssertEqual(marked, RimeMarkedText(preedit: "CD", selRange: NSRange(location: 0, length: 2),
                                     caretPos: 2, preeditCaretUTF16: 2,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  // MARK: - #89 keep-alive（合成期 marked text 永不空；zws 进入/不进入条件）

  func test_keepAlive_inlineCandidate_emptyPreview_composing_yieldsZWS() {
    // 组码中（raw preedit 非空）但渲染产物空：inlineCandidate + 空 preview + 无尾码
    // （!inlinePreedit 分支不追加剩余码）→ 唯一能在合成期产出空串的分支 → zws 兜底。
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "ab", selStart: 0, selEnd: 2, cursorPos: 2, commitTextPreview: ""),
      inlinePreedit: false, inlineCandidate: true)
    XCTAssertEqual(marked, RimeMarkedText(preedit: RimeCompositionRenderer.compositionKeepAlive,
                                     selRange: NSRange(location: 0, length: 0),
                                     caretPos: 0, preeditCaretUTF16: 2,
                                     preeditSelStartUTF16: 0, preeditSelEndUTF16: 2))
  }

  func test_keepAlive_inlineCandidate_nilPreview_caretAtEnd_yieldsZWS() {
    // inlinePreedit=true 但光标在 preedit 末端（无剩余码可追加）+ nil preview → 渲染空 → zws。
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "ab", selStart: 0, selEnd: 2, cursorPos: 2, commitTextPreview: nil),
      inlinePreedit: true, inlineCandidate: true)
    XCTAssertEqual(marked.preedit, RimeCompositionRenderer.compositionKeepAlive)
    XCTAssertEqual(marked.preeditCaretUTF16, 2)
  }

  func test_keepAlive_notInjected_whenRawPreeditEmpty() {
    // raw preedit 空（闲置 / ESC / 删空收尾轮）：渲染必须保持空串——这是客户端 marked text
    // 的清理路径；zws 在此注入 = 往宿主里撒零宽字符 + ESC 永远清不掉（P0 缺陷面，锁死）。
    for (inlinePreedit, inlineCandidate) in [(true, false), (false, false), (true, true), (false, true)] {
      let marked = RimeCompositionRenderer.markedText(
        composition: comp(preedit: "", selStart: 0, selEnd: 0, cursorPos: 0, commitTextPreview: nil),
        inlinePreedit: inlinePreedit, inlineCandidate: inlineCandidate)
      XCTAssertEqual(marked.preedit, "",
                     "raw-empty round must render empty (inlinePreedit=\(inlinePreedit), inlineCandidate=\(inlineCandidate))")
    }
  }

  func test_keepAlive_notInjected_whenRenderedNonEmpty() {
    // 非空产出不受影响：no_inline 的全角空格占位原样保留（U+3000，非 zws）。
    let marked = RimeCompositionRenderer.markedText(
      composition: comp(preedit: "ceshi", selStart: 0, selEnd: 5, cursorPos: 5),
      inlinePreedit: false, inlineCandidate: false)
    XCTAssertEqual(marked.preedit, "　")
  }

  // MARK: - #90（G1）keep-alive 非空 = autoPair commit 门在 zws 回合保持关闭的承重不变量

  func test_keepAlive_isNonEmpty_soAutoPairCommitGateStaysClosedDuringZWSRound() {
    // autoPair 的 commit 门（FamoInputController+RimeUpdate.swift `commitApplyingAutoPair`）读
    // `self.preedit.isEmpty` 决定是否做右邻 IPC 几何读。#89 后 `self.preedit` 在「引擎组码中但
    // 渲染空」回合持有本 keep-alive；门保持关闭（plain 降级、不在活合成期做 IPC 读）的**唯一**
    // 依据 = keep-alive 非空。若有人把它改成空串，该门会静默重开 = #89 前的 bug（面③回归入口）。
    // 这条断言直接锁死那个跨 seam 依赖，与 RimeUpdate 里的门代码互为文档。
    XCTAssertFalse(RimeCompositionRenderer.compositionKeepAlive.isEmpty)
    XCTAssertEqual(RimeCompositionRenderer.compositionKeepAlive, "\u{200B}")
  }
}
