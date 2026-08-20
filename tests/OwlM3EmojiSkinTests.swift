//
//  OwlM3EmojiSkinTests.swift
//  OwltypeTests — M3 emoji/symbol + skin preset smoke checks
//

import XCTest
@testable import Owltype

final class OwlM3EmojiSkinTests: XCTestCase {
  private let recentKey = "OwlEmojiRecent"
  private let skinKey = "OwlSkin"
  private let candidateEmojiKey = "OwlEmojiInCandidates"
  private var oldRecents: [String]?
  private var oldSkin: String?
  private var oldCandidateEmoji: Any?

  override func setUp() {
    super.setUp()
    oldRecents = OwlDefaults.standard.stringArray(forKey: recentKey)
    oldSkin = OwlDefaults.standard.string(forKey: skinKey)
    oldCandidateEmoji = OwlDefaults.standard.object(forKey: candidateEmojiKey)
    OwlDefaults.standard.removeObject(forKey: recentKey)
    OwlDefaults.standard.removeObject(forKey: skinKey)
    OwlDefaults.standard.removeObject(forKey: candidateEmojiKey)
  }

  override func tearDown() {
    restore(oldRecents, forKey: recentKey)
    restore(oldSkin, forKey: skinKey)
    restore(oldCandidateEmoji, forKey: candidateEmojiKey)
    super.tearDown()
  }

  func testEmojiSearchCoversWritingSymbolsAndKeywords() {
    XCTAssertTrue(OwlEmojiData.search("书名号").contains { $0.char == "《》" })
    XCTAssertTrue(OwlEmojiData.search("section").contains { $0.char == "§" })
    XCTAssertTrue(OwlEmojiData.search("笑").contains { $0.char == "😀" })
  }

  func testRecentsDeduplicateAndCap() {
    for n in 0..<20 { _ = OwlEmojiRecents.push("x\(n)") }
    _ = OwlEmojiRecents.push("x10")

    let recents = OwlEmojiRecents.current()
    XCTAssertEqual(recents.first, "x10")
    XCTAssertEqual(recents.count, 14)
    XCTAssertEqual(recents.filter { $0 == "x10" }.count, 1)
  }

  func testEmojiPreferencesAndLocalCategories() {
    // 候选 emoji 开关默认关（出厂 schema reset 1→0）；面板「启用」开关已移除——面板常驻输入法菜单栏。
    XCTAssertFalse(OwlEmojiPreferences.candidateEmojiEnabled)
    OwlEmojiPreferences.candidateEmojiEnabled = true
    XCTAssertTrue(OwlEmojiPreferences.candidateEmojiEnabled)

    XCTAssertTrue(OwlEmojiData.items(for: .kaomoji).contains { $0.char == "¯\\_(ツ)_/¯" })
    XCTAssertTrue(OwlEmojiData.search("摊手").contains { $0.char == "¯\\_(ツ)_/¯" })
  }

  func testDeepredIsTheDefaultSkin() {
    let settings = OwlCandidatePanelSettings.live
    let state = OwlSettingsState()
    XCTAssertEqual(settings.snapshot().skin, .deepred)
    settings.edit(.skin(.wuda), state: state, onChange: {})
    XCTAssertEqual(settings.snapshot().skin, .wuda)
  }

  // MARK: - Status HUD message-type selection (reproduces legacy OwlPanel.updateStatus)

  /// `.mix` shows the short label when present, else the long label.
  func testStatusHUDMixPrefersShortElseLong() {
    XCTAssertEqual(OwlStatusMessageType.mix.message(long: "简体中文", short: "简"), "简")
    XCTAssertEqual(OwlStatusMessageType.mix.message(long: "简体中文", short: ""), "简体中文")
  }

  /// `.long` always shows the long label.
  func testStatusHUDLongAlwaysLong() {
    XCTAssertEqual(OwlStatusMessageType.long.message(long: "简体中文", short: "简"), "简体中文")
    XCTAssertEqual(OwlStatusMessageType.long.message(long: "简体中文", short: ""), "简体中文")
  }

  /// `.short` shows the short label, else the first character of long, else "".
  func testStatusHUDShortFallsBackToInitialThenEmpty() {
    XCTAssertEqual(OwlStatusMessageType.short.message(long: "简体中文", short: "简"), "简")
    XCTAssertEqual(OwlStatusMessageType.short.message(long: "简体中文", short: ""), "简")
    XCTAssertEqual(OwlStatusMessageType.short.message(long: "", short: ""), "")
  }

  /// Default message type matches the legacy `OwlTheme.statusMessageType` default (.mix).
  func testStatusHUDDefaultMessageTypeIsMix() {
    XCTAssertEqual(OwlStyleFlags().statusMessageType, .mix)
  }

  private func restore(_ value: [String]?, forKey key: String) {
    if let value {
      OwlDefaults.standard.set(value, forKey: key)
    } else {
      OwlDefaults.standard.removeObject(forKey: key)
    }
  }

  private func restore(_ value: String?, forKey key: String) {
    if let value {
      OwlDefaults.standard.set(value, forKey: key)
    } else {
      OwlDefaults.standard.removeObject(forKey: key)
    }
  }

  private func restore(_ value: Any?, forKey key: String) {
    if let value {
      OwlDefaults.standard.set(value, forKey: key)
    } else {
      OwlDefaults.standard.removeObject(forKey: key)
    }
  }
}
