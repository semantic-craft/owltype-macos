//
//  FamoM3EmojiSkinTests.swift
//  FamoTests — M3 emoji/symbol + skin preset smoke checks
//

import XCTest
@testable import Famo

final class FamoM3EmojiSkinTests: XCTestCase {
  private let recentKey = "FamoEmojiRecent"
  private let skinKey = "FamoSkin"
  private let candidateEmojiKey = "FamoEmojiInCandidates"
  private var oldRecents: [String]?
  private var oldSkin: String?
  private var oldCandidateEmoji: Any?

  override func setUp() {
    super.setUp()
    oldRecents = FamoDefaults.standard.stringArray(forKey: recentKey)
    oldSkin = FamoDefaults.standard.string(forKey: skinKey)
    oldCandidateEmoji = FamoDefaults.standard.object(forKey: candidateEmojiKey)
    FamoDefaults.standard.removeObject(forKey: recentKey)
    FamoDefaults.standard.removeObject(forKey: skinKey)
    FamoDefaults.standard.removeObject(forKey: candidateEmojiKey)
  }

  override func tearDown() {
    restore(oldRecents, forKey: recentKey)
    restore(oldSkin, forKey: skinKey)
    restore(oldCandidateEmoji, forKey: candidateEmojiKey)
    super.tearDown()
  }

  func testEmojiSearchCoversWritingSymbolsAndKeywords() {
    XCTAssertTrue(FamoEmojiData.search("书名号").contains { $0.char == "《》" })
    XCTAssertTrue(FamoEmojiData.search("section").contains { $0.char == "§" })
    XCTAssertTrue(FamoEmojiData.search("笑").contains { $0.char == "😀" })
  }

  func testRecentsDeduplicateAndCap() {
    for n in 0..<20 { _ = FamoEmojiRecents.push("x\(n)") }
    _ = FamoEmojiRecents.push("x10")

    let recents = FamoEmojiRecents.current()
    XCTAssertEqual(recents.first, "x10")
    XCTAssertEqual(recents.count, 14)
    XCTAssertEqual(recents.filter { $0 == "x10" }.count, 1)
  }

  func testEmojiPreferencesAndLocalCategories() {
    // 候选 emoji 开关默认关（出厂 schema reset 1→0）；面板「启用」开关已移除——面板常驻输入法菜单栏。
    XCTAssertFalse(FamoEmojiPreferences.candidateEmojiEnabled)
    FamoEmojiPreferences.candidateEmojiEnabled = true
    XCTAssertTrue(FamoEmojiPreferences.candidateEmojiEnabled)

    XCTAssertTrue(FamoEmojiData.items(for: .kaomoji).contains { $0.char == "¯\\_(ツ)_/¯" })
    XCTAssertTrue(FamoEmojiData.search("摊手").contains { $0.char == "¯\\_(ツ)_/¯" })
  }

  func testDeepredIsTheDefaultSkin() {
    XCTAssertEqual(FamoSkinPreferences.skin, .deepred)
    FamoSkinPreferences.skin = .wuda
    XCTAssertEqual(FamoSkinPreferences.skin, .wuda)
  }

  // MARK: - Status HUD message-type selection (reproduces legacy FamoPanel.updateStatus)

  /// `.mix` shows the short label when present, else the long label.
  func testStatusHUDMixPrefersShortElseLong() {
    XCTAssertEqual(FamoStatusMessageType.mix.message(long: "简体中文", short: "简"), "简")
    XCTAssertEqual(FamoStatusMessageType.mix.message(long: "简体中文", short: ""), "简体中文")
  }

  /// `.long` always shows the long label.
  func testStatusHUDLongAlwaysLong() {
    XCTAssertEqual(FamoStatusMessageType.long.message(long: "简体中文", short: "简"), "简体中文")
    XCTAssertEqual(FamoStatusMessageType.long.message(long: "简体中文", short: ""), "简体中文")
  }

  /// `.short` shows the short label, else the first character of long, else "".
  func testStatusHUDShortFallsBackToInitialThenEmpty() {
    XCTAssertEqual(FamoStatusMessageType.short.message(long: "简体中文", short: "简"), "简")
    XCTAssertEqual(FamoStatusMessageType.short.message(long: "简体中文", short: ""), "简")
    XCTAssertEqual(FamoStatusMessageType.short.message(long: "", short: ""), "")
  }

  /// Default message type matches the legacy `FamoTheme.statusMessageType` default (.mix).
  func testStatusHUDDefaultMessageTypeIsMix() {
    XCTAssertEqual(FamoStyleFlags().statusMessageType, .mix)
  }

  private func restore(_ value: [String]?, forKey key: String) {
    if let value {
      FamoDefaults.standard.set(value, forKey: key)
    } else {
      FamoDefaults.standard.removeObject(forKey: key)
    }
  }

  private func restore(_ value: String?, forKey key: String) {
    if let value {
      FamoDefaults.standard.set(value, forKey: key)
    } else {
      FamoDefaults.standard.removeObject(forKey: key)
    }
  }

  private func restore(_ value: Any?, forKey key: String) {
    if let value {
      FamoDefaults.standard.set(value, forKey: key)
    } else {
      FamoDefaults.standard.removeObject(forKey: key)
    }
  }
}
