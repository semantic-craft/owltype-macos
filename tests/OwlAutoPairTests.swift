//
//  OwlAutoPairTests.swift
//  OwltypeTests
//
//  自动配对括号 (task 07-02): the pure `OwlAutoPair` decision layer, the pref's live cached
//  flag, and the `OwlClientAction.insertTextInRange` value case. The execution half
//  (`commitApplyingAutoPair`) drives a real `IMKTextInput` client and stays real-machine
//  verified (headless `IMKInputController` can't be constructed — same limitation as the
//  rest of the controller; see owl-dependency-seams.md). The decision function carries all
//  the branching, so it is the unit-test body.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlAutoPairTests: XCTestCase {
  // MARK: - 开关关闭：一切 .plain

  func testDisabledIsAlwaysPlainForEveryInput() {
    for text in ["（", "）", "《", "》", "“", "”", "你好（", "a", ""] {
      XCTAssertEqual(
        OwlAutoPair.decision(enabled: false, commitText: text, rightNeighbor: "）", caretMoveAllowed: true),
        .plain,
        "disabled must be plain for \(text)"
      )
    }
  }

  // MARK: - 配对表：每类开括号 → .pair(开, 闭)

  func testEveryOpenerPairsWithItsExpectedCloser() {
    let expected: [(open: String, close: String)] = [
      ("（", "）"), ("【", "】"), ("《", "》"), ("〈", "〉"),
      ("「", "」"), ("『", "』"), ("〔", "〕"), ("“", "”"), ("‘", "’"),
      // ASCII 括号（成对输入扩展）——直引号故意不在表内。
      ("<", ">"), ("(", ")"), ("[", "]"), ("{", "}")
    ]
    // The table is exactly the PRD set (+ ASCII 括号) — no extra pairs sneak in.
    XCTAssertEqual(OwlAutoPair.pairs.count, expected.count)
    for pair in expected {
      XCTAssertEqual(
        OwlAutoPair.decision(enabled: true, commitText: pair.open, rightNeighbor: nil, caretMoveAllowed: true),
        .pair(open: pair.open, close: pair.close, caretMove: true),
        pair.open
      )
    }
  }

  // MARK: - 引号方向：“/‘ 开、”/’ 闭（rime-ice 交替输出零 yaml 改动的前提）

  func testQuoteOpenersPairAndQuoteClosersSkipOver() {
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "“", rightNeighbor: nil, caretMoveAllowed: true),
      .pair(open: "“", close: "”", caretMove: true)
    )
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "‘", rightNeighbor: nil, caretMoveAllowed: true),
      .pair(open: "‘", close: "’", caretMove: true)
    )
    // The alternation's closing quote right before an auto-paired one is swallowed…
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "”", rightNeighbor: "”", caretMoveAllowed: true),
      .skipOver(close: "”")
    )
    // …but a closing quote with anything else to the right stays plain.
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "”", rightNeighbor: "。", caretMoveAllowed: true),
      .plain
    )
  }

  // MARK: - skip-over 命中 / 未命中

  func testSkipOverFiresOnlyWhenRightNeighborIsTheSameCloser() {
    for close in ["）", "】", "》", "〉", "」", "』", "〕", "”", "’", ")", "]", "}", ">"] {
      XCTAssertEqual(
        OwlAutoPair.decision(enabled: true, commitText: close, rightNeighbor: close.first, caretMoveAllowed: false),
        .skipOver(close: close),
        close
      )
    }
    // Different neighbor / nil neighbor (read failed or end of document) → plain (= today's
    // duplicate-closer behavior, no damage).
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "）", rightNeighbor: "】", caretMoveAllowed: true),
      .plain
    )
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "）", rightNeighbor: nil, caretMoveAllowed: true),
      .plain
    )
  }

  // MARK: - caretMove policy

  func testCaretMoveFollowsPolicyDecision() {
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "（", rightNeighbor: nil, caretMoveAllowed: true),
      .pair(open: "（", close: "）", caretMove: true)
    )
    XCTAssertEqual(
      OwlAutoPair.decision(enabled: true, commitText: "（", rightNeighbor: nil, caretMoveAllowed: false),
      .pair(open: "（", close: "）", caretMove: false)
    )
  }

  // MARK: - 触发规则 v1：恰为配对表单字符

  func testOnlyExactSinglePairCharTriggers() {
    // Composed commit (组合提交), multi-char, empty, and non-pair chars all pass through.
    // `[` moved OUT of this list — it's now an ASCII pair opener; `=` stays a non-pair passthrough.
    for text in ["你好（", "（（", "（）", "", "a", "。", "你", "="] {
      XCTAssertEqual(
        OwlAutoPair.decision(enabled: true, commitText: text, rightNeighbor: "）", caretMoveAllowed: true),
        .plain,
        "must be plain for \(text)"
      )
    }
  }

  // MARK: - singleCloser 辅助（执行层用它决定是否发起右邻 IPC 读）

  func testSingleCloserHelper() {
    XCTAssertEqual(OwlAutoPair.singleCloser(in: "）"), "）")
    XCTAssertEqual(OwlAutoPair.singleCloser(in: "”"), "”")
    XCTAssertNil(OwlAutoPair.singleCloser(in: "（"))
    XCTAssertNil(OwlAutoPair.singleCloser(in: "））"))
    XCTAssertNil(OwlAutoPair.singleCloser(in: "你好）"))
    XCTAssertNil(OwlAutoPair.singleCloser(in: ""))
  }

  // MARK: - commit 顺序前提：空格 transform 对配对字符是恒等

  /// `commit(string:)` runs the spacing transform FIRST and decides auto-pair on the transformed
  /// text. That order is only inert because pair chars are neither CJK nor Latin/digit for the
  /// spacing boundary — lock that invariant here.
  func testCommitTransformIsIdentityOnPairTableChars() {
    for opener in OwlAutoPair.pairs.keys {
      let text = String(opener)
      XCTAssertEqual(
        OwlCommitTransform.apply(to: text, cjkEnglishSpacing: true, cjkNumberSpacing: true, previous: "字"),
        text, text
      )
      XCTAssertEqual(
        OwlCommitTransform.apply(to: text, cjkEnglishSpacing: true, cjkNumberSpacing: true, previous: "A"),
        text, text
      )
    }
  }

  // MARK: - OwlClientAction 新 case 的值语义

  func testInsertTextInRangeEquality() {
    let base = OwlClientAction.insertTextInRange("（", replacementRange: NSRange(location: 3, length: 1))
    let same = OwlClientAction.insertTextInRange("（", replacementRange: NSRange(location: 3, length: 1))
    let shifted = OwlClientAction.insertTextInRange("（", replacementRange: NSRange(location: 4, length: 1))
    XCTAssertEqual(base, same)
    XCTAssertNotEqual(base, shifted)
    XCTAssertNotEqual(OwlClientAction.insertText("（"), base)
  }

  // MARK: - 设置项：默认关 + cached flag 热生效、不触发任何 Rime apply

  func testAutoPairBracketsToggleIsLiveAndDoesNotTriggerAnyDeploy() {
    let key = "OwlKeyboardAutoPairBrackets"
    let saved = OwlDefaults.standard.object(forKey: key)
    defer {
      if let saved {
        OwlDefaults.standard.set(saved, forKey: key)
        OwlKeyboardPreferences.autoPairBrackets = (saved as? NSNumber)?.boolValue ?? true
      } else {
        OwlKeyboardPreferences.autoPairBrackets = true
        OwlDefaults.standard.removeObject(forKey: key)
      }
    }

    // Toggle ON via the exact action shape the 键盘输入 page uses — NO apply closure involved
    // (mirrors testCJKAlnumSpacingToggleIsLiveAndDoesNotTriggerAnyDeploy).
    let state = OwlSettingsState()
    OwlKeyboardPreferences.autoPairBrackets = false
    state.keyboardAutoPairBrackets = false
    OwlSettingsActions.toggle(state: state, keyPath: \.keyboardAutoPairBrackets) {
      OwlKeyboardPreferences.autoPairBrackets = $0
    }
    XCTAssertTrue(state.keyboardAutoPairBrackets)
    XCTAssertTrue(OwlKeyboardPreferences.autoPairBrackets)
    XCTAssertTrue(OwlDefaults.standard.bool(forKey: key))

    OwlSettingsActions.toggle(state: state, keyPath: \.keyboardAutoPairBrackets) {
      OwlKeyboardPreferences.autoPairBrackets = $0
    }
    XCTAssertFalse(state.keyboardAutoPairBrackets)
    XCTAssertFalse(OwlKeyboardPreferences.autoPairBrackets)
  }
}
