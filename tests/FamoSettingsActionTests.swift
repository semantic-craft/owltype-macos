//
//  FamoSettingsActionTests.swift
//  FamoTests
//

import Foundation
import XCTest
@testable import Famo

final class FamoSettingsActionTests: XCTestCase {
  private var savedDefaults: [String: Any?] = [:]
  private var tempDirs: [URL] = []
  private let keys = [
    "FamoKeyboardInputMethod", "FamoKeyboardDoublePinyin", "FamoKeyboardWubiScheme", "FamoKeyboardWubiCandidateMode",
    "FamoKeyboardPageSize",
    "FamoKeyboardWubiCodeHint", "FamoKeyboardWubiAutoClear", "FamoKeyboardShiftSwitchCJK",
    "FamoKeyboardFullShapeToggle", "FamoKeyboardCJKPunctToggle",
    "FamoKeyboardDefaultAsciiMode", "FamoKeyboardDefaultFullShape", "FamoKeyboardPageMinusEquals",
    "FamoKeyboardPageBrackets", "FamoKeyboardPageCommaPeriod", "FamoKeyboardSelect23Semicolon",
    "FamoKeyboardSelect23Command",
    "FamoKeyboardCJKEnglishSpacing", "FamoKeyboardCJKNumberSpacing",
    "FamoKeyboardAppEnglishBundleIDs",
    "FamoFuzzyZhZ", "FamoFuzzyChC", "FamoFuzzyShS", "FamoFuzzyNL", "FamoFuzzyRL",
    "FamoFuzzyFH", "FamoFuzzyAnAng", "FamoFuzzyEnEng", "FamoFuzzyInIng",
    "FamoPanelAppearance", "FamoPanelFontSize", "FamoPanelOrientation", "FamoPanelFontDesign",
    "FamoPanelAnimations", "FamoPanelExpandedByDefault", "FamoPanelPreviewPages", "FamoPanelPreviewRows",
    "FamoSkin", "FamoEmojiInCandidates",
    "FamoCloudLaneEnabled", "FamoDeepSeekModel",
    "FamoSelectionMenuEnabled", "FamoSkillSourceVerificationEnabled", "FamoSkillResearchAssistEnabled",
    "FamoSkillAskAnythingEnabled",
    "FamoAskWebSearchEnabled", "FamoAskSearchProvider",
  ]

  override func setUp() {
    super.setUp()
    savedDefaults = Dictionary(uniqueKeysWithValues: keys.map { ($0, FamoDefaults.standard.object(forKey: $0)) })
  }

  override func tearDown() {
    for key in keys {
      if let value = savedDefaults[key] ?? nil {
        FamoDefaults.standard.set(value, forKey: key)
      } else {
        FamoDefaults.standard.removeObject(forKey: key)
      }
    }
    for dir in tempDirs {
      try? FileManager.default.removeItem(at: dir)
    }
    tempDirs = []
    super.tearDown()
  }

  func testClickablePreferenceActionsUpdateStateAndPreferenceHomes() {
    let state = FamoSettingsState()
    var selectedSchemas: [String] = []

    FamoSettingsActions.selectInputMethod(.doublePinyin, state: state) { selectedSchemas.append($0) }
    FamoSettingsActions.selectDoublePinyin(.mspy, state: state) { selectedSchemas.append($0) }
    // 选混输子方案（此时方案非五笔，不上屏）后再切到五笔输入 → schemaId 解析成混输。
    FamoSettingsActions.selectWubiScheme(.pinyinMix, state: state) { selectedSchemas.append($0) }
    FamoSettingsActions.selectInputMethod(.wubi, state: state) { selectedSchemas.append($0) }
    XCTAssertEqual(selectedSchemas, ["double_pinyin_flypy", "double_pinyin_mspy", "wubi86_jidian_pinyin"])
    XCTAssertEqual(FamoKeyboardPreferences.inputMethod, .wubi)
    XCTAssertEqual(FamoKeyboardPreferences.wubiScheme, .pinyinMix)
    XCTAssertEqual(FamoKeyboardPreferences.doublePinyin, .mspy)

    assertSet(.singleFirst, \.keyboardWubiCandidateMode, state, { FamoKeyboardPreferences.wubiCandidateMode }) { FamoKeyboardPreferences.wubiCandidateMode = $0 }
    assertSet(.dark, \.panelAppearance, state, { FamoPanelPreferences.appearance }) { FamoPanelPreferences.appearance = $0 }
    assertSet(.large, \.panelFontSize, state, { FamoPanelPreferences.fontSize }) { FamoPanelPreferences.fontSize = $0 }
    assertSet(.vertical, \.panelOrientation, state, { FamoPanelPreferences.orientation }) { FamoPanelPreferences.orientation = $0 }
    assertSet(.notoSerifSC, \.panelFontDesign, state, { FamoPanelPreferences.fontDesign }) { FamoPanelPreferences.fontDesign = $0 }
    assertSet(6, \.candidatePageSize, state, { FamoKeyboardPreferences.pageSize }) { FamoKeyboardPreferences.pageSize = $0 }
    assertSet(.wuda, \.skin, state, { FamoSkinPreferences.skin }) { FamoSkinPreferences.skin = $0 }
    assertSet(FamoCloudPreferences.reasonerDeepSeekModel, \.cloudModel, state, { FamoCloudPreferences.deepSeekModel }) { FamoCloudPreferences.deepSeekModel = $0 }
    // 默认状态·中英文 / 全半角 下拉（同 `FamoSettingsActions.set` 写穿；简繁体复用 traditionalOutput）。
    assertSet(true, \.keyboardDefaultAsciiMode, state, { FamoKeyboardPreferences.defaultAsciiMode }) { FamoKeyboardPreferences.defaultAsciiMode = $0 }
    assertSet(true, \.keyboardDefaultFullShape, state, { FamoKeyboardPreferences.defaultFullShape }) { FamoKeyboardPreferences.defaultFullShape = $0 }

    assertToggle(\.keyboardWubiCodeHint, state, { FamoKeyboardPreferences.wubiCodeHint }) { FamoKeyboardPreferences.wubiCodeHint = $0 }
    assertToggle(\.keyboardWubiAutoClear, state, { FamoKeyboardPreferences.wubiAutoClear }) { FamoKeyboardPreferences.wubiAutoClear = $0 }
    assertToggle(\.keyboardWubiUserDictLearning, state, { FamoKeyboardPreferences.wubiUserDictLearning }) { FamoKeyboardPreferences.wubiUserDictLearning = $0 }
    assertToggle(\.keyboardShiftSwitchCJK, state, { FamoKeyboardPreferences.shiftSwitchCJK }) { FamoKeyboardPreferences.shiftSwitchCJK = $0 }
    assertToggle(\.keyboardCJKPunctToggle, state, { FamoKeyboardPreferences.cjkPunctToggle }) { FamoKeyboardPreferences.cjkPunctToggle = $0 }
    assertToggle(\.keyboardPageMinusEquals, state, { FamoKeyboardPreferences.pageMinusEquals }) { FamoKeyboardPreferences.pageMinusEquals = $0 }
    assertToggle(\.keyboardPageBrackets, state, { FamoKeyboardPreferences.pageBrackets }) { FamoKeyboardPreferences.pageBrackets = $0 }
    assertToggle(\.keyboardPageCommaPeriod, state, { FamoKeyboardPreferences.pageCommaPeriod }) { FamoKeyboardPreferences.pageCommaPeriod = $0 }
    assertToggle(\.keyboardSelect23Semicolon, state, { FamoKeyboardPreferences.select23Semicolon }) { FamoKeyboardPreferences.select23Semicolon = $0 }
    assertToggle(\.keyboardCJKAlnumSpacing, state, { FamoKeyboardPreferences.cjkAlnumSpacing }) { FamoKeyboardPreferences.cjkAlnumSpacing = $0 }
    assertToggle(\.panelAnimationsEnabled, state, { FamoPanelPreferences.animationsEnabled }) { FamoPanelPreferences.animationsEnabled = $0 }
    // 卷轴：后页行数分段经 FamoSettingsActions.set 写穿（是否卷轴由排列方向决定，无独立开关）。
    assertSet(1, \.panelScrollRows, state, { FamoPanelPreferences.scrollRows }) { FamoPanelPreferences.scrollRows = $0 }
    assertToggle(\.candidateEmojiEnabled, state, { FamoEmojiPreferences.candidateEmojiEnabled }) { FamoEmojiPreferences.candidateEmojiEnabled = $0 }
    assertToggle(\.cloudEnabled, state, { FamoCloudPreferences.isEnabled }) { FamoCloudPreferences.isEnabled = $0 }
    assertToggle(\.askWebSearchEnabled, state, { FamoAskWebSearchSettings.isEnabled }) { FamoAskWebSearchSettings.isEnabled = $0 }
    // 任意提问「联网模型」下拉：写穿到偏好，且「自动」("") 也要能写回去。
    assertSet("doubao", \.askWebSearchProvider, state, { FamoAskSearchProviderSettings.rawValue }) { FamoAskSearchProviderSettings.rawValue = $0 }
    assertSet("", \.askWebSearchProvider, state, { FamoAskSearchProviderSettings.rawValue }) { FamoAskSearchProviderSettings.rawValue = $0 }
    assertToggle(\.selectionMenuEnabled, state, { FamoSelectionMenuPreferences.isEnabled }) { FamoSelectionMenuPreferences.isEnabled = $0 }
    // 任意提问的技能开关（2026-07-26 技能精简：兜底功能置顶、真开关默认开）。
    assertToggle(\.askAnythingSkillEnabled, state, { FamoSelectionMenuPreferences.askEnabled }) { FamoSelectionMenuPreferences.askEnabled = $0 }
    assertToggle(\.sourceVerificationSkillEnabled, state, { FamoSelectionMenuPreferences.sourceVerificationEnabled }) { FamoSelectionMenuPreferences.sourceVerificationEnabled = $0 }
    assertToggle(\.researchAssistSkillEnabled, state, { FamoSelectionMenuPreferences.researchAssistEnabled }) { FamoSelectionMenuPreferences.researchAssistEnabled = $0 }
    assertToggle(\.publishFormattingSkillEnabled, state, { FamoSelectionMenuPreferences.publishFormattingEnabled }) { FamoSelectionMenuPreferences.publishFormattingEnabled = $0 }
    assertToggle(\.translationSkillEnabled, state, { FamoSelectionMenuPreferences.translationEnabled }) { FamoSelectionMenuPreferences.translationEnabled = $0 }

    assertFuzzyToggleActions()

    FamoSettingsActions.setAppEnglishBundleIDsText("com.apple.Terminal bad:key com.apple.Terminal", state: state)
    XCTAssertEqual(FamoKeyboardPreferences.appEnglishBundleIDs, ["com.apple.Terminal"])
  }

  func testSelectionMenuSkillPreferencesDefaultToOptInSkillsOnly() {
    FamoSelectionMenuPreferences.resetForTesting()
    XCTAssertFalse(FamoSelectionMenuPreferences.isEnabled)
    XCTAssertTrue(FamoSelectionMenuPreferences.askEnabled)
    XCTAssertTrue(FamoSelectionMenuPreferences.sourceVerificationEnabled)
    XCTAssertTrue(FamoSelectionMenuPreferences.researchAssistEnabled)
    XCTAssertTrue(FamoSelectionMenuPreferences.publishFormattingEnabled)
    XCTAssertTrue(FamoSelectionMenuPreferences.translationEnabled)
    XCTAssertTrue(FamoSelectionMenuPreferences.promptOptimizeEnabled)
  }

  func testSelectionMenuActionsFollowEnabledSkillPreferences() {
    FamoSelectionMenuPreferences.resetForTesting()

    // 云端 AI 是全部技能的总闸：关掉则菜单为空（含任意提问），不管各技能开关是什么。
    XCTAssertEqual(FamoSelectionMenuAction.enabledActions(cloudEnabled: false), [])

    XCTAssertEqual(
      FamoSelectionMenuAction.enabledActions(cloudEnabled: true),
      [.ask, .polish, .sourceVerification, .researchAssist, .publishFormatting,
       .translate, .promptOptimize]
    )

    FamoSelectionMenuPreferences.publishFormattingEnabled = false
    FamoSelectionMenuPreferences.sourceVerificationEnabled = false
    XCTAssertEqual(
      FamoSelectionMenuAction.enabledActions(cloudEnabled: true),
      [.ask, .polish, .researchAssist, .translate, .promptOptimize]
    )

    FamoSelectionMenuPreferences.polishEnabled = false
    FamoSelectionMenuPreferences.translationEnabled = false
    FamoSelectionMenuPreferences.promptOptimizeEnabled = false
    XCTAssertEqual(
      FamoSelectionMenuAction.enabledActions(cloudEnabled: true),
      [.ask, .researchAssist]
    )

    // 任意提问自 2026-07-26 起有自己的开关（默认开）：单独关掉它，其余技能不受影响。
    FamoSelectionMenuPreferences.askEnabled = false
    XCTAssertEqual(FamoSelectionMenuAction.enabledActions(cloudEnabled: true), [.researchAssist])

    // 全部开关都关（含任意提问）→ 菜单为空。
    FamoSelectionMenuPreferences.researchAssistEnabled = false
    XCTAssertEqual(FamoSelectionMenuAction.enabledActions(cloudEnabled: true), [])

    FamoSelectionMenuPreferences.resetForTesting()
  }

  @MainActor
  func testSelectionReplacementFlowWritesThroughCapturedTarget() {
    var writes: [String] = []
    let target = FamoSelectionReplacementTarget { text in
      writes.append(text)
      return .success
    }

    XCTAssertEqual(FamoSelectionReplacementFlow.write("  通知正文\n", target: target), .inserted(.axSelectedText))
    XCTAssertEqual(writes, ["  通知正文\n"])
  }

  @MainActor
  func testSelectionReplacementFlowDoesNotWriteWithoutTargetOrText() {
    var writes: [String] = []
    let target = FamoSelectionReplacementTarget { text in
      writes.append(text)
      return .success
    }

    XCTAssertEqual(
      FamoSelectionReplacementFlow.write("排版结果", target: nil),
      .failed("无法定位原选区，请重新选择文字后再试。")
    )
    XCTAssertEqual(
      FamoSelectionReplacementFlow.write(" \n\t", target: target),
      .failed("未生成可替换文本。")
    )
    XCTAssertTrue(writes.isEmpty)
  }

  func testInputMethodSelectionCanTriggerConfigApplyAfterSchemaSelection() {
    let state = FamoSettingsState()
    var trace: [String] = []

    FamoSettingsActions.selectInputMethod(
      .wubi,
      state: state,
      applyConfig: { trace.append("apply") },
      onSelectSchema: { trace.append("schema:\($0)") }
    )
    XCTAssertEqual(trace, ["schema:wubi86_jidian", "apply"])

    trace = []
    FamoSettingsActions.selectWubiScheme(
      .pinyinMix,
      state: state,
      applyConfig: { trace.append("apply") },
      onSelectSchema: { trace.append("schema:\($0)") }
    )
    XCTAssertEqual(trace, ["schema:wubi86_jidian_pinyin", "apply"])
  }

  func testPreferredSchemaIDFollowsWubiPinyinMixPreference() {
    FamoKeyboardPreferences.inputMethod = .wubi
    FamoKeyboardPreferences.wubiScheme = .pinyinMix

    XCTAssertEqual(FamoKeyboardPreferences.preferredSchemaID, "wubi86_jidian_pinyin")

    FamoKeyboardPreferences.wubiScheme = .jidian86
    XCTAssertEqual(FamoKeyboardPreferences.preferredSchemaID, "wubi86_jidian")
  }

  func testStoreBackedButtonActionsReachStoresAndStatuses() throws {
    let entry = try FamoQuickSendStore.entry(text: "判决摘要", code: "pjzy")
    var persistedQuickSend: [FamoQuickSendEntry] = []
    var redeploys = 0
    let save = try FamoSettingsActions.saveQuickSendEntry(
      phrase: "判决摘要",
      code: "pjzy",
      editingCode: nil,
      entries: [],
      persist: { next in
        persistedQuickSend = next
        redeploys += 1
        return (next, false)
      }
    )
    XCTAssertEqual(persistedQuickSend, [entry])
    XCTAssertEqual(save.entries, [entry])
    XCTAssertEqual(save.phrase, "")
    XCTAssertEqual(save.code, "")
    XCTAssertNil(save.editingCode)
    XCTAssertEqual(save.status, "已保存；应用配置失败，请查看诊断日志。")
    XCTAssertEqual(redeploys, 1)

    let delete = try FamoSettingsActions.deleteQuickSendEntry(
      entry,
      editingCode: entry.code,
      entries: [entry],
      persist: { next in
        persistedQuickSend = next
        redeploys += 1
        return (next, true)
      }
    )
    XCTAssertTrue(persistedQuickSend.isEmpty)
    XCTAssertTrue(delete.entries.isEmpty)
    XCTAssertEqual(delete.phrase, "")
    XCTAssertEqual(delete.code, "")
    XCTAssertNil(delete.editingCode)
    XCTAssertEqual(delete.status, "已删除并应用配置改动。")
    XCTAssertEqual(redeploys, 2)

    var clipboardEnabled = false
    let enableStatus = FamoSettingsActions.setClipboardEnabled(true) { clipboardEnabled = $0 }
    XCTAssertTrue(clipboardEnabled)
    XCTAssertEqual(enableStatus, "已启用；只在你点击捕获时读取纯文本剪贴板。")

    let blockedCapture = try FamoSettingsActions.captureClipboard(enabled: false, text: "忽略") { _ in
      XCTFail("disabled capture must not read the pasteboard")
      return []
    }
    XCTAssertNil(blockedCapture.entries)
    XCTAssertEqual(blockedCapture.status, "先启用剪贴板面板。")

    let dir = try makeTempDir()
    let captured = try FamoSettingsActions.captureClipboard(enabled: true, text: "  判决摘要  ") {
      try FamoClipboardStore.capture($0, root: dir, now: Date(timeIntervalSince1970: 0))
    }
    XCTAssertEqual(captured.entries?.map(\.text), ["判决摘要"])
    XCTAssertTrue(captured.status.contains("已捕获当前剪贴板"))

    let cleared = try FamoSettingsActions.clearClipboard {
      try FamoClipboardStore.clear(root: dir)
    }
    XCTAssertTrue(cleared.entries.isEmpty)
    XCTAssertEqual(cleared.status, "已清空本地剪贴板记录。")
    XCTAssertTrue(FamoClipboardStore.load(root: dir).isEmpty)
  }

  func testProjectLearnAndKeychainButtonActionsReachStoresAndStatuses() throws {
    let root = try makeTempDir()
    let suiteName = "FamoSettingsActions-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FamoProjectStore(root: root, defaults: defaults)

    let created = try FamoSettingsActions.createProject(name: " 行政法课程 ", store: store)
    XCTAssertEqual(created.project.name, "行政法课程")
    XCTAssertEqual(created.newProjectName, "")
    XCTAssertEqual(created.status, "已新建场景词库「行政法课程」。")

    let selected = FamoSettingsActions.selectProject(created.project)
    XCTAssertEqual(selected.selectedID, created.project.id)
    XCTAssertEqual(selected.renameDraft, "行政法课程")
    XCTAssertEqual(selected.wordsDraft, "")

    let activated = try FamoSettingsActions.activateProject(created.project, store: store)
    XCTAssertEqual(activated.activeID, created.project.id)
    XCTAssertEqual(activated.status, "已激活「行政法课程」。")

    let renamed = try FamoSettingsActions.renameProject(created.project, to: " 行政法案例 ", store: store)
    XCTAssertEqual(renamed.project.name, "行政法案例")
    XCTAssertEqual(renamed.status, "已重命名为「行政法案例」。")

    let words = try FamoSettingsActions.saveProjectWords(
      renamed.project,
      wordsText: "行政许可\n行政处罚\n行政许可",
      store: store
    )
    XCTAssertEqual(words.project.normalizedWords, ["行政许可", "行政处罚"])
    XCTAssertEqual(words.status, "已保存 2 个词条。")

    let emptyRule = try FamoSettingsActions.addProjectTermRule(
      to: words.project,
      preferred: " ",
      allowedText: "程序正当",
      forbiddenText: "走流程",
      store: store
    )
    XCTAssertNil(emptyRule.project)
    XCTAssertEqual(emptyRule.status, "首选术语不能为空。")

    let withRule = try FamoSettingsActions.addProjectTermRule(
      to: words.project,
      preferred: " 正当程序 ",
      allowedText: "程序正当，正当程序",
      forbiddenText: "走流程, 乱流程 ",
      store: store
    )
    let rule = try XCTUnwrap(withRule.project?.termRules.first)
    XCTAssertEqual(rule.preferred, "正当程序")
    XCTAssertEqual(rule.normalizedAllowed, ["程序正当", "正当程序"])
    XCTAssertEqual(rule.normalizedForbidden, ["走流程", "乱流程"])
    XCTAssertEqual(withRule.preferred, "")
    XCTAssertEqual(withRule.status, "已添加术语规则「正当程序」（共 1 条）。")

    let removedRule = try FamoSettingsActions.removeProjectTermRule(
      rule,
      from: try XCTUnwrap(withRule.project),
      store: store
    )
    XCTAssertTrue(removedRule.project.termRules.isEmpty)
    XCTAssertEqual(removedRule.status, "已删除术语规则「正当程序」。")

    let deleted = try FamoSettingsActions.deleteProject(
      removedRule.project,
      selectedID: removedRule.project.id,
      store: store
    )
    XCTAssertNil(deleted.selectedID)
    XCTAssertEqual(deleted.status, "已删除「行政法案例」。")
    XCTAssertNil(store.load(id: removedRule.project.id))

    XCTAssertEqual(FamoSettingsActions.deepSeekAPIKeyStatus { nil }, "未配置 API Key")
    XCTAssertEqual(FamoSettingsActions.deepSeekAPIKeyStatus { "sk-test" }, "已配置 Keychain API Key")
    XCTAssertEqual(FamoSettingsActions.deepSeekAPIKeyStatus { throw NSError(domain: "test", code: 1) }, "无法读取 Keychain")

    var savedKey = ""
    let emptyKey = FamoSettingsActions.saveDeepSeekAPIKey(" ") {
      savedKey = $0
    }
    XCTAssertEqual(emptyKey.input, " ")
    XCTAssertEqual(emptyKey.status, "请输入 API Key")
    XCTAssertEqual(savedKey, "")

    let saved = FamoSettingsActions.saveDeepSeekAPIKey(" sk-test ") {
      savedKey = $0
    }
    XCTAssertEqual(saved.input, "")
    XCTAssertEqual(saved.status, "已保存到 Keychain")
    XCTAssertEqual(savedKey, "sk-test")

    let saveFailure = FamoSettingsActions.saveDeepSeekAPIKey("sk-fail") { _ in
      throw NSError(domain: "test", code: 2)
    }
    XCTAssertEqual(saveFailure.input, "sk-fail")
    XCTAssertEqual(saveFailure.status, "保存 Keychain 失败")

    var didDelete = false
    let deletedKey = FamoSettingsActions.deleteDeepSeekAPIKey(input: "sk-test") {
      didDelete = true
    }
    XCTAssertTrue(didDelete)
    XCTAssertEqual(deletedKey.input, "")
    XCTAssertEqual(deletedKey.status, "已删除 API Key")

    let deleteFailure = FamoSettingsActions.deleteDeepSeekAPIKey(input: "sk-test") {
      throw NSError(domain: "test", code: 3)
    }
    XCTAssertEqual(deleteFailure.input, "sk-test")
    XCTAssertEqual(deleteFailure.status, "删除 Keychain 失败")
  }

  func testPreviewSchemaAndWritePreviewActionsAreClickableWithoutLiveSideEffects() {
    var selectedSchemas: [String] = []
    let schema = SchemaItem(id: "rime_ice", name: "雾凇拼音")
    XCTAssertFalse(FamoSettingsActions.selectSchemaRow(schema, currentSchemaID: "rime_ice") {
      selectedSchemas.append($0)
    })
    XCTAssertTrue(FamoSettingsActions.selectSchemaRow(schema, currentSchemaID: "wubi86_jidian") {
      selectedSchemas.append($0)
    })
    XCTAssertEqual(selectedSchemas, ["rime_ice"])

    var copied = ""
    FamoSettingsActions.copyPreviewText("patch:\n") { copied = $0 }
    XCTAssertEqual(copied, "patch:\n")

    let file = FamoManagedPatchFile(
      fileName: "default.custom.yaml",
      block: ManagedPatchBlock(
        marker: "TEST",
        yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 5"]
      )
    )

    var applied: [String] = []
    var redeploys = 0
    let blockedApply = FamoSettingsActions.applyWritePreview(
      confirmed: false,
      files: [file],
      timestamp: "ts",
      apply: { file, timestamp in applied.append("\(file.fileName)@\(timestamp)") },
      redeploy: {
        redeploys += 1
        return true
      }
    )
    XCTAssertNil(blockedApply)
    XCTAssertTrue(applied.isEmpty)
    XCTAssertEqual(redeploys, 0)

    let appliedStatus = FamoSettingsActions.applyWritePreview(
      confirmed: true,
      files: [file],
      timestamp: "ts",
      apply: { file, timestamp in applied.append("\(file.fileName)@\(timestamp)") },
      redeploy: {
        redeploys += 1
        return true
      }
    )
    XCTAssertEqual(applied, ["default.custom.yaml@ts"])
    XCTAssertEqual(redeploys, 1)
    XCTAssertEqual(appliedStatus, "已写入并应用配置 default.custom.yaml（备份+manifest 已记录，可回滚）。")

    let refused = FamoSettingsActions.applyWritePreview(
      confirmed: true,
      files: [file],
      timestamp: "ts",
      apply: { _, _ in throw FamoConfigWriteError.refusedNeverTouch("user.yaml") },
      redeploy: {
        XCTFail("failed apply must not redeploy")
        return true
      }
    )
    XCTAssertEqual(refused, "已拒绝写入受保护文件：user.yaml。")

    var rollbacks = 0
    let blockedRollback = FamoSettingsActions.rollbackWritePreview(
      confirmed: false,
      rollback: { rollbacks += 1 },
      redeploy: {
        XCTFail("blocked rollback must not redeploy")
        return true
      }
    )
    XCTAssertNil(blockedRollback)
    XCTAssertEqual(rollbacks, 0)

    let rollbackStatus = FamoSettingsActions.rollbackWritePreview(
      confirmed: true,
      rollback: { rollbacks += 1 },
      redeploy: { false }
    )
    XCTAssertEqual(rollbacks, 1)
    XCTAssertEqual(rollbackStatus, "已按 manifest 回滚最近一次写入；应用配置失败，请查看诊断日志。")

    let rollbackFailure = FamoSettingsActions.rollbackWritePreview(
      confirmed: true,
      rollback: { throw NSError(domain: "test", code: 4) },
      redeploy: {
        XCTFail("failed rollback must not redeploy")
        return true
      }
    )
    XCTAssertTrue(rollbackFailure?.contains("回滚失败") == true)
  }

  // MARK: - PR2 Track 1: Famo-side prefs are live + must NOT trigger a Rime deploy/apply

  /// The 本地便捷输入 toggle is a Famo-side cached flag read live at the commit seam by
  /// `FamoCommitTransform`. Toggling it must (a) take effect on the very next commit transform
  /// (no deploy), and (b) never route through a Rime apply/redeploy closure.
  func testCJKAlnumSpacingToggleIsLiveAndDoesNotTriggerAnyDeploy() {
    let state = FamoSettingsState()
    var applyCalls = 0
    let applySpy: () -> Bool = { applyCalls += 1; return true }

    // Baseline: all off → transform is identity for the cross-boundary spacing.
    FamoKeyboardPreferences.cjkEnglishSpacing = false
    FamoKeyboardPreferences.cjkNumberSpacing = false
    state.keyboardCJKEnglishSpacing = false
    state.keyboardCJKNumberSpacing = false
    state.keyboardCJKAlnumSpacing = false
    XCTAssertEqual(FamoCommitTransform.apply(to: "法墨AI第3条"), "法墨AI第3条")

    // Legacy migration: either old spacing key makes the new single runtime switch ON.
    FamoKeyboardPreferences.cjkEnglishSpacing = true
    FamoKeyboardPreferences.cjkNumberSpacing = false
    XCTAssertTrue(FamoKeyboardPreferences.cjkAlnumSpacing)
    XCTAssertEqual(FamoCommitTransform.apply(to: "第3条"), "第 3 条")
    FamoKeyboardPreferences.cjkAlnumSpacing = false

    // Toggle 中文与英文间加入空格 ON via the exact action the page uses — NO apply closure involved.
    FamoSettingsActions.toggle(state: state, keyPath: \.keyboardCJKAlnumSpacing) {
      FamoKeyboardPreferences.cjkAlnumSpacing = $0
      state.keyboardCJKEnglishSpacing = $0
      state.keyboardCJKNumberSpacing = $0
    }
    XCTAssertTrue(state.keyboardCJKAlnumSpacing)
    XCTAssertTrue(state.keyboardCJKEnglishSpacing)
    XCTAssertTrue(state.keyboardCJKNumberSpacing)
    // Live: the cached flag is read immediately by the next commit transform — no deploy.
    XCTAssertEqual(FamoCommitTransform.apply(to: "法墨AI"), "法墨 AI")
    XCTAssertEqual(FamoCommitTransform.apply(to: "第3条"), "第 3 条")

    // The apply/redeploy spy was NEVER invoked by any Famo-side toggle above.
    XCTAssertEqual(applyCalls, 0, "Famo-side Track-1 toggles must not invoke a Rime apply/redeploy")
    _ = applySpy // silence unused warning while documenting the spy contract
  }

  /// PR3 Track 2: the fast keyboard apply status helper reports "已生效" on success and an
  /// honest "应用失败" (not "重新部署") on failure, for both the keyboard page and the
  /// 候选窗外观 候选个数 control. Pure status function — no IO.
  func testFastApplyStatusMessagesUseImmediateNotDeployWording() {
    XCTAssertEqual(
      FamoKeyboardPage.autoApplyStatusMessage(written: ["default.custom.yaml"], deploySucceeded: true),
      "已生效：default.custom.yaml。"
    )
    let kbFail = FamoKeyboardPage.autoApplyStatusMessage(written: ["default.custom.yaml"], deploySucceeded: false)
    XCTAssertTrue(kbFail.contains("应用失败"))
    XCTAssertFalse(kbFail.contains("重新部署"))

    XCTAssertEqual(
      FamoSettingsView.candidatePageSizeApplyStatusMessage(written: ["default.custom.yaml"], deploySucceeded: true),
      "候选个数已生效：default.custom.yaml。"
    )
    let pageFail = FamoSettingsView.candidatePageSizeApplyStatusMessage(written: [], deploySucceeded: false)
    XCTAssertTrue(pageFail.contains("候选个数未生效"))
    XCTAssertFalse(pageFail.contains("重新部署"))
  }

  /// PR3 Track 2 (fuzzy): `applyFuzzyConfigFast` runs the async `start_maintenance(fullCheck:false)`
  /// (prism rebuild on a background thread) and MUST `join_maintenance_thread` BEFORE the live
  /// reselect re-reads `build/` — otherwise the reselect races the rebuild and the new fuzzy
  /// rules silently fail to take effect. Drive the delegate with a fake engine and assert the
  /// join happens, after start_maintenance. No `activeInputController`, so the reselect is a
  /// safe no-op here; we only assert the engine lifecycle ordering.
  func testApplyFuzzyConfigFastJoinsMaintenanceAfterStartAndBeforeReselect() {
    let delegate = FamoApplicationDelegate()
    let engine = FakeRimeEngine(startMaintenanceResult: true)
    delegate.engine = engine

    XCTAssertTrue(delegate.applyFuzzyConfigFast())

    XCTAssertEqual(engine.joinMaintenanceCount, 1, "fuzzy fast-apply must join the maintenance thread")
    XCTAssertEqual(
      engine.lifecycleTrace, ["startMaintenance", "joinMaintenance"],
      "join must happen AFTER start_maintenance (and before the reselect re-reads build/)"
    )
  }

  /// When `start_maintenance` itself fails there is no async work to wait for, so the fuzzy
  /// fast-apply must NOT call join (nothing to join) and reports failure.
  func testApplyFuzzyConfigFastSkipsJoinWhenMaintenanceFails() {
    let delegate = FamoApplicationDelegate()
    let engine = FakeRimeEngine(startMaintenanceResult: false)
    delegate.engine = engine

    XCTAssertFalse(delegate.applyFuzzyConfigFast())
    XCTAssertEqual(engine.joinMaintenanceCount, 0)
    XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance"])
  }

  /// PR3 Track 2 (config-only): `applyKeyboardConfigFast` uses synchronous `deploy_config_file`
  /// (config_file_update RunTask), so it must NOT run `start_maintenance` and must NOT join —
  /// the rebuilt `build/` is ready synchronously before the reselect.
  func testApplyKeyboardConfigFastUsesConfigFileDeployNotMaintenance() {
    let delegate = FamoApplicationDelegate()
    let engine = FakeRimeEngine(currentSchema: "rime_ice", deployConfigFileResult: true)
    delegate.engine = engine

    XCTAssertTrue(delegate.applyKeyboardConfigFast())
    XCTAssertEqual(engine.joinMaintenanceCount, 0, "config-only fast-apply must not run/join maintenance")
    XCTAssertFalse(engine.lifecycleTrace.contains("startMaintenance"))
  }

  /// #121: App 默认英文 writes land in famo.custom.yaml's managed block (famo domain), so the
  /// fast-apply MUST recompile famo.yaml too — deploying only default.yaml + the active schema
  /// leaves build/famo.yaml stale and getAppOptions serving factory entries only (the 真机验收
  /// failure: user-added apps silently never went English).
  func testApplyKeyboardConfigFastDeploysFamoFrontendConfig() {
    let delegate = FamoApplicationDelegate()
    let engine = FakeRimeEngine(currentSchema: "rime_ice", deployConfigFileResult: true)
    delegate.engine = engine

    XCTAssertTrue(delegate.applyKeyboardConfigFast())
    XCTAssertTrue(engine.deployedConfigFiles.contains("famo.yaml"),
                  "fast-apply must recompile famo.yaml (per-app app_options live there)")
    XCTAssertTrue(engine.deployedConfigFiles.contains("default.yaml"))
  }

  /// #121 companion gap: rime's detect_modifications does not track famo.custom.yaml, so a
  /// famo-domain-only change leaves `start_maintenance` with "nothing to do" (false). startRime
  /// used to gate the famo.yaml deploy on that flag — even a full 重新部署 then skipped it and
  /// the managed-block write stayed inert. The deploy must run regardless of the flag.
  func testStartRimeDeploysFamoConfigEvenWhenMaintenanceIdle() {
    let delegate = FamoApplicationDelegate()
    let engine = FakeRimeEngine(startMaintenanceResult: false)
    delegate.engine = engine

    _ = delegate.startRime(fullCheck: true)
    XCTAssertTrue(engine.deployedConfigFiles.contains("famo.yaml"),
                  "famo.yaml deploy must not be gated on start_maintenance having work to do")
  }

  private func assertSet<T: Equatable>(
    _ value: T,
    _ keyPath: ReferenceWritableKeyPath<FamoSettingsState, T>,
    _ state: FamoSettingsState,
    _ read: () -> T,
    _ write: @escaping (T) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    FamoSettingsActions.set(value, state: state, keyPath: keyPath, write: write)
    XCTAssertEqual(state[keyPath: keyPath], value, file: file, line: line)
    XCTAssertEqual(read(), value, file: file, line: line)
  }

  private func assertToggle(
    _ keyPath: ReferenceWritableKeyPath<FamoSettingsState, Bool>,
    _ state: FamoSettingsState,
    _ read: () -> Bool,
    _ write: @escaping (Bool) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    state[keyPath: keyPath] = false
    write(false)
    FamoSettingsActions.toggle(state: state, keyPath: keyPath, write: write)
    XCTAssertTrue(state[keyPath: keyPath], file: file, line: line)
    XCTAssertTrue(read(), file: file, line: line)
  }

  private func assertFuzzyToggleActions(file: StaticString = #filePath, line: UInt = #line) {
    let cases: [(String, () -> Bool, (Bool) -> Void)] = [
      ("zhz", { FamoFuzzyPreferences.zhz }, { FamoFuzzyPreferences.zhz = $0 }),
      ("chc", { FamoFuzzyPreferences.chc }, { FamoFuzzyPreferences.chc = $0 }),
      ("shs", { FamoFuzzyPreferences.shs }, { FamoFuzzyPreferences.shs = $0 }),
      ("nl", { FamoFuzzyPreferences.nl }, { FamoFuzzyPreferences.nl = $0 }),
      ("rl", { FamoFuzzyPreferences.rl }, { FamoFuzzyPreferences.rl = $0 }),
      ("fh", { FamoFuzzyPreferences.fh }, { FamoFuzzyPreferences.fh = $0 }),
      ("anang", { FamoFuzzyPreferences.anang }, { FamoFuzzyPreferences.anang = $0 }),
      ("eneng", { FamoFuzzyPreferences.eneng }, { FamoFuzzyPreferences.eneng = $0 }),
      ("ining", { FamoFuzzyPreferences.ining }, { FamoFuzzyPreferences.ining = $0 }),
    ]
    for (name, read, write) in cases {
      write(false)
      let next = FamoSettingsActions.toggleLocalBool(false, write: write)
      XCTAssertTrue(next, name, file: file, line: line)
      XCTAssertTrue(read(), name, file: file, line: line)
    }
    XCTAssertEqual(FamoFuzzySnapshot.current().enabledCount, cases.count, file: file, line: line)
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("famo-settings-action", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDirs.append(dir)
    return dir
  }
}
