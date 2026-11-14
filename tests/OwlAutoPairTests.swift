//
//  OwlAutoPairTests.swift
//  OwltypeTests
//

import Foundation
import XCTest
@testable import Owltype

final class OwlAutoPairTests: XCTestCase {
  func testPairsTableContainsExpectedChineseAndASCIIBracketsWithoutStraightQuotes() {
    let expected: [Character: Character] = [
      "（": "）", "【": "】", "《": "》", "〈": "〉",
      "「": "」", "『": "』", "〔": "〕", "“": "”", "‘": "’",
      "<": ">", "(": ")", "[": "]", "{": "}"
    ]
    XCTAssertEqual(OwlAutoPair.pairs, expected)
    for straight in [Character("\""), "'", "`"] {
      XCTAssertNil(OwlAutoPair.pairs[straight])
    }
    XCTAssertEqual(OwlAutoPair.chinesePairs["〖"], "〗")
    XCTAssertEqual(OwlAutoPair.reopenings, [
      "”": "“",
      "’": "‘",
      "」": "「",
      "』": "『"
    ])
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
