//
//  FamoSettingsE2ETests.swift
//  FamoTests
//
//  End-to-end contracts for settings that must persist, generate the intended Rime
//  patches, or reach the runtime homes used by the input method.
//

import Foundation
import XCTest
@testable import Famo

final class FamoSettingsE2EContractTests: XCTestCase {
  private var savedDefaults: [StoredDefault] = []
  private var tempDirs: [URL] = []

  override func setUp() {
    super.setUp()
    savedDefaults = Self.preferenceKeys.map { key in
      let value = FamoDefaults.standard.object(forKey: key)
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
    FamoKeyboardPreferences.inputMethod = .wubi
    FamoKeyboardPreferences.wubiScheme = .pinyinMix
    FamoKeyboardPreferences.doublePinyin = .mspy
    FamoKeyboardPreferences.shiftSwitchCJK = false
    FamoKeyboardPreferences.cjkPunctToggle = true
    FamoKeyboardPreferences.pageSize = 9
    FamoKeyboardPreferences.pageMinusEquals = true
    FamoKeyboardPreferences.pageBrackets = true
    FamoKeyboardPreferences.pageCommaPeriod = true
    FamoKeyboardPreferences.select23Semicolon = true
    FamoKeyboardPreferences.slashSymbolMenu = true
    FamoKeyboardPreferences.cjkAlnumSpacing = true
    FamoKeyboardPreferences.appEnglishBundleIDs = ["com.apple.Terminal", "bad:key", "com.apple.Terminal"]
    FamoKeyboardPreferences.wubiCodeHint = true
    FamoKeyboardPreferences.wubiAutoClear = true
    FamoKeyboardPreferences.wubiCandidateMode = .singleOnly
    FamoFuzzyPreferences.zhz = true
    FamoFuzzyPreferences.chc = true
    FamoFuzzyPreferences.anang = true

    let snapshot = FamoKeyboardSnapshot.current()
    XCTAssertEqual(snapshot.inputMethod, .wubi)
    XCTAssertEqual(snapshot.wubiScheme, .pinyinMix)
    XCTAssertEqual(snapshot.doublePinyin, .mspy)
    XCTAssertFalse(snapshot.shiftSwitchCJK)
    XCTAssertEqual(snapshot.pageSize, 9)
    XCTAssertTrue(snapshot.slashSymbolMenu)
    XCTAssertEqual(snapshot.appEnglishBundleIDs, ["com.apple.Terminal"])
    XCTAssertEqual(snapshot.fuzzy.enabledCount, 3)

    let rimeDir = try makeTempDir()
    let written = try FamoManagedKeyboardPatchPlan.apply(
      snapshot: snapshot,
      writer: FamoConfigWriter(rimeDir: rimeDir),
      timestamp: "20260622-settings-e2e"
    )

    XCTAssertEqual(written, [
      "default.custom.yaml",
      "famo.custom.yaml",
      "rime_ice.custom.yaml",
      "wubi86_jidian.custom.yaml",
      "wubi86_jidian_pinyin.custom.yaml",
      "wubi86_jidian_trad.custom.yaml",
      "wubi86_jidian_trad_pinyin.custom.yaml",
    ])

    let defaultPatch = try read("default.custom.yaml", in: rimeDir)
    XCTAssertTrue(defaultPatch.contains("wubi86_jidian_trad_pinyin"))
    XCTAssertTrue(defaultPatch.contains("\"menu/page_size\": 9"))
    XCTAssertFalse(defaultPatch.contains("\"ascii_composer/switch_key/Shift_L\": commit_code"))
    XCTAssertFalse(defaultPatch.contains("\"ascii_composer/switch_key/Shift_R\": commit_code"))
    XCTAssertTrue(defaultPatch.contains("toggle: ascii_punct"))
    XCTAssertTrue(defaultPatch.contains("accept: minus"))
    XCTAssertTrue(defaultPatch.contains("accept: bracketleft"))
    XCTAssertTrue(defaultPatch.contains("accept: comma"))
    XCTAssertTrue(defaultPatch.contains("send: 2"))
    XCTAssertTrue(defaultPatch.contains("send: 3"))
    XCTAssertTrue(defaultPatch.contains("\"punctuator/half_shape/+\":"))
    XCTAssertTrue(defaultPatch.contains("\"punctuator/full_shape/+\":"))
    XCTAssertTrue(defaultPatch.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"))
    // app_options moved to the famo domain (task 07-08): NOT in default anymore — it lives in
    // famo.custom.yaml, the only domain FamoConfig.getAppOptions reads.
    XCTAssertFalse(defaultPatch.contains("app_options/"))
    let famoPatch = try read("famo.custom.yaml", in: rimeDir)
    XCTAssertTrue(famoPatch.contains("\"app_options/com.apple.Terminal/ascii_mode\": true"))
    XCTAssertFalse(famoPatch.contains("bad:key"))
    XCTAssertFalse(defaultPatch.contains("Super_L"))

    let rimeIcePatch = try read("rime_ice.custom.yaml", in: rimeDir)
    XCTAssertTrue(rimeIcePatch.contains("\"speller/algebra/+\""))
    XCTAssertTrue(rimeIcePatch.contains("derive/^zh/z/"))
    XCTAssertTrue(rimeIcePatch.contains("derive/^ch/c/"))
    XCTAssertTrue(rimeIcePatch.contains("derive/an$/ang/"))

    for name in [
      "wubi86_jidian.custom.yaml",
      "wubi86_jidian_pinyin.custom.yaml",
      "wubi86_jidian_trad.custom.yaml",
      "wubi86_jidian_trad_pinyin.custom.yaml",
    ] {
      let patch = try read(name, in: rimeDir)
      XCTAssertTrue(patch.contains("\"translator/comment_format\": []"), name)
      XCTAssertTrue(patch.contains("\"reverse_lookup/comment_format\": []"), name)
      XCTAssertTrue(patch.contains("\"reverse_lookup/prefix\": \"z\""), name)
      XCTAssertTrue(patch.contains("\"speller/auto_clear\": max_length"), name)
      XCTAssertTrue(patch.contains("lua_filter@*wubi86_jidian_single_char_only"), name)
      XCTAssertFalse(patch.contains("lua_filter@*wubi86_jidian_single_char_first_filter"), name)
      XCTAssertTrue(patch.contains("\"punctuator/half_shape/+\":"), name)
      XCTAssertTrue(patch.contains("\"punctuator/full_shape/+\":"), name)
      XCTAssertTrue(patch.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"), name)
    }

    XCTAssertEqual(FamoCommitTransform.apply(to: "法墨AI第3条"), "法墨 AI 第 3 条")
    XCTAssertEqual(FamoCommitTransform.apply(to: "1. 第一项\n"), "1. 第一项\n")
  }

  func testPanelEmojiSkinAIAndExperimentalSettingsPersistToRuntimeHomes() throws {
    let panelEditingState = FamoSettingsState()
    let panelSettings = FamoCandidatePanelSettings.live
    panelSettings.edit(.appearance(.dark), state: panelEditingState, onChange: {})
    FamoPanelPreferences.fontSize = .large
    FamoPanelPreferences.orientation = .vertical
    panelSettings.edit(.font(.notoSerifSC), state: panelEditingState, onChange: {})
    panelSettings.edit(.animationsEnabled(false), state: panelEditingState, onChange: {})
    panelSettings.edit(.skin(.wuda), state: panelEditingState, onChange: {})
    FamoCloudPreferences.isEnabled = true
    FamoCloudPreferences.provider = .deepSeek
    FamoCloudPreferences.deepSeekModel = "deepseek-reasoner"

    XCTAssertEqual(panelSettings.snapshot().appearance, .dark)
    XCTAssertEqual(FamoPanelPreferences.fontSize, .large)
    XCTAssertTrue(FamoPanelPreferences.orientation.isVertical(rimeVertical: false, schemaID: "rime_ice"))
    XCTAssertEqual(panelSettings.snapshot().font.selection, .notoSerifSC)
    XCTAssertFalse(panelSettings.snapshot().animationsEnabled)
    XCTAssertEqual(panelSettings.snapshot().skin, .wuda)
    XCTAssertTrue(FamoCloudPreferences.isEnabled)
    XCTAssertEqual(FamoCloudPreferences.provider, .deepSeek)
    XCTAssertEqual(FamoCloudPreferences.deepSeekModel, FamoCloudPreferences.reasonerDeepSeekModel)
  }

  func testStoreBackedSettingsUseIsolatedLocalStorage() throws {
    let rimeDir = try makeTempDir()
    let suiteName = "FamoSettingsE2E-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let quickEntry = try FamoQuickSendStore.entry(text: "法墨测试", code: "fmcs")
    try FamoQuickSendStore.save(
      [quickEntry],
      writer: FamoConfigWriter(rimeDir: rimeDir),
      timestamp: "20260622-settings-e2e"
    )
    // load reads the JSON source of truth: exactly the saved entries. The derived table carries
    // the same bare code (no prefix — ` collides with rime-ice's radical-search lead key).
    XCTAssertEqual(FamoQuickSendStore.load(rimeDir: rimeDir), [quickEntry])
    XCTAssertTrue(try read("famo_quick_send.txt", in: rimeDir).contains("法墨测试\tfmcs\t100000"))
    XCTAssertFalse(try read("famo_quick_send.txt", in: rimeDir).contains("`fmcs"))
    XCTAssertTrue(try read("rime_ice.custom.yaml", in: rimeDir).contains("table_translator@famo_quick_send"))

    XCTAssertFalse(FamoClipboardStore.isEnabled(defaults: defaults))
    FamoClipboardStore.setEnabled(true, defaults: defaults)
    XCTAssertTrue(FamoClipboardStore.isEnabled(defaults: defaults))
    let clipboard = try FamoClipboardStore.capture("  判决摘要  ", root: rimeDir, now: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(clipboard.map(\.text), ["判决摘要"])
    try FamoClipboardStore.clear(root: rimeDir)
    XCTAssertTrue(FamoClipboardStore.load(root: rimeDir).isEmpty)

    let projectStore = FamoProjectStore(root: rimeDir, defaults: defaults)
    let project = try projectStore.create(name: "行政法课程")
    try projectStore.activate(id: project.id)
    let renamed = try projectStore.rename(id: project.id, to: "行政法案例")
    let withWords = try projectStore.setWords(id: renamed.id, words: ["行政许可", "行政处罚", "行政许可"])
    let rule = FamoTermRule(preferred: "正当程序", allowedVariants: ["程序正当"], forbiddenVariants: ["走流程"])
    let withRule = try projectStore.setTermRules(id: withWords.id, termRules: [rule])
    XCTAssertEqual(projectStore.activeProjectID, project.id)
    XCTAssertEqual(withRule.name, "行政法案例")
    XCTAssertEqual(withRule.normalizedWords, ["行政许可", "行政处罚"])
    XCTAssertEqual(withRule.termRules.first?.preferred, "正当程序")
    try projectStore.delete(id: project.id)
    XCTAssertNil(projectStore.activeProjectID)
  }

  func testQuickSendExamplesAreValidAndEnableRoundtripsToRimePatch() throws {
    // Every built-in example is a valid quick-send entry (construct via the store's validating
    // factory so a malformed example fails here), with no newline/Tab and unique codes.
    var seenCodes = Set<String>()
    for example in FamoQuickSendExamples.all {
      let rebuilt = try FamoQuickSendStore.entry(text: example.entry.text, code: example.entry.code)
      XCTAssertEqual(rebuilt, example.entry, "example \(example.tool) must already be normalized")
      XCTAssertFalse(example.entry.text.contains("\n"), example.tool)
      XCTAssertFalse(example.entry.text.contains("\t"), example.tool)
      XCTAssertNotNil(
        example.entry.code.range(of: #"^[a-z][a-z0-9]{0,31}$"#, options: .regularExpression),
        "example code \(example.entry.code) must be valid"
      )
      XCTAssertTrue(seenCodes.insert(example.entry.code).inserted, "duplicate example code \(example.entry.code)")
    }

    // Enabling an example == saving entries that include its `entry`: it roundtrips through `load`
    // as exactly itself, while the generated TSV + rime_ice patch carry the command under its
    // bare code (full-code trigger; enable_completion stays off in the patch).
    let rimeDir = try makeTempDir()
    let claude = try XCTUnwrap(FamoQuickSendExamples.all.first { $0.tool == "Claude Code" })
    try FamoQuickSendStore.save(
      [claude.entry],
      writer: FamoConfigWriter(rimeDir: rimeDir),
      timestamp: "20260630-quick-send-examples"
    )
    XCTAssertEqual(FamoQuickSendStore.load(rimeDir: rimeDir), [claude.entry])
    let table = try read("famo_quick_send.txt", in: rimeDir)
    XCTAssertTrue(table.contains("claude --dangerously-skip-permissions\tyocc\t100000"))
    XCTAssertFalse(table.contains("`yocc"))
    XCTAssertFalse(table.contains("\tvyocc\t"))
    XCTAssertTrue(try read("rime_ice.custom.yaml", in: rimeDir).contains("table_translator@famo_quick_send"))
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("famo-settings-e2e", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDirs.append(dir)
    return dir
  }

  private func read(_ fileName: String, in dir: URL) throws -> String {
    try String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8)
  }

  private func setKnownPreferenceBaseline() {
    FamoKeyboardPreferences.inputMethod = .pinyin
    FamoKeyboardPreferences.doublePinyin = .flypy
    FamoKeyboardPreferences.shiftSwitchCJK = true
    FamoKeyboardPreferences.cjkPunctToggle = false
    FamoKeyboardPreferences.pageSize = 8
    FamoKeyboardPreferences.pageMinusEquals = true
    FamoKeyboardPreferences.pageBrackets = true
    FamoKeyboardPreferences.pageCommaPeriod = false
    FamoKeyboardPreferences.select23Semicolon = false
    FamoKeyboardPreferences.slashSymbolMenu = false
    FamoKeyboardPreferences.cjkAlnumSpacing = false
    FamoKeyboardPreferences.appEnglishBundleIDs = []
    FamoKeyboardPreferences.wubiCodeHint = false
    FamoKeyboardPreferences.wubiAutoClear = false
    FamoKeyboardPreferences.wubiCandidateMode = .normal
    resetFuzzyPreferences()
    let panelSettings = FamoCandidatePanelSettings.live
    let panelState = FamoSettingsState()
    panelSettings.edit(.appearance(.system), state: panelState, onChange: {})
    FamoPanelPreferences.fontSize = .medium
    FamoPanelPreferences.orientation = .auto
    panelSettings.edit(.font(.default), state: panelState, onChange: {})
    panelSettings.edit(.animationsEnabled(true), state: panelState, onChange: {})
    panelSettings.edit(.skin(.deepred), state: panelState, onChange: {})
    FamoCloudPreferences.resetForTesting()
    FamoExperimentalPreferences.resetForTesting()
  }

  private func resetFuzzyPreferences() {
    FamoFuzzyPreferences.zhz = false
    FamoFuzzyPreferences.chc = false
    FamoFuzzyPreferences.shs = false
    FamoFuzzyPreferences.nl = false
    FamoFuzzyPreferences.rl = false
    FamoFuzzyPreferences.fh = false
    FamoFuzzyPreferences.anang = false
    FamoFuzzyPreferences.eneng = false
    FamoFuzzyPreferences.ining = false
  }

  private func restoreUserDefaults() {
    for item in savedDefaults {
      if item.hadValue, let value = item.value {
        FamoDefaults.standard.set(value, forKey: item.key)
      } else {
        FamoDefaults.standard.removeObject(forKey: item.key)
      }
    }
    restoreCachedBool("FamoKeyboardCJKEnglishSpacing", default: false) {
      FamoKeyboardPreferences.cjkEnglishSpacing = $0
    }
    restoreCachedBool("FamoKeyboardCJKNumberSpacing", default: false) {
      FamoKeyboardPreferences.cjkNumberSpacing = $0
    }
    restoreCachedBool("FamoKeyboardSlashSymbolMenu", default: false) {
      FamoKeyboardPreferences.slashSymbolMenu = $0
    }
  }

  private func restoreCachedBool(_ key: String, default defaultValue: Bool, set: (Bool) -> Void) {
    guard let item = savedDefaults.first(where: { $0.key == key }) else { return }
    if item.hadValue {
      set(Self.boolValue(item.value) ?? defaultValue)
    } else {
      set(defaultValue)
      FamoDefaults.standard.removeObject(forKey: key)
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
    "FamoKeyboardInputMethod",
    "FamoKeyboardPageSize",
    "FamoKeyboardDoublePinyin",
    "FamoKeyboardWubiCodeHint",
    "FamoKeyboardWubiAutoClear",
    "FamoKeyboardWubiCandidateMode",
    "FamoKeyboardShiftSwitchCJK",
    "FamoKeyboardFullShapeToggle",
    "FamoKeyboardCJKPunctToggle",
    "FamoKeyboardPageMinusEquals",
    "FamoKeyboardPageBrackets",
    "FamoKeyboardPageCommaPeriod",
    "FamoKeyboardSelect23Semicolon",
    "FamoKeyboardSelect23Command",
    "FamoKeyboardSlashSymbolMenu",
    "FamoKeyboardCJKEnglishSpacing",
    "FamoKeyboardCJKNumberSpacing",
    "FamoKeyboardAppEnglishBundleIDs",
    "FamoFuzzyZhZ",
    "FamoFuzzyChC",
    "FamoFuzzyShS",
    "FamoFuzzyNL",
    "FamoFuzzyRL",
    "FamoFuzzyFH",
    "FamoFuzzyAnAng",
    "FamoFuzzyEnEng",
    "FamoFuzzyInIng",
    "FamoPanelAppearance",
    "FamoPanelFontSize",
    "FamoPanelOrientation",
    "FamoPanelFontDesign",
    "FamoPanelAnimations",
    "FamoPanelExpandedByDefault",
    "FamoSkin",
    "FamoCloudLaneEnabled",
    "FamoCloudProvider",
    "FamoDeepSeekModel",
    "FamoDeepSeekEndpoint",
  ]
}
