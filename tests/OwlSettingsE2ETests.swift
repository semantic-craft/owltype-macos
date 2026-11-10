//
//  OwlSettingsE2ETests.swift
//  OwltypeTests
//
//  End-to-end contracts for settings that must persist, generate the intended Rime
//  patches, or reach the runtime homes used by the input method.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlSettingsE2EContractTests: XCTestCase {
  private var savedDefaults: [StoredDefault] = []
  private var tempDirs: [URL] = []

  override func setUp() {
    super.setUp()
    savedDefaults = Self.preferenceKeys.map { key in
      let value = OwlDefaults.standard.object(forKey: key)
      return StoredDefault(key: key, value: value, hadValue: value != nil)
    }
    setKnownPreferenceBaseline()
  }

  override func tearDown() {
    restoreUserDefaults()
    for dir in tempDirs {
      try? FileManager.default.removeItem(at: dir)
    }
    tempDirs = []
    super.tearDown()
  }

  func testKeyboardSettingsPersistAndReachRimePatchAndRuntimeTransforms() throws {
    OwlKeyboardPreferences.inputMethod = .wubi
    OwlKeyboardPreferences.wubiScheme = .pinyinMix
    OwlKeyboardPreferences.doublePinyin = .mspy
    OwlKeyboardPreferences.shiftSwitchCJK = false
    OwlKeyboardPreferences.cjkPunctToggle = true
    OwlKeyboardPreferences.pageSize = 9
    OwlKeyboardPreferences.pageMinusEquals = true
    OwlKeyboardPreferences.pageBrackets = true
    OwlKeyboardPreferences.pageCommaPeriod = true
    OwlKeyboardPreferences.select23Semicolon = true
    OwlKeyboardPreferences.slashSymbolMenu = true
    OwlKeyboardPreferences.cjkAlnumSpacing = true
    OwlKeyboardPreferences.appEnglishBundleIDs = ["com.apple.Terminal", "bad:key", "com.apple.Terminal"]
    OwlKeyboardPreferences.wubiCodeHint = true
    OwlKeyboardPreferences.wubiAutoClear = true
    OwlKeyboardPreferences.wubiCandidateMode = .singleOnly
    OwlFuzzyPreferences.zhz = true
    OwlFuzzyPreferences.chc = true
    OwlFuzzyPreferences.anang = true

    XCTAssertEqual(OwlKeyboardPreferences.inputMethod, .wubi)
    XCTAssertEqual(OwlKeyboardPreferences.wubiScheme, .pinyinMix)
    XCTAssertEqual(OwlKeyboardPreferences.doublePinyin, .mspy)
    XCTAssertFalse(OwlKeyboardPreferences.shiftSwitchCJK)
    XCTAssertEqual(OwlKeyboardPreferences.pageSize, 9)
    XCTAssertTrue(OwlKeyboardPreferences.slashSymbolMenu)
    XCTAssertEqual(OwlKeyboardPreferences.appEnglishBundleIDs, ["com.apple.Terminal"])
    XCTAssertEqual(OwlFuzzySnapshot.current().enabledCount, 3)

    XCTAssertEqual(OwlCommitTransform.apply(to: "猫头鹰AI第3条"), "猫头鹰 AI 第 3 条")
    XCTAssertEqual(OwlCommitTransform.apply(to: "1. 第一项\n"), "1. 第一项\n")
  }

  func testPanelEmojiSkinAIAndExperimentalSettingsPersistToRuntimeHomes() throws {
    let panelEditingState = OwlSettingsState()
    let panelSettings = OwlCandidatePanelSettings.live
    panelSettings.edit(.appearance(.dark), state: panelEditingState, onChange: {})
    panelSettings.edit(.size(.large), state: panelEditingState, onChange: {})
    panelSettings.edit(.orientation(.vertical), state: panelEditingState, onChange: {})
    panelSettings.edit(.font(.notoSerifSC), state: panelEditingState, onChange: {})
    panelSettings.edit(.animationsEnabled(false), state: panelEditingState, onChange: {})
    panelSettings.edit(.skin(.wuda), state: panelEditingState, onChange: {})
    OwlCloudPreferences.isEnabled = true
    OwlCloudPreferences.deepSeekModel = "deepseek-reasoner"

    XCTAssertEqual(panelSettings.snapshot().appearance, .dark)
    XCTAssertEqual(panelSettings.snapshot().size, .large)
    XCTAssertTrue(panelSettings.snapshot().orientation.isVertical(engineVertical: false, schemaID: "rime_ice"))
    XCTAssertEqual(panelSettings.snapshot().font.selection, .notoSerifSC)
    XCTAssertFalse(panelSettings.snapshot().animationsEnabled)
    XCTAssertEqual(panelSettings.snapshot().skin, .wuda)
    XCTAssertTrue(OwlCloudPreferences.isEnabled)
    XCTAssertEqual(OwlCloudPreferences.deepSeekModel, OwlCloudPreferences.reasonerDeepSeekModel)
  }

  func testStoreBackedSettingsUseIsolatedLocalStorage() throws {
    let dataDir = try makeTempDir()
    let suiteName = "OwlSettingsE2E-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var template = OwlTemplateEntry(title: "猫头鹰测试", body: "猫头鹰测试")
    template.trigger = "mtycs"
    template.invocationMode = .candidate
    try OwlTemplateStore.save(
      OwlTemplateLibrary(entries: [template]),
      dataDir: dataDir
    )
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: dataDir).entries, [template])

    XCTAssertFalse(OwlClipboardStore.isEnabled(defaults: defaults))
    OwlClipboardStore.setEnabled(true, defaults: defaults)
    XCTAssertTrue(OwlClipboardStore.isEnabled(defaults: defaults))
    let clipboard = try OwlClipboardStore.capture("  判决摘要  ", root: dataDir, now: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(clipboard.map(\.text), ["判决摘要"])
    try OwlClipboardStore.clear(root: dataDir)
    XCTAssertTrue(OwlClipboardStore.load(root: dataDir).isEmpty)
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-settings-e2e", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDirs.append(dir)
    return dir
  }

  private func read(_ fileName: String, in dir: URL) throws -> String {
    try String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8)
  }

  private func setKnownPreferenceBaseline() {
    OwlKeyboardPreferences.inputMethod = .pinyin
    OwlKeyboardPreferences.doublePinyin = .flypy
    OwlKeyboardPreferences.shiftSwitchCJK = true
    OwlKeyboardPreferences.cjkPunctToggle = false
    OwlKeyboardPreferences.pageSize = 8
    OwlKeyboardPreferences.pageMinusEquals = true
    OwlKeyboardPreferences.pageBrackets = true
    OwlKeyboardPreferences.pageCommaPeriod = false
    OwlKeyboardPreferences.select23Semicolon = false
    OwlKeyboardPreferences.slashSymbolMenu = false
    OwlKeyboardPreferences.cjkAlnumSpacing = false
    OwlKeyboardPreferences.appEnglishBundleIDs = []
    OwlKeyboardPreferences.wubiCodeHint = false
    OwlKeyboardPreferences.wubiAutoClear = false
    OwlKeyboardPreferences.wubiCandidateMode = .normal
    resetFuzzyPreferences()
    let panelSettings = OwlCandidatePanelSettings.live
    let panelState = OwlSettingsState()
    panelSettings.edit(.appearance(.system), state: panelState, onChange: {})
    panelSettings.edit(.size(.medium), state: panelState, onChange: {})
    panelSettings.edit(.orientation(.auto), state: panelState, onChange: {})
    panelSettings.edit(.font(.default), state: panelState, onChange: {})
    panelSettings.edit(.animationsEnabled(true), state: panelState, onChange: {})
    panelSettings.edit(.skin(.deepred), state: panelState, onChange: {})
    OwlCloudPreferences.resetForTesting()
    OwlExperimentalPreferences.resetForTesting()
  }

  private func resetFuzzyPreferences() {
    OwlFuzzyPreferences.zhz = false
    OwlFuzzyPreferences.chc = false
    OwlFuzzyPreferences.shs = false
    OwlFuzzyPreferences.nl = false
    OwlFuzzyPreferences.rl = false
    OwlFuzzyPreferences.fh = false
    OwlFuzzyPreferences.anang = false
    OwlFuzzyPreferences.eneng = false
    OwlFuzzyPreferences.ining = false
  }

  private func restoreUserDefaults() {
    for item in savedDefaults {
      if item.hadValue, let value = item.value {
        OwlDefaults.standard.set(value, forKey: item.key)
      } else {
        OwlDefaults.standard.removeObject(forKey: item.key)
      }
    }
    restoreCachedBool("OwlKeyboardCJKEnglishSpacing", default: false) {
      OwlKeyboardPreferences.cjkEnglishSpacing = $0
    }
    restoreCachedBool("OwlKeyboardCJKNumberSpacing", default: false) {
      OwlKeyboardPreferences.cjkNumberSpacing = $0
    }
    restoreCachedBool("OwlKeyboardSlashSymbolMenu", default: false) {
      OwlKeyboardPreferences.slashSymbolMenu = $0
    }
  }

  private func restoreCachedBool(_ key: String, default defaultValue: Bool, set: (Bool) -> Void) {
    guard let item = savedDefaults.first(where: { $0.key == key }) else { return }
    if item.hadValue {
      set(Self.boolValue(item.value) ?? defaultValue)
    } else {
      set(defaultValue)
      OwlDefaults.standard.removeObject(forKey: key)
    }
  }

  private struct StoredDefault {
    let key: String
    let value: Any?
    let hadValue: Bool
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
  }

  private static let preferenceKeys = [
    "OwlKeyboardInputMethod",
    "OwlKeyboardPageSize",
    "OwlKeyboardDoublePinyin",
    "OwlKeyboardWubiCodeHint",
    "OwlKeyboardWubiAutoClear",
    "OwlKeyboardWubiCandidateMode",
    "OwlKeyboardShiftSwitchCJK",
    "OwlKeyboardFullShapeToggle",
    "OwlKeyboardCJKPunctToggle",
    "OwlKeyboardPageMinusEquals",
    "OwlKeyboardPageBrackets",
    "OwlKeyboardPageCommaPeriod",
    "OwlKeyboardSelect23Semicolon",
    "OwlKeyboardSelect23Command",
    "OwlKeyboardSlashSymbolMenu",
    "OwlKeyboardCJKEnglishSpacing",
    "OwlKeyboardCJKNumberSpacing",
    "OwlKeyboardAppEnglishBundleIDs",
    "OwlFuzzyZhZ",
    "OwlFuzzyChC",
    "OwlFuzzyShS",
    "OwlFuzzyNL",
    "OwlFuzzyRL",
    "OwlFuzzyFH",
    "OwlFuzzyAnAng",
    "OwlFuzzyEnEng",
    "OwlFuzzyInIng",
    "OwlPanelAppearance",
    "OwlPanelFontSize",
    "OwlPanelOrientation",
    "OwlPanelFontDesign",
    "OwlPanelAnimations",
    "OwlSkin",
    "OwlCloudLaneEnabled",
    "OwlDeepSeekModel",
    "OwlDeepSeekEndpoint",
  ]
}
