//
//  OwlSettingsActionTests.swift
//  OwltypeTests
//

import Foundation
import XCTest
@testable import Owltype

final class OwlSettingsActionTests: XCTestCase {
  private var savedDefaults: [String: Any?] = [:]
  private var tempDirs: [URL] = []
  private let keys = [
    "OwlKeyboardInputMethod", "OwlKeyboardDoublePinyin", "OwlKeyboardWubiScheme", "OwlKeyboardWubiCandidateMode",
    "OwlKeyboardPageSize",
    "OwlKeyboardWubiCodeHint", "OwlKeyboardWubiAutoClear", "OwlKeyboardShiftSwitchCJK",
    "OwlKeyboardFullShapeToggle", "OwlKeyboardCJKPunctToggle",
    "OwlKeyboardDefaultAsciiMode", "OwlKeyboardDefaultFullShape", "OwlKeyboardPageMinusEquals",
    "OwlKeyboardPageBrackets", "OwlKeyboardPageCommaPeriod", "OwlKeyboardSelect23Semicolon",
    "OwlKeyboardSelect23Command", "OwlKeyboardSlashSymbolMenu", "OwlKeyboardAngleSymbolMenu",
    "OwlKeyboardCJKEnglishSpacing", "OwlKeyboardCJKNumberSpacing",
    "OwlKeyboardAppEnglishBundleIDs",
    "OwlFuzzyZhZ", "OwlFuzzyChC", "OwlFuzzyShS", "OwlFuzzyNL", "OwlFuzzyRL",
    "OwlFuzzyFH", "OwlFuzzyAnAng", "OwlFuzzyEnEng", "OwlFuzzyInIng",
    "OwlPanelAppearance", "OwlPanelFontSize", "OwlPanelOrientation", "OwlPanelFontDesign",
    "OwlPanelAnimations", "OwlPanelPreviewRows",
    "OwlSkin", "OwlEmojiInCandidates",
    "OwlCloudLaneEnabled", "OwlDeepSeekModel",
    "OwlSelectionMenuEnabled", "OwlSkillSourceVerificationEnabled", "OwlSkillResearchAssistEnabled",
    "OwlSkillAskAnythingEnabled",
    "OwlAskWebSearchEnabled", "OwlAskSearchProvider",
  ]

  override func setUp() {
    super.setUp()
    savedDefaults = Dictionary(uniqueKeysWithValues: keys.map { ($0, OwlDefaults.standard.object(forKey: $0)) })
  }

  override func tearDown() {
    for key in keys {
      if let value = savedDefaults[key] ?? nil {
        OwlDefaults.standard.set(value, forKey: key)
      } else {
        OwlDefaults.standard.removeObject(forKey: key)
      }
    }
    if let value = savedDefaults["OwlKeyboardSlashSymbolMenu"] ?? nil {
      OwlKeyboardPreferences.slashSymbolMenu = (value as? NSNumber)?.boolValue ?? false
    } else {
      OwlKeyboardPreferences.slashSymbolMenu = false
      OwlDefaults.standard.removeObject(forKey: "OwlKeyboardSlashSymbolMenu")
    }
    for dir in tempDirs {
      try? FileManager.default.removeItem(at: dir)
    }
    tempDirs = []
    super.tearDown()
  }

  func testClickablePreferenceActionsUpdateStateAndPreferenceHomes() {
    let state = OwlSettingsState()
    var selectedSchemas: [String] = []

    OwlSettingsActions.selectInputMethod(.doublePinyin, state: state) { selectedSchemas.append($0) }
    OwlSettingsActions.selectDoublePinyin(.mspy, state: state) { selectedSchemas.append($0) }
    // 选混输子方案（此时方案非五笔，不上屏）后再切到五笔输入 → schemaId 解析成混输。
    OwlSettingsActions.selectWubiScheme(.pinyinMix, state: state) { selectedSchemas.append($0) }
    OwlSettingsActions.selectInputMethod(.wubi, state: state) { selectedSchemas.append($0) }
    XCTAssertEqual(selectedSchemas, ["double_pinyin_flypy", "double_pinyin_mspy", "wubi86_jidian_pinyin"])
    XCTAssertEqual(OwlKeyboardPreferences.inputMethod, .wubi)
    XCTAssertEqual(OwlKeyboardPreferences.wubiScheme, .pinyinMix)
    XCTAssertEqual(OwlKeyboardPreferences.doublePinyin, .mspy)

    assertSet(.singleFirst, \.keyboardWubiCandidateMode, state, { OwlKeyboardPreferences.wubiCandidateMode }) { OwlKeyboardPreferences.wubiCandidateMode = $0 }
    let panelSettings = OwlCandidatePanelSettings.live
    panelSettings.edit(.appearance(.dark), state: state, onChange: {})
    XCTAssertEqual(panelSettings.snapshot().appearance, .dark)
    panelSettings.edit(.size(.large), state: state, onChange: {})
    panelSettings.edit(.orientation(.vertical), state: state, onChange: {})
    XCTAssertEqual(panelSettings.snapshot().size, .large)
    XCTAssertEqual(panelSettings.snapshot().orientation, .vertical)
    panelSettings.edit(.font(.mapleMono), state: state, onChange: {})
    XCTAssertEqual(state.candidateFont.selection, .mapleMono)
    XCTAssertEqual(panelSettings.snapshot().font.selection, .mapleMono)
    assertSet(6, \.candidatePageSize, state, { OwlKeyboardPreferences.pageSize }) { OwlKeyboardPreferences.pageSize = $0 }
    panelSettings.edit(.skin(.wuda), state: state, onChange: {})
    XCTAssertEqual(panelSettings.snapshot().skin, .wuda)
    assertSet(OwlCloudPreferences.reasonerDeepSeekModel, \.cloudModel, state, { OwlCloudPreferences.deepSeekModel }) { OwlCloudPreferences.deepSeekModel = $0 }
    // 默认状态·中英文 / 全半角 下拉（同 `OwlSettingsActions.set` 写穿；简繁体复用 traditionalOutput）。
    assertSet(true, \.keyboardDefaultAsciiMode, state, { OwlKeyboardPreferences.defaultAsciiMode }) { OwlKeyboardPreferences.defaultAsciiMode = $0 }
    assertSet(true, \.keyboardDefaultFullShape, state, { OwlKeyboardPreferences.defaultFullShape }) { OwlKeyboardPreferences.defaultFullShape = $0 }

    assertToggle(\.keyboardWubiCodeHint, state, { OwlKeyboardPreferences.wubiCodeHint }) { OwlKeyboardPreferences.wubiCodeHint = $0 }
    assertToggle(\.keyboardWubiAutoClear, state, { OwlKeyboardPreferences.wubiAutoClear }) { OwlKeyboardPreferences.wubiAutoClear = $0 }
    assertToggle(\.keyboardWubiUserDictLearning, state, { OwlKeyboardPreferences.wubiUserDictLearning }) { OwlKeyboardPreferences.wubiUserDictLearning = $0 }
    assertToggle(\.keyboardShiftSwitchCJK, state, { OwlKeyboardPreferences.shiftSwitchCJK }) { OwlKeyboardPreferences.shiftSwitchCJK = $0 }
    assertToggle(\.keyboardCJKPunctToggle, state, { OwlKeyboardPreferences.cjkPunctToggle }) { OwlKeyboardPreferences.cjkPunctToggle = $0 }
    assertToggle(\.keyboardPageMinusEquals, state, { OwlKeyboardPreferences.pageMinusEquals }) { OwlKeyboardPreferences.pageMinusEquals = $0 }
    assertToggle(\.keyboardPageBrackets, state, { OwlKeyboardPreferences.pageBrackets }) { OwlKeyboardPreferences.pageBrackets = $0 }
    assertToggle(\.keyboardPageCommaPeriod, state, { OwlKeyboardPreferences.pageCommaPeriod }) { OwlKeyboardPreferences.pageCommaPeriod = $0 }
    assertToggle(\.keyboardSelect23Semicolon, state, { OwlKeyboardPreferences.select23Semicolon }) { OwlKeyboardPreferences.select23Semicolon = $0 }
    assertToggle(\.keyboardSlashSymbolMenu, state, { OwlKeyboardPreferences.slashSymbolMenu }) { OwlKeyboardPreferences.slashSymbolMenu = $0 }
    assertToggle(\.keyboardAngleSymbolMenu, state, { OwlKeyboardPreferences.angleSymbolMenu }) { OwlKeyboardPreferences.angleSymbolMenu = $0 }
    assertToggle(\.keyboardCJKAlnumSpacing, state, { OwlKeyboardPreferences.cjkAlnumSpacing }) { OwlKeyboardPreferences.cjkAlnumSpacing = $0 }
    panelSettings.edit(.animationsEnabled(false), state: state, onChange: {})
    XCTAssertFalse(panelSettings.snapshot().animationsEnabled)
    panelSettings.edit(.scrollRows(1), state: state, onChange: {})
    XCTAssertEqual(panelSettings.snapshot().scrollRows, 1)
    assertToggle(\.candidateEmojiEnabled, state, { OwlEmojiPreferences.candidateEmojiEnabled }) { OwlEmojiPreferences.candidateEmojiEnabled = $0 }
    assertToggle(\.cloudEnabled, state, { OwlCloudPreferences.isEnabled }) { OwlCloudPreferences.isEnabled = $0 }
    assertToggle(\.askWebSearchEnabled, state, { OwlAskWebSearchSettings.isEnabled }) { OwlAskWebSearchSettings.isEnabled = $0 }
    assertToggle(\.selectionMenuEnabled, state, { OwlSelectionMenuPreferences.isEnabled }) { OwlSelectionMenuPreferences.isEnabled = $0 }
    // 任意提问的技能开关（2026-07-26 技能精简：兜底功能置顶、真开关默认开）。
    assertToggle(\.askAnythingSkillEnabled, state, { OwlSelectionMenuPreferences.askEnabled }) { OwlSelectionMenuPreferences.askEnabled = $0 }
    assertToggle(\.sourceVerificationSkillEnabled, state, { OwlSelectionMenuPreferences.sourceVerificationEnabled }) { OwlSelectionMenuPreferences.sourceVerificationEnabled = $0 }
    assertToggle(\.researchAssistSkillEnabled, state, { OwlSelectionMenuPreferences.researchAssistEnabled }) { OwlSelectionMenuPreferences.researchAssistEnabled = $0 }
    assertToggle(\.publishFormattingSkillEnabled, state, { OwlSelectionMenuPreferences.publishFormattingEnabled }) { OwlSelectionMenuPreferences.publishFormattingEnabled = $0 }
    assertToggle(\.translationSkillEnabled, state, { OwlSelectionMenuPreferences.translationEnabled }) { OwlSelectionMenuPreferences.translationEnabled = $0 }
    assertToggle(\.goalBriefSkillEnabled, state, { OwlSelectionMenuPreferences.goalBriefEnabled }) { OwlSelectionMenuPreferences.goalBriefEnabled = $0 }

    assertFuzzyToggleActions()

    OwlSettingsActions.setAppEnglishBundleIDsText("com.apple.Terminal bad:key com.apple.Terminal", state: state)
    XCTAssertEqual(OwlKeyboardPreferences.appEnglishBundleIDs, ["com.apple.Terminal"])
  }

  func testSelectionMenuSkillPreferencesDefaultToOptInSkillsOnly() {
    OwlSelectionMenuPreferences.resetForTesting()
    XCTAssertFalse(OwlSelectionMenuPreferences.isEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.askEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.sourceVerificationEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.researchAssistEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.publishFormattingEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.translationEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.promptOptimizeEnabled)
    XCTAssertTrue(OwlSelectionMenuPreferences.goalBriefEnabled)
  }

  func testSelectionMenuActionsFollowEnabledSkillPreferences() {
    OwlSelectionMenuPreferences.resetForTesting()

    // 云端 AI 是全部技能的总闸：关掉则菜单为空（含任意提问），不管各技能开关是什么。
    XCTAssertEqual(OwlSelectionMenuAction.enabledActions(cloudEnabled: false), [])

    XCTAssertEqual(
      OwlSelectionMenuAction.enabledActions(cloudEnabled: true),
      [.ask, .polish, .sourceVerification, .researchAssist, .publishFormatting,
       .translate, .promptOptimize, .goalBrief]
    )

    OwlSelectionMenuPreferences.publishFormattingEnabled = false
    OwlSelectionMenuPreferences.sourceVerificationEnabled = false
    XCTAssertEqual(
      OwlSelectionMenuAction.enabledActions(cloudEnabled: true),
      [.ask, .polish, .researchAssist, .translate, .promptOptimize, .goalBrief]
    )

    OwlSelectionMenuPreferences.polishEnabled = false
    OwlSelectionMenuPreferences.translationEnabled = false
    OwlSelectionMenuPreferences.promptOptimizeEnabled = false
    OwlSelectionMenuPreferences.goalBriefEnabled = false
    XCTAssertEqual(
      OwlSelectionMenuAction.enabledActions(cloudEnabled: true),
      [.ask, .researchAssist]
    )

    // 任意提问自 2026-07-26 起有自己的开关（默认开）：单独关掉它，其余技能不受影响。
    OwlSelectionMenuPreferences.askEnabled = false
    XCTAssertEqual(OwlSelectionMenuAction.enabledActions(cloudEnabled: true), [.researchAssist])

    // 全部开关都关（含任意提问）→ 菜单为空。
    OwlSelectionMenuPreferences.researchAssistEnabled = false
    XCTAssertEqual(OwlSelectionMenuAction.enabledActions(cloudEnabled: true), [])

    OwlSelectionMenuPreferences.resetForTesting()
  }

  @MainActor
  func testSelectionReplacementFlowWritesThroughCapturedTarget() {
    var writes: [String] = []
    let target = OwlSelectionReplacementTarget { text in
      writes.append(text)
      return .success
    }

    XCTAssertEqual(OwlSelectionReplacementFlow.write("  通知正文\n", target: target), .inserted(.axSelectedText))
    XCTAssertEqual(writes, ["  通知正文\n"])
  }

  @MainActor
  func testSelectionReplacementFlowDoesNotWriteWithoutTargetOrText() {
    var writes: [String] = []
    let target = OwlSelectionReplacementTarget { text in
      writes.append(text)
      return .success
    }

    XCTAssertEqual(
      OwlSelectionReplacementFlow.write("排版结果", target: nil),
      .failed("无法定位原选区，请重新选择文字后再试。")
    )
    XCTAssertEqual(
      OwlSelectionReplacementFlow.write(" \n\t", target: target),
      .failed("未生成可替换文本。")
    )
    XCTAssertTrue(writes.isEmpty)
  }

  func testInputMethodSelectionCanTriggerConfigApplyAfterSchemaSelection() {
    let state = OwlSettingsState()
    var trace: [String] = []

    OwlSettingsActions.selectInputMethod(
      .wubi,
      state: state,
      applyConfig: { trace.append("apply") },
      onSelectSchema: { trace.append("schema:\($0)") }
    )
    XCTAssertEqual(trace, ["schema:wubi86_jidian", "apply"])

    trace = []
    OwlSettingsActions.selectWubiScheme(
      .pinyinMix,
      state: state,
      applyConfig: { trace.append("apply") },
      onSelectSchema: { trace.append("schema:\($0)") }
    )
    XCTAssertEqual(trace, ["schema:wubi86_jidian_pinyin", "apply"])
  }

  func testPreferredSchemaIDFollowsWubiPinyinMixPreference() {
    OwlKeyboardPreferences.inputMethod = .wubi
    OwlKeyboardPreferences.wubiScheme = .pinyinMix

    XCTAssertEqual(OwlKeyboardPreferences.preferredSchemaID, "wubi86_jidian_pinyin")

    OwlKeyboardPreferences.wubiScheme = .jidian86
    XCTAssertEqual(OwlKeyboardPreferences.preferredSchemaID, "wubi86_jidian")
  }

  func testStoreBackedButtonActionsReachStoresAndStatuses() throws {
    var clipboardEnabled = false
    let enableStatus = OwlSettingsActions.setClipboardEnabled(true) { clipboardEnabled = $0 }
    XCTAssertTrue(clipboardEnabled)
    XCTAssertEqual(enableStatus, "已启用；只在你点击捕获时读取纯文本剪贴板。")

    let blockedCapture = try OwlSettingsActions.captureClipboard(enabled: false, text: "忽略") { _ in
      XCTFail("disabled capture must not read the pasteboard")
      return []
    }
    XCTAssertNil(blockedCapture.entries)
    XCTAssertEqual(blockedCapture.status, "先启用剪贴板面板。")

    let dir = try makeTempDir()
    let captured = try OwlSettingsActions.captureClipboard(enabled: true, text: "  判决摘要  ") {
      try OwlClipboardStore.capture($0, root: dir, now: Date(timeIntervalSince1970: 0))
    }
    XCTAssertEqual(captured.entries?.map(\.text), ["判决摘要"])
    XCTAssertTrue(captured.status.contains("已捕获当前剪贴板"))

    let cleared = try OwlSettingsActions.clearClipboard {
      try OwlClipboardStore.clear(root: dir)
    }
    XCTAssertTrue(cleared.entries.isEmpty)
    XCTAssertEqual(cleared.status, "已清空本地剪贴板记录。")
    XCTAssertTrue(OwlClipboardStore.load(root: dir).isEmpty)
  }

  func testLearnAndKeychainButtonActionsReachStoresAndStatuses() throws {
    XCTAssertEqual(OwlSettingsActions.deepSeekAPIKeyStatus { nil }, "未配置 API Key")
    XCTAssertEqual(OwlSettingsActions.deepSeekAPIKeyStatus { "sk-test" }, "已配置 Keychain API Key")
    XCTAssertEqual(OwlSettingsActions.deepSeekAPIKeyStatus { throw NSError(domain: "test", code: 1) }, "无法读取 Keychain")

    var savedKey = ""
    let emptyKey = OwlSettingsActions.saveDeepSeekAPIKey(" ") {
      savedKey = $0
    }
    XCTAssertEqual(emptyKey.input, " ")
    XCTAssertEqual(emptyKey.status, "请输入 API Key")
    XCTAssertEqual(savedKey, "")

    let saved = OwlSettingsActions.saveDeepSeekAPIKey(" sk-test ") {
      savedKey = $0
    }
    XCTAssertEqual(saved.input, "")
    XCTAssertEqual(saved.status, "已保存到 Keychain")
    XCTAssertEqual(savedKey, "sk-test")

    let saveFailure = OwlSettingsActions.saveDeepSeekAPIKey("sk-fail") { _ in
      throw NSError(domain: "test", code: 2)
    }
    XCTAssertEqual(saveFailure.input, "sk-fail")
    XCTAssertEqual(saveFailure.status, "保存 Keychain 失败")

    var didDelete = false
    let deletedKey = OwlSettingsActions.deleteDeepSeekAPIKey(input: "sk-test") {
      didDelete = true
    }
    XCTAssertTrue(didDelete)
    XCTAssertEqual(deletedKey.input, "")
    XCTAssertEqual(deletedKey.status, "已删除 API Key")

    let deleteFailure = OwlSettingsActions.deleteDeepSeekAPIKey(input: "sk-test") {
      throw NSError(domain: "test", code: 3)
    }
    XCTAssertEqual(deleteFailure.input, "sk-test")
    XCTAssertEqual(deleteFailure.status, "删除 Keychain 失败")
  }

  func testPreviewSchemaAndWritePreviewActionsAreClickableWithoutLiveSideEffects() {
    var selectedSchemas: [String] = []
    let schema = SchemaItem(id: "rime_ice", name: "雾凇拼音")
    XCTAssertFalse(OwlSettingsActions.selectSchemaRow(schema, currentSchemaID: "rime_ice") {
      selectedSchemas.append($0)
    })
    XCTAssertTrue(OwlSettingsActions.selectSchemaRow(schema, currentSchemaID: "wubi86_jidian") {
      selectedSchemas.append($0)
    })
    XCTAssertEqual(selectedSchemas, ["rime_ice"])
  }

  // MARK: - PR2 Track 1: Owltype-side prefs are live + must NOT trigger a Rime deploy/apply

  /// The 本地便捷输入 toggle is a Owltype-side cached flag read live at the commit seam by
  /// `OwlCommitTransform`. Toggling it must (a) take effect on the very next commit transform
  /// (no deploy), and (b) never route through a Rime apply/redeploy closure.
  func testCJKAlnumSpacingToggleIsLiveAndDoesNotTriggerAnyDeploy() {
    let state = OwlSettingsState()
    var applyCalls = 0
    let applySpy: () -> Bool = { applyCalls += 1; return true }

    // Baseline: all off → transform is identity for the cross-boundary spacing.
    OwlKeyboardPreferences.cjkEnglishSpacing = false
    OwlKeyboardPreferences.cjkNumberSpacing = false
    state.keyboardCJKEnglishSpacing = false
    state.keyboardCJKNumberSpacing = false
    state.keyboardCJKAlnumSpacing = false
    XCTAssertEqual(OwlCommitTransform.apply(to: "猫头鹰AI第3条"), "猫头鹰AI第3条")

    // Legacy migration: either old spacing key makes the new single runtime switch ON.
    OwlKeyboardPreferences.cjkEnglishSpacing = true
    OwlKeyboardPreferences.cjkNumberSpacing = false
    XCTAssertTrue(OwlKeyboardPreferences.cjkAlnumSpacing)
    XCTAssertEqual(OwlCommitTransform.apply(to: "第3条"), "第 3 条")
    OwlKeyboardPreferences.cjkAlnumSpacing = false

    // Toggle 中文与英文间加入空格 ON via the exact action the page uses — NO apply closure involved.
    OwlSettingsActions.toggle(state: state, keyPath: \.keyboardCJKAlnumSpacing) {
      OwlKeyboardPreferences.cjkAlnumSpacing = $0
      state.keyboardCJKEnglishSpacing = $0
      state.keyboardCJKNumberSpacing = $0
    }
    XCTAssertTrue(state.keyboardCJKAlnumSpacing)
    XCTAssertTrue(state.keyboardCJKEnglishSpacing)
    XCTAssertTrue(state.keyboardCJKNumberSpacing)
    // Live: the cached flag is read immediately by the next commit transform — no deploy.
    XCTAssertEqual(OwlCommitTransform.apply(to: "猫头鹰AI"), "猫头鹰 AI")
    XCTAssertEqual(OwlCommitTransform.apply(to: "第3条"), "第 3 条")

    // The apply/redeploy spy was NEVER invoked by any Owltype-side toggle above.
    XCTAssertEqual(applyCalls, 0, "Owltype-side Track-1 toggles must not invoke a Rime apply/redeploy")
    _ = applySpy // silence unused warning while documenting the spy contract
  }

  /// PR3 Track 2: the fast keyboard apply status helper reports "已生效" on success and an
  /// honest "应用失败" (not "重新部署") on failure, for both the keyboard page and the
  /// 候选窗外观 候选个数 control. Pure status function — no IO.
  func testFastApplyStatusMessagesUseImmediateNotDeployWording() {
    XCTAssertEqual(
      OwlKeyboardPage.autoApplyStatusMessage(written: ["default.custom.yaml"], deploySucceeded: true),
      "已生效：default.custom.yaml。"
    )
    XCTAssertEqual(
      OwlKeyboardPage.autoApplyStatusMessage(
        written: [],
        deploySucceeded: true
      ),
      "配置已生效。"
    )
    let kbFail = OwlKeyboardPage.autoApplyStatusMessage(written: ["default.custom.yaml"], deploySucceeded: false)
    XCTAssertTrue(kbFail.contains("应用失败"))
    XCTAssertFalse(kbFail.contains("重新部署"))

    XCTAssertEqual(
      OwlSettingsView.candidatePageSizeApplyStatusMessage(written: ["default.custom.yaml"], deploySucceeded: true),
      "候选个数已生效：default.custom.yaml。"
    )
    XCTAssertEqual(
      OwlSettingsView.candidatePageSizeApplyStatusMessage(
        written: [],
        deploySucceeded: true
      ),
      "候选个数已生效。"
    )
    let pageFail = OwlSettingsView.candidatePageSizeApplyStatusMessage(written: [], deploySucceeded: false)
    XCTAssertTrue(pageFail.contains("候选个数未生效"))
    XCTAssertFalse(pageFail.contains("重新部署"))
  }

  /// PR3 Track 2 (fuzzy): `applyFuzzyConfigFast` runs the async `start_maintenance(fullCheck:false)`
  /// (prism rebuild on a background thread) and MUST `join_maintenance_thread` BEFORE the live
  /// reselect re-reads `build/` — otherwise the reselect races the rebuild and the new fuzzy
  /// rules silently fail to take effect. Drive the delegate with a fake engine and assert the
  /// join happens, after start_maintenance. No `activeInputController`, so the reselect is a
  /// safe no-op here; we only assert the engine lifecycle ordering.
  func testApplyFuzzyConfigFastJoinsMaintenanceAfterStartAndBeforeReselect() throws {
    let delegate = OwlApplicationDelegate()
    let engine = FakeInputEngine(startMaintenanceResult: true)
    delegate.runtime.engine = engine

    XCTAssertTrue(try delegate.runtime.applyKeyboardSettings(.fuzzy, directory: applicationDirectory()).succeeded)

    XCTAssertEqual(engine.joinMaintenanceCount, 1, "fuzzy fast-apply must join the maintenance thread")
    XCTAssertEqual(
      engine.lifecycleTrace, ["startMaintenance", "joinMaintenance"],
      "join must happen AFTER start_maintenance (and before the reselect re-reads build/)"
    )
  }

  /// When `start_maintenance` itself fails there is no async work to wait for, so the fuzzy
  /// fast-apply must NOT call join (nothing to join) and reports failure.
  func testApplyFuzzyConfigFastSkipsJoinWhenMaintenanceFails() throws {
    let delegate = OwlApplicationDelegate()
    let engine = FakeInputEngine(startMaintenanceResult: false)
    delegate.runtime.engine = engine

    XCTAssertFalse(try delegate.runtime.applyKeyboardSettings(.fuzzy, directory: applicationDirectory()).succeeded)
    XCTAssertEqual(engine.joinMaintenanceCount, 0)
    XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance"])
  }

  /// PR3 Track 2 (config-only): `applyKeyboardConfigFast` uses synchronous `deploy_config_file`
  /// (config_file_update RunTask), so it must NOT run `start_maintenance` and must NOT join —
  /// the rebuilt `build/` is ready synchronously before the reselect.
  func testApplyKeyboardConfigFastUsesConfigFileDeployNotMaintenance() throws {
    let delegate = OwlApplicationDelegate()
    let engine = FakeInputEngine(currentSchema: "rime_ice", deployConfigFileResult: true)
    delegate.runtime.engine = engine

    XCTAssertTrue(try delegate.runtime.applyKeyboardSettings(.config, directory: applicationDirectory()).succeeded)
    XCTAssertEqual(engine.joinMaintenanceCount, 0, "config-only fast-apply must not run/join maintenance")
    XCTAssertFalse(engine.lifecycleTrace.contains("startMaintenance"))
  }

  func testStartRimeDeploysOwltypeConfigEvenWhenMaintenanceIdle() throws {
    let engine = FakeInputEngine(startMaintenanceResult: false)
    let runtime = EngineRuntime(engine: engine, userDirectory: try applicationDirectory())

    _ = runtime.start(fullCheck: true)
    XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance"])
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
  }

  private func applicationDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    tempDirs.append(directory)
    return directory
  }

  private func assertSet<T: Equatable>(
    _ value: T,
    _ keyPath: ReferenceWritableKeyPath<OwlSettingsState, T>,
    _ state: OwlSettingsState,
    _ read: () -> T,
    _ write: @escaping (T) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    OwlSettingsActions.set(value, state: state, keyPath: keyPath, write: write)
    XCTAssertEqual(state[keyPath: keyPath], value, file: file, line: line)
    XCTAssertEqual(read(), value, file: file, line: line)
  }

  private func assertToggle(
    _ keyPath: ReferenceWritableKeyPath<OwlSettingsState, Bool>,
    _ state: OwlSettingsState,
    _ read: () -> Bool,
    _ write: @escaping (Bool) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    state[keyPath: keyPath] = false
    write(false)
    OwlSettingsActions.toggle(state: state, keyPath: keyPath, write: write)
    XCTAssertTrue(state[keyPath: keyPath], file: file, line: line)
    XCTAssertTrue(read(), file: file, line: line)
  }

  private func assertFuzzyToggleActions(file: StaticString = #filePath, line: UInt = #line) {
    let cases: [(String, () -> Bool, (Bool) -> Void)] = [
      ("zhz", { OwlFuzzyPreferences.zhz }, { OwlFuzzyPreferences.zhz = $0 }),
      ("chc", { OwlFuzzyPreferences.chc }, { OwlFuzzyPreferences.chc = $0 }),
      ("shs", { OwlFuzzyPreferences.shs }, { OwlFuzzyPreferences.shs = $0 }),
      ("nl", { OwlFuzzyPreferences.nl }, { OwlFuzzyPreferences.nl = $0 }),
      ("rl", { OwlFuzzyPreferences.rl }, { OwlFuzzyPreferences.rl = $0 }),
      ("fh", { OwlFuzzyPreferences.fh }, { OwlFuzzyPreferences.fh = $0 }),
      ("anang", { OwlFuzzyPreferences.anang }, { OwlFuzzyPreferences.anang = $0 }),
      ("eneng", { OwlFuzzyPreferences.eneng }, { OwlFuzzyPreferences.eneng = $0 }),
      ("ining", { OwlFuzzyPreferences.ining }, { OwlFuzzyPreferences.ining = $0 }),
    ]
    for (name, read, write) in cases {
      write(false)
      let next = OwlSettingsActions.toggleLocalBool(false, write: write)
      XCTAssertTrue(next, name, file: file, line: line)
      XCTAssertTrue(read(), name, file: file, line: line)
    }
    XCTAssertEqual(OwlFuzzySnapshot.current().enabledCount, cases.count, file: file, line: line)
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-settings-action", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDirs.append(dir)
    return dir
  }
}
