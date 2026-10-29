//
//  OwlKeyboardSettingsCatalogTests.swift
//  OwltypeTests
//
//  One parity check over every keyboard switch: defaults agree, a stored value seeds back
//  into the settings state, and every engine option is a name the Rust FFI handles.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlKeyboardSettingsCatalogTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "im.owltype.inputmethod.Owltype.catalog-tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  /// Keys and defaults that shipped before the catalog. They are user data: a row may be added,
  /// but none of these may be renamed or change default.
  private let shipped: [String: Bool] = [
    "OwlKeyboardWubiAutoCommitUnique": true, "OwlKeyboardWubiFifthCodeTopCommit": true,
    "OwlKeyboardWubiCodeHint": true, "OwlKeyboardWubiZWildcard": false,
    "OwlKeyboardWubiAutoClear": false, "OwlKeyboardWubiZReverseLookup": true,
    "OwlKeyboardWubiEnglishChannel": false, "OwlKeyboardWubiUserDictLearning": true,
    "OwlKeyboardPinyinQuickPhraseCandidates": false, "OwlKeyboardCJKPunctToggle": false,
    "OwlKeyboardShiftSwitchCJK": true, "OwlKeyboardGoodOldCapsLock": true,
    "OwlKeyboardPageMinusEquals": true, "OwlKeyboardPageBrackets": true,
    "OwlKeyboardPageCommaPeriod": false, "OwlKeyboardSelect23Semicolon": false,
    "OwlKeyboardSlashSymbolMenu": false, "OwlKeyboardAngleSymbolMenu": false,
    "OwlKeyboardTraditionalOutput": false, "OwlKeyboardDefaultAsciiMode": false,
    "OwlKeyboardDefaultFullShape": false, "OwlKeyboardAutoPairBrackets": true,
    "OwlKeyboardSmartPunctuation": true, "OwlKeyboardSmartPunctuationRepeat": true,
    "OwlKeyboardSmartPunctuationSpace": false, "OwlKeyboardCJKEnglishSpacing": false,
    "OwlKeyboardCJKNumberSpacing": false,
  ]

  func testEverySwitchHasOneDefaultSharedByCatalogAndSettingsState() {
    let catalog = OwlKeyboardSettingsCatalog(defaults: defaults)
    let state = OwlSettingsState()
    let keys = OwlKeyboardSwitch.allCases.map(\.key)
    XCTAssertEqual(Set(keys).count, keys.count, "two switches share a UserDefaults key")
    let mirrors = Set(OwlKeyboardSwitch.allCases.map(\.row.mirror))
    XCTAssertEqual(mirrors.count, keys.count, "two switches share a settings-state mirror")

    for toggle in OwlKeyboardSwitch.allCases {
      XCTAssertEqual(state[keyPath: toggle.row.mirror], toggle.defaultValue, "\(toggle) state default")
      XCTAssertEqual(catalog.load(toggle), toggle.defaultValue, "\(toggle) unwritten key reads its default")
      if let shippedDefault = shipped[toggle.key] {
        XCTAssertEqual(toggle.defaultValue, shippedDefault, "\(toggle) changed a shipped default")
      }
    }
    XCTAssertTrue(Set(keys).isSuperset(of: shipped.keys), "a shipped key was renamed or dropped")
  }

  func testStoredValuesSeedBackIntoSettingsStateAndStayPlainBools() {
    var refreshed: [OwlKeyboardSwitch: Bool] = [:]
    let catalog = OwlKeyboardSettingsCatalog(defaults: defaults) { refreshed[$0] = $1 }
    for toggle in OwlKeyboardSwitch.allCases {
      catalog.set(toggle, !toggle.defaultValue)
    }

    let state = OwlSettingsState()
    catalog.seed(into: state)
    let loaded = catalog.load()
    for toggle in OwlKeyboardSwitch.allCases {
      let expected = !toggle.defaultValue
      XCTAssertEqual(state[keyPath: toggle.row.mirror], expected, "\(toggle) seed")
      XCTAssertEqual(loaded[toggle], expected, "\(toggle) load")
      XCTAssertEqual(refreshed[toggle], expected, "\(toggle) cache refresh")
      XCTAssertEqual(defaults.object(forKey: toggle.key) as? Bool, expected, "\(toggle) stored form")
    }
    XCTAssertEqual(Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
                   Set(OwlKeyboardSwitch.allCases.map(\.key)), "set writes exactly its own key")
    XCTAssertTrue(state.keyboardCJKAlnumSpacing, "the derived spacing switch follows its two keys")
  }

  func testEngineOptionsAreTheNamesTheRustSessionHandles() throws {
    XCTAssertEqual(OwlKeyboardSettingsCatalog.engineOptions.map(\.name), [
      "wubi_auto_commit_unique", "wubi_fifth_code_top_commit", "wubi_code_hint", "wubi_z_wildcard",
      "wubi_auto_clear", "wubi_z_reverse_lookup", "wubi_english_channel", "wubi_user_dict_learning",
      "quick_phrase_candidates",
    ])
    XCTAssertEqual(OwlKeyboardSwitch.cjkPunctToggle.row.application, .sessionOption(.asciiPunct))

    // The FFI ignores unknown option names, so a typo would silently do nothing: every name must
    // be an explicit arm of its `set_option` match.
    let ffi = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("rust/crates/owl-msime-ffi/src/lib.rs")
    let source = try String(contentsOf: ffi, encoding: .utf8)
    for option in OwlKeyboardSettingsCatalog.engineOptions {
      XCTAssertTrue(source.contains("\"\(option.name)\" =>"), "FFI has no set_option arm for \(option.name)")
    }
    XCTAssertTrue(source.contains("\"\(EngineOption.asciiPunct.rawValue)\" =>"))
  }

  func testLiveCatalogKeepsHotPathCachesInStepWithDefaults() {
    let saved = OwlKeyboardSwitch.allCases.map { ($0, OwlDefaults.standard.object(forKey: $0.key)) }
    defer {
      for (toggle, value) in saved {
        if let value {
          OwlDefaults.standard.set(value, forKey: toggle.key)
          OwlKeyboardPreferences.refreshCache(toggle, (value as? Bool) ?? toggle.defaultValue)
        } else {
          OwlKeyboardSettingsCatalog.live.set(toggle, toggle.defaultValue)
          OwlDefaults.standard.removeObject(forKey: toggle.key)
        }
      }
    }
    let live = OwlKeyboardSettingsCatalog.live
    for value in [true, false] {
      live.set(.slashSymbolMenu, value)
      live.set(.autoPairBrackets, value)
      live.set(.cjkEnglishSpacing, value)
      live.set(.cjkNumberSpacing, value)
      XCTAssertEqual(OwlKeyboardPreferences.slashSymbolMenu, value)
      XCTAssertEqual(OwlKeyboardPreferences.autoPairBrackets, value)
      XCTAssertEqual(OwlKeyboardPreferences.cjkEnglishSpacing, value)
      XCTAssertEqual(OwlKeyboardPreferences.cjkNumberSpacing, value)
    }
  }
}
