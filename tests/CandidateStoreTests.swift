//
//  CandidateStoreTests.swift
//  OwltypeTests — candidate provenance, shared cloud base, commit transforms, panel display and
//  selection polish. No network, no engine.
//

import AppKit
import SwiftUI
import XCTest
@testable import Owltype

/// G3 provenance tags the candidate panel renders.
final class ProvenanceTests: XCTestCase {
  func testAINeedsConfirmation() {
    XCTAssertTrue(OwlProvenance.ai.needsConfirmation)
    XCTAssertFalse(OwlProvenance.project.needsConfirmation)
  }
}

/// Shared cloud-AI base coverage: the canonical DeepSeek model mapping, the error→message
/// strings, the usage telemetry, the numbered-rewrite parser, and the retry-policy classifier.
/// All are used by the kept 划词润色 / 任意提问 paths; the candidate pipeline is gone.
@MainActor
final class OwlCloudSharedBaseTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlCloudPreferences.resetForTesting()
    OwlCloudUsageTelemetry.resetForTesting()
  }

  override func tearDown() async throws {
    OwlCloudPreferences.resetForTesting()
    OwlCloudUsageTelemetry.resetForTesting()
    try await super.tearDown()
  }

  func testDeepSeekModelDefaultsToV4AndCanonicalizesLegacyAliases() {
    XCTAssertEqual(OwlCloudPreferences.deepSeekModel, "deepseek-flash")

    OwlCloudPreferences.deepSeekModel = "deepseek-reasoner"
    XCTAssertEqual(OwlCloudPreferences.deepSeekModel, "deepseek-v4-pro")

    OwlCloudPreferences.deepSeekModel = "deepseek-chat"
    XCTAssertEqual(OwlCloudPreferences.deepSeekModel, "deepseek-flash")
  }

  func testDeepSeekStatusMessagesAreSpecific() {
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(400)), "云端 AI 拒绝了此请求")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(401)), "云端 AI 的 API Key 无效")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(402)), "云端 AI 账户余额不足")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(422)), "云端 AI 不支持的请求格式")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(429)), "云端 AI 请求过于频繁，请稍后再试")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(500)), "云端 AI 服务器错误，请稍后重试")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(503)), "云端 AI 服务繁忙，请稍后重试")
    XCTAssertEqual(
      OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(418)),
      "云端 AI 请求失败（418）"
    )
  }

  // 任意提问的专属云闸测试（OwlAskAnythingGate）已随状态栏入口一并删除（2026-07-26）：无选区入口
  // 没了之后它只剩划词菜单一条路，关闸由 `OwlSelectionMenuAction.enabledActions(cloudEnabled:)`
  // 统一挡下（断言在 OwlSettingsActionTests，关闸返空数组＝连 .ask 都不出现）。

  func testDeepSeekUsageTelemetryStoresOnlyCountsAndCache() {
    OwlCloudUsageTelemetry.record(
      OwlCloudUsageSnapshot(
        model: "deepseek-v4-flash",
        completionTokens: 3,
        promptTokens: 10,
        promptCacheHitTokens: 7,
        promptCacheMissTokens: 3,
        totalTokens: 13
      )
    )

    XCTAssertEqual(
      OwlCloudUsageTelemetry.lastUsage,
      OwlCloudUsageSnapshot(
        model: "deepseek-v4-flash",
        completionTokens: 3,
        promptTokens: 10,
        promptCacheHitTokens: 7,
        promptCacheMissTokens: 3,
        totalTokens: 13
      )
    )
  }

  func testParserRejectsBadJSONAndCleansFields() {
    // Malformed JSON-looking text → no candidates (never surface raw braces/brackets).
    XCTAssertEqual(OwlNumberedRewriteParser.parse("{not valid json"), [])
    XCTAssertEqual(OwlNumberedRewriteParser.parse("[oops"), [])
    // Object form parsed; empties dropped, duplicates de-duped, order preserved.
    XCTAssertEqual(
      OwlNumberedRewriteParser.parse("{\"candidates\": [\"本院认为\", \"\", \"本院认为\", \"依法驳回\"]}"),
      ["本院认为", "依法驳回"]
    )
    // Bare array form still accepted.
    XCTAssertEqual(OwlNumberedRewriteParser.parse("[\"甲\", \"乙\"]"), ["甲", "乙"])
  }

  func testRetryPolicyClassifiesErrors() {
    XCTAssertTrue(OwlCloudRetry.isRetryable(OwlCloudRequestError.emptyResponse))
    XCTAssertTrue(OwlCloudRetry.isRetryable(OwlCloudRequestError.badHTTPStatus(500)))
    XCTAssertTrue(OwlCloudRetry.isRetryable(OwlCloudRequestError.badHTTPStatus(503)))
    XCTAssertTrue(OwlCloudRetry.isRetryable(URLError(.timedOut)))
    XCTAssertTrue(OwlCloudRetry.isRetryable(URLError(.networkConnectionLost)))
    XCTAssertFalse(OwlCloudRetry.isRetryable(OwlCloudRequestError.badHTTPStatus(429)))
    XCTAssertFalse(OwlCloudRetry.isRetryable(OwlCloudRequestError.badHTTPStatus(400)))
    XCTAssertFalse(OwlCloudRetry.isRetryable(URLError(.notConnectedToInternet)))
  }
}

@MainActor
final class OwlNumberedRewriteParserTests: XCTestCase {

  func testSharedCandidateTextParserHandlesJsonObjectAndDedupes() {
    let parsed = OwlNumberedRewriteParser.parse(#"{"candidates":["本院认为","本院认为","依法驳回"]}"#)
    XCTAssertEqual(parsed, ["本院认为", "依法驳回"])
  }

  func testSharedCandidateTextParserTreatsInvalidJsonAsNoResult() {
    XCTAssertEqual(OwlNumberedRewriteParser.parse(#"{"candidates":["本院认为""#), [])
    XCTAssertEqual(OwlNumberedRewriteParser.parse("[]"), [])
    XCTAssertEqual(OwlNumberedRewriteParser.parse(""), [])
  }
}

final class OwlCommitTransformTests: XCTestCase {
  func testDisabledKeepsText() {
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "Owltype输入法2", cjkEnglishSpacing: false, cjkNumberSpacing: false),
      "Owltype输入法2"
    )
  }

  func testCJKEnglishSpacing() {
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "猫头鹰AI", cjkEnglishSpacing: true, cjkNumberSpacing: false),
      "猫头鹰 AI"
    )
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "AI猫头鹰", cjkEnglishSpacing: true, cjkNumberSpacing: false),
      "AI 猫头鹰"
    )
  }

  func testCJKNumberSpacing() {
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "第3条", cjkEnglishSpacing: false, cjkNumberSpacing: true),
      "第 3 条"
    )
  }

  func testBothModesAvoidDoubleSpacing() {
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "猫头鹰 AI", cjkEnglishSpacing: true, cjkNumberSpacing: true),
      "猫头鹰 AI"
    )
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "Owltype输入法2", cjkEnglishSpacing: true, cjkNumberSpacing: true),
      "Owltype 输入法 2"
    )
  }

  // Regression (2026-06-28): the real-world bug — 中文 and 英文 arrive in SEPARATE commits, so the
  // string-only transform never saw the boundary and no space appeared. The `previous:` seed (the
  // trailing char of the prior commit, threaded by OwlInputController.lastCommittedCharacter)
  // restores the boundary space.
  func testCrossCommitBoundarySpacing() {
    // 猫头鹰 committed, then AI committed separately → leading space before AI.
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "AI", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: "墨"),
      " AI"
    )
    // AI committed, then 猫头鹰 → leading space before 猫头鹰.
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "猫头鹰", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: "I"),
      " 猫头鹰"
    )
    // 第 committed, then 3条 → number spacing across the boundary.
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "3条", cjkEnglishSpacing: false, cjkNumberSpacing: true, previous: "第"),
      " 3 条"
    )
    // Same script across the boundary → no leading space.
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "天", cjkEnglishSpacing: true, cjkNumberSpacing: true, previous: "今"),
      "天"
    )
    // Previous char is a space/punctuation (BoundaryKind nil) → no double space.
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "AI", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: " "),
      "AI"
    )
    // nil previous (first commit after focus change) → unchanged.
    XCTAssertEqual(
      OwlCommitTransform.apply(to: "AI", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: nil),
      "AI"
    )
  }

}

@MainActor
final class OwlModernUISmokeTests: XCTestCase {

  /// 把引导的每一步渲染成 PNG 落到临时目录，路径打进测试日志。
  ///
  /// 为什么需要它：引导窗是**固定 720×480 且不滚动**的，而 `fittingSize` 恒等于这个尺寸
  /// （它就是 body 里 `.frame` 写死的），所以尺寸断言对「某一步内容变长、超出窗口被裁掉」
  /// 完全无感。内容溢出只有渲染出来才看得见，而这是每个新用户的第一屏。
  /// 断言只挡明显退化（画不出/全白）；真正的验收是人看图。
  func testOnboardingStepsRenderWithoutDegenerateOutput() throws {
    // 落在 Caches 而不是 temporaryDirectory：后者在测试宿主里是个每次都变的私有路径，
    // 图渲染出来也找不到，看不成图这个测试就白写了。
    let dir = try XCTUnwrap(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
      .appending(component: "owl-onboarding-snapshots", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    for step in 0..<5 {
      let view = OwlOnboardingView(
        onOpenSystemSettings: {},
        onSelectSchema: { _ in },
        onOpenInputSettings: {},
        onFinish: {},
        isOwltypeEnabled: { step > 2 },   // 走到「启用」之后的步骤按已启用渲染
        initialStep: step
      )
      // 必须挂进真窗口：`initialStep` 经 onAppear 落到 @State，离屏裸 hosting view 不触发。
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(
        x: 0, y: 0,
        width: OwlOnboardingMetrics.width, height: OwlOnboardingMetrics.height)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      // 等 onAppear 换步 + 换步动画（.snappy 0.2s）整个走完再取图，否则抓到的是过渡中间态，
      // 上一步的内容还叠在画面上，看起来像重影 bug。
      RunLoop.current.run(until: Date().addingTimeInterval(0.8))
      host.layoutSubtreeIfNeeded()

      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = dir.appending(component: "step-\(step).png", directoryHint: .notDirectory)
      try png.write(to: url)
      print("Owltype onboarding snapshot: \(url.path)")

      XCTAssertEqual(rep.pixelsWide, Int(OwlOnboardingMetrics.width * window.backingScaleFactor))
      XCTAssertGreaterThan(png.count, 4096, "step \(step) 渲染结果小得不像真画面")
    }
  }

  private func fittingSize<V: View>(of view: V) -> NSSize {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  func testSwiftUISurfacesHaveNonZeroFittingSizes() {
    let panelState = CandidatePanelState()
    panelState.preedit = "ni hao"
    panelState.candidates = [
      CandidateViewModel(id: 0, label: "1", text: "你好", comment: "ni hao"),
      CandidateViewModel(id: 1, label: "2", text: "您好")
    ]
    let panelSize = fittingSize(of: OwlCandidatePanelView(
      state: panelState,
      onSelect: { _ in },
      onPage: { _ in }
    ))
    XCTAssertGreaterThanOrEqual(panelSize.width, 196)
    XCTAssertGreaterThan(panelSize.height, 0)

    let settingsState = OwlSettingsState()
    settingsState.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    let settingsSize = fittingSize(of: OwlSettingsView(
      state: settingsState,
      onSelectSchema: { _ in },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { .init(written: [], succeeded: true) },
      onApplyFuzzyConfigFast: { .init(written: [], succeeded: true) },
      userDataActions: .init(
        migrateLegacy: {},
        resetUserDict: {}
      ),
      onOpenDataFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    ))
    XCTAssertGreaterThan(settingsSize.width, 0)
    XCTAssertGreaterThan(settingsSize.height, 0)

    settingsState.selectedPage = .ai
    let aiSettingsSize = fittingSize(of: OwlSettingsView(
      state: settingsState,
      onSelectSchema: { _ in },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { .init(written: [], succeeded: true) },
      onApplyFuzzyConfigFast: { .init(written: [], succeeded: true) },
      userDataActions: .init(
        migrateLegacy: {},
        resetUserDict: {}
      ),
      onOpenDataFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    ))
    XCTAssertGreaterThan(aiSettingsSize.width, 0)
    XCTAssertGreaterThan(aiSettingsSize.height, 0)

    let onboardingSize = fittingSize(of: OwlOnboardingView(
      onOpenSystemSettings: {},
      onSelectSchema: { _ in },
      onOpenInputSettings: {},
      onFinish: {},
      isOwltypeEnabled: { true }
    ))
    // 视图与窗口共用同一组数，锁的是「两边没走散」——窗口比内容大会露底色、小会裁掉底部按钮。
    XCTAssertEqual(onboardingSize.width, OwlOnboardingMetrics.width)
    XCTAssertEqual(onboardingSize.height, OwlOnboardingMetrics.height)

    let emojiSize = fittingSize(of: OwlEmojiPanelView(onPick: { _ in }, onClose: {}))
    XCTAssertEqual(emojiSize.width, 372)
    XCTAssertEqual(emojiSize.height, 318)
  }

  func testCompactCommentsOnlyShowForWubiSchemas() {
    let state = CandidatePanelState()
    let candidate = CandidateViewModel(id: 0, label: "1", text: "你好", comment: "wqvb")

    state.candidateFormat = .full
    state.schemaID = "wubi86_jidian"
    XCTAssertTrue(state.showsCompactComment(for: candidate))

    state.schemaID = "wubi86_jidian_pinyin"
    XCTAssertTrue(state.showsCompactComment(for: candidate))

    state.schemaID = "rime_ice"
    XCTAssertFalse(state.showsCompactComment(for: candidate))

    state.schemaID = "wubi86_jidian"
    state.candidateFormat = .noComment
    XCTAssertFalse(state.showsCompactComment(for: candidate))

    state.candidateFormat = .full
    XCTAssertFalse(state.showsCompactComment(for: CandidateViewModel(id: 0, label: "1", text: "你好")))
  }

  func testSnippetSettingsHasOneEntryAndPreservesExistingShortcutBindings() {
    XCTAssertEqual(OwlSettingsPage.visibleCases.filter { $0.title == "快捷片段" }, [.quickSend])
    XCTAssertNil(OwlSettingsPage(rawValue: "prompts"))
    XCTAssertEqual(OwlHotKeySlot.quickSendPanel.defaultsKey, "OwlQuickSendPanelHotKey")
    XCTAssertEqual(OwlHotKeySlot.promptAssistant.defaultsKey, "OwlPromptAssistantHotKey")
  }

  func testKeyboardPageExposesFirstClassInputModesAndDoublePinyinPickerState() {
    XCTAssertFalse(OwlSettingsPage.visibleCases.contains(.schemes))
    XCTAssertEqual(
      OwlInputMethod.allCases.map(\.displayName),
      ["拼音输入", "双拼输入", "五笔输入"]
    )
    XCTAssertEqual(OwlWubiScheme.allCases.map(\.displayName),
      ["86 版五笔", "86 版五笔拼音混输", "98 版五笔", "98 版五笔拼音混输"])
    XCTAssertEqual(OwlInputMethod.pinyin.schemaId(doublePinyin: .flypy, wubiScheme: .jidian86), "rime_ice")
    XCTAssertEqual(OwlInputMethod.doublePinyin.schemaId(doublePinyin: .flypy, wubiScheme: .jidian86), "double_pinyin_flypy")
    XCTAssertEqual(OwlInputMethod.wubi.schemaId(doublePinyin: .flypy, wubiScheme: .jidian86), "wubi86_jidian")
    XCTAssertEqual(OwlInputMethod.wubi.schemaId(doublePinyin: .flypy, wubiScheme: .pinyinMix), "wubi86_jidian_pinyin")
    XCTAssertEqual(OwlInputMethod.wubi.schemaId(doublePinyin: .flypy, wubiScheme: .jidian98), "wubi98")
    XCTAssertEqual(OwlInputMethod.wubi.schemaId(doublePinyin: .flypy, wubiScheme: .pinyinMix98), "wubi98_pinyin")
    XCTAssertFalse(OwlKeyboardPage.isDoublePinyinPickerEnabled(for: .pinyin))
    XCTAssertTrue(OwlKeyboardPage.isDoublePinyinPickerEnabled(for: .doublePinyin))
    XCTAssertFalse(OwlKeyboardPage.isDoublePinyinPickerEnabled(for: .wubi))
    XCTAssertEqual(OwlKeyboardPage.doublePinyinPickerOpacity(for: .pinyin), 0.4)
    XCTAssertEqual(OwlKeyboardPage.doublePinyinPickerOpacity(for: .doublePinyin), 1)
  }

  func testInputMenuTitlesExposeRuntimeToggles() {
    XCTAssertEqual(OwlInputMenuTitles.cjkInput(asciiMode: true), "切换至中文输入")
    XCTAssertEqual(OwlInputMenuTitles.cjkInput(asciiMode: false), "切换至英文输入")
    XCTAssertEqual(OwlInputMenuTitles.traditionalInput(traditional: false), "切换至繁体输入")
    XCTAssertEqual(OwlInputMenuTitles.traditionalInput(traditional: true), "切换至简体输入")
    XCTAssertEqual(OwlInputMenuTitles.asciiPunctuation(asciiPunct: false), "使用英文标点符号")
    XCTAssertEqual(OwlInputMenuTitles.asciiPunctuation(asciiPunct: true), "使用中文标点符号")
    XCTAssertEqual(OwlInputMenuTitles.fullShape(fullShape: false), "使用全角输入")
    XCTAssertEqual(OwlInputMenuTitles.fullShape(fullShape: true), "使用半角输入")
  }

  func testInputMenuTitlesExposeHighFrequencyTools() {
    XCTAssertEqual(OwlInputMenuTitles.clipboard, "剪贴板…")
    XCTAssertEqual(OwlInputMenuTitles.emoji, "表情符号…")
    XCTAssertEqual(OwlInputMenuTitles.quickSend, "快捷片段…")
    XCTAssertEqual(OwlInputMenuTitles.deploy, "应用配置改动")
  }

  func testWritePreviewReportsDeployFailureAfterSuccessfulWrite() {
    let status = OwlWritePreviewSheet.applyStatusMessage(
      written: ["default.custom.yaml"],
      deploySucceeded: false
    )

    XCTAssertTrue(status.contains("已写入 default.custom.yaml"))
    XCTAssertTrue(status.contains("应用配置失败"))
    XCTAssertFalse(status.contains("已写入并应用配置"))
  }

  func testAboutPageFormatsVersionAndBuildIdentity() {
    XCTAssertEqual(
      OwlAboutPage.versionDisplay(info: [
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "42"
      ]),
      "1.0 (42)"
    )
    XCTAssertEqual(OwlAboutPage.versionDisplay(info: nil), "未知")
    XCTAssertEqual(
      OwlAboutPage.buildIdentityDisplay(bundleIdentifier: "im.owltype.inputmethod.Owltype"),
      "im.owltype.inputmethod.Owltype"
    )
    XCTAssertEqual(OwlAboutPage.buildIdentityDisplay(bundleIdentifier: ""), "未知")
  }

  func testFloatingPanelsDoNotStealHostFocus() {
    XCTAssertFalse(OwlSwiftUICandidatePanel().canBecomeKey)
    XCTAssertFalse(OwlEmojiPanel().canBecomeKey)
    // The status HUD is also a non-activating panel — it must never steal host focus.
    XCTAssertFalse(OwlStatusHUD().canBecomeKey)
    XCTAssertFalse(OwlInputStatusPanel.shared.canBecomeKey)
    XCTAssertFalse(OwlInputStatusPanel.shared.canBecomeMain)
    XCTAssertTrue(OwlInputStatusPanel.shared.styleMask.contains(.nonactivatingPanel))
  }

  // NOTE: `testSwiftUICandidatePanelDefaultsOnButCanOptOut` was removed when the
  // `OwlSwiftUIPanel` feature flag was retired — SwiftUI is now the sole candidate
  // renderer, so there is no opt-out flag left to test.
}

/// G8 候选显示设置 — panel prefs (orientation/typeface/animation/expanded) + Rime page_size.
@MainActor
final class OwlCandidateDisplayTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    for key in ["OwlPanelFontSize", "OwlPanelOrientation", "OwlPanelFontDesign",
                "OwlPanelAnimations", "OwlPanelShowPreedit", "OwlPanelShowPaging",
                "OwlPanelCandidateFormat", "OwlPanelPreviewRows",
                "OwlKeyboardPageSize"] {
      OwlDefaults.standard.removeObject(forKey: key)
    }
  }
  override func tearDown() async throws {
    for key in ["OwlPanelFontSize", "OwlPanelOrientation", "OwlPanelFontDesign",
                "OwlPanelAnimations", "OwlPanelShowPreedit", "OwlPanelShowPaging",
                "OwlPanelCandidateFormat", "OwlPanelPreviewRows",
                "OwlKeyboardPageSize"] {
      OwlDefaults.standard.removeObject(forKey: key)
    }
    try await super.tearDown()
  }

  func testPanelDisplayPrefsDefaultsAndRoundTrip() {
    let settings = OwlCandidatePanelSettings.live
    let state = OwlSettingsState()
    // Defaults.
    XCTAssertEqual(settings.snapshot().orientation, .vertical)
    settings.seed(state)
    XCTAssertEqual(state.candidateFont.selection, .default)
    XCTAssertTrue(settings.snapshot().animationsEnabled)
    // Round-trip.
    settings.edit(.orientation(.horizontal), state: state, onChange: {})
    settings.edit(.font(.mapleMono), state: state, onChange: {})
    settings.edit(.animationsEnabled(false), state: state, onChange: {})
    XCTAssertEqual(settings.snapshot().orientation, .horizontal)
    XCTAssertEqual(settings.snapshot().font.selection, .mapleMono)
    XCTAssertFalse(settings.snapshot().animationsEnabled)
  }

  /// 多行后页行数：默认 4（2026-07-28 截图定案），钳到 1...4（抵御手改 defaults 写出的
  /// 越界值）；老用户存过的 1/2 落在新区间内原样生效。
  func testScrollRowsDefaultAndClamp() {
    let settings = OwlCandidatePanelSettings.live
    let state = OwlSettingsState()
    OwlDefaults.standard.removeObject(forKey: "OwlPanelPreviewRows")
    XCTAssertEqual(settings.snapshot().scrollRows, 4)
    settings.edit(.scrollRows(1), state: state, onChange: {})
    XCTAssertEqual(settings.snapshot().scrollRows, 1)
    OwlDefaults.standard.set(9, forKey: "OwlPanelPreviewRows")
    XCTAssertEqual(settings.snapshot().scrollRows, 4)
    OwlDefaults.standard.set(0, forKey: "OwlPanelPreviewRows")
    XCTAssertEqual(settings.snapshot().scrollRows, 1)
    OwlDefaults.standard.set(2, forKey: "OwlPanelPreviewRows")
    XCTAssertEqual(settings.snapshot().scrollRows, 2)
    OwlDefaults.standard.removeObject(forKey: "OwlPanelPreviewRows")
  }

  func testOrientationResolution() {
    // With no schema default, .auto follows Rime's _vertical; explicit overrides ignore it.
    XCTAssertTrue(OwlPanelOrientation.auto.isVertical(engineVertical: true))
    XCTAssertFalse(OwlPanelOrientation.auto.isVertical(engineVertical: false))
    XCTAssertFalse(OwlPanelOrientation.horizontal.isVertical(engineVertical: true))
    XCTAssertTrue(OwlPanelOrientation.vertical.isVertical(engineVertical: false))
    // 多行是横排的一种：`isVertical` 恒 false，`scrolls` 才是它与单行横排的区别。
    XCTAssertFalse(OwlPanelOrientation.scroll.isVertical(engineVertical: true))
    XCTAssertTrue(OwlPanelOrientation.scroll.scrolls)
    XCTAssertFalse(OwlPanelOrientation.horizontal.scrolls)
  }

  func testAutoOrientationIsHorizontalForWubiSchemas() {
    // Fix #2 (2026-06-22): the old Wubi-forces-vertical special case was removed. With
    // orientation 自动, every schema — including Wubi — follows ONLY rime's _vertical, so a
    // Wubi schema with engineVertical:false now resolves to horizontal like rime_ice.
    XCTAssertFalse(OwlPanelOrientation.auto.isVertical(engineVertical: false, schemaID: "wubi86_jidian"))
    XCTAssertFalse(OwlPanelOrientation.auto.isVertical(engineVertical: false, schemaID: "wubi86_jidian_pinyin"))
    XCTAssertFalse(OwlPanelOrientation.auto.isVertical(engineVertical: false, schemaID: "wubi86_jidian_trad"))
    XCTAssertFalse(OwlPanelOrientation.auto.isVertical(engineVertical: false, schemaID: "wubi86_jidian_trad_pinyin"))
    XCTAssertFalse(OwlPanelOrientation.auto.isVertical(engineVertical: false, schemaID: "rime_ice"))
    // …but a schema that DOES set rime _vertical still goes vertical under 自动.
    XCTAssertTrue(OwlPanelOrientation.auto.isVertical(engineVertical: true, schemaID: "wubi86_jidian"))
  }

  func testExplicitOrientationStillOverridesForAnySchema() {
    // Explicit 横排/竖排 win regardless of schema and regardless of rime _vertical.
    XCTAssertFalse(OwlPanelOrientation.horizontal.isVertical(engineVertical: true, schemaID: "wubi86_jidian"))
    XCTAssertTrue(OwlPanelOrientation.vertical.isVertical(engineVertical: false, schemaID: "wubi86_jidian"))
    XCTAssertTrue(OwlPanelOrientation.vertical.isVertical(engineVertical: false, schemaID: "rime_ice"))
  }

  func testCandidateFontDownloadURL() {
    XCTAssertEqual(
      OwlCandidateFontSelection.mapleMonoDownloadURL.absoluteString,
      "https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-CN.zip"
    )
  }

  func testPageSizeDefaultAndClamp() {
    XCTAssertEqual(OwlKeyboardPreferences.pageSize, 4)
    OwlKeyboardPreferences.pageSize = 5
    XCTAssertEqual(OwlKeyboardPreferences.pageSize, 5)
    OwlKeyboardPreferences.pageSize = 99                     // clamp high
    XCTAssertEqual(OwlKeyboardPreferences.pageSize, 9)
    OwlKeyboardPreferences.pageSize = 1                      // clamp low
    XCTAssertEqual(OwlKeyboardPreferences.pageSize, 3)
  }

  func testKeyboardPatchEmitsConfiguredPageSize() {
    OwlKeyboardPreferences.pageSize = 6
    let yaml = owlDefaultCustomYAML(from: OwlKeyboardSnapshot.current())
    XCTAssertTrue(yaml.contains("\"menu/page_size\": 6"), "patch must carry the chosen 候选个数")
    XCTAssertFalse(yaml.contains("\"menu/page_size\": 8"), "no stale hardcoded 8")
  }

  func testCandidatePageSizeApplyStatusReportsDeployFailureAsNotEffective() {
    let status = OwlSettingsView.candidatePageSizeApplyStatusMessage(
      written: ["default.custom.yaml"],
      deploySucceeded: false
    )

    // PR3: copy moved from deploy-implying "重新部署失败" to immediate "应用失败".
    XCTAssertTrue(status.contains("应用失败"))
    XCTAssertFalse(status.contains("重新部署"))
    XCTAssertTrue(status.contains("候选个数未生效"))
  }
}

// MARK: - B4 选中润色 (OwlSelectionPolish) — pure prompt/policy + service guards

/// A reply carrying `content` in both shells (Chat `choices`, Responses `output_text`), so the test
/// holds whichever wire the routed provider speaks.
private func polishReply(_ content: String) -> Data {
  let body: [String: Any] = [
    "choices": [["message": ["content": content]]], "output_text": content, "model": "m",
  ]
  return try! JSONSerialization.data(withJSONObject: body)
}

final class OwlSelectionPolishPromptTests: XCTestCase {

  func testPolishPromptAsksForJSONCandidatesAndRewrite() {
    // B4 reuses the json_object {"candidates":[...]} contract so the shared parser is reused.
    let prompt = OwlSelectionPolish.systemPrompt
    XCTAssertTrue(prompt.contains("{\"candidates\":"), "polish prompt must demand the {\"candidates\":[...]} shape")
    XCTAssertTrue(prompt.lowercased().contains("json"), "polish prompt must ask for JSON (json_object mode)")
    XCTAssertTrue(
      prompt.contains("改写") || prompt.lowercased().contains("rewrite") || prompt.lowercased().contains("polish"),
      "polish prompt must ask for a rewrite / polish"
    )
  }

  func testRejectionReasonRejectsEmptyAndWhitespaceOnly() {
    XCTAssertEqual(OwlSelectionPolish.rejectionReason(for: ""), .emptySelection)
    XCTAssertEqual(OwlSelectionPolish.rejectionReason(for: "   \n\t "), .emptySelection)
  }

  func testRejectionReasonCapsLongSelections() {
    let ok = String(repeating: "甲", count: OwlSelectionPolish.maxSelectionLength)
    XCTAssertNil(OwlSelectionPolish.rejectionReason(for: ok), "selection at the cap is acceptable")

    let tooLong = String(repeating: "甲", count: OwlSelectionPolish.maxSelectionLength + 1)
    XCTAssertEqual(
      OwlSelectionPolish.rejectionReason(for: tooLong),
      .selectionTooLong(OwlSelectionPolish.maxSelectionLength + 1),
      "selection beyond the cap must be rejected (privacy + cost guard)"
    )
  }

  func testPolishRequestUsesFlashModelAndJSONObjectAndCarriesSelectedText() throws {
    OwlCloudPreferences.resetForTesting()
    defer { OwlCloudPreferences.resetForTesting() }

    let request = try OwlSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(request.model, OwlCloudPreferences.deepSeekModel, "polish uses the flash model")
    XCTAssertEqual(request.responseFormat, .jsonObject)
    // The selected text IS the payload here — the documented CodeOnly exception.
    let userContent = request.messages.first(where: { $0.role == "user" })?.content ?? ""
    XCTAssertTrue(userContent.contains("他撤销了合同"), "the user payload carries the selected text")
  }

  func testPolishRequestContainsOnlyPromptAndExplicitSelection() throws {
    let request = try OwlSelectionPolish.chatRequest(for: "好的")
    XCTAssertEqual(request.messages.map(\.role), ["system", "user"])
    XCTAssertTrue(request.messages[1].content.contains("好的"))
  }

  /// Redaction is removed: B4 sends the selected document text VERBATIM (raw). PII in the selection
  /// reaches the wire as-is — the privacy trade-off was an explicit user decision (2026-06-23).
  func testPolishRequestSendsSelectionRawWithoutMasking() throws {
    OwlCloudPreferences.resetForTesting()
    defer { OwlCloudPreferences.resetForTesting() }

    let selection = "原告联系方式PHONE_SENTINEL邮箱EMAIL_SENTINEL案号CASE_SENTINEL依据第107条撤销合同"
    let request = try OwlSelectionPolish.chatRequest(for: selection)
    let userContent = request.messages.first(where: { $0.role == "user" })?.content ?? ""

    // Raw passthrough: every field is carried verbatim, no masking placeholder.
    XCTAssertTrue(userContent.contains("PHONE_SENTINEL"), "explicit phone placeholder is sent raw")
    XCTAssertTrue(userContent.contains("EMAIL_SENTINEL"), "explicit e-mail placeholder is sent raw")
    XCTAssertTrue(userContent.contains("CASE_SENTINEL"), "explicit case placeholder is sent raw")
    XCTAssertTrue(userContent.contains("第107条"), "legal article number survives")
    XCTAssertTrue(userContent.contains("撤销合同"), "ordinary legal text survives")
  }
}

@MainActor
final class OwlSelectionPolishServiceTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlCloudPreferences.resetForTesting()
    OwlCloudUsageTelemetry.resetForTesting()
  }

  override func tearDown() async throws {
    OwlCloudPreferences.resetForTesting()
    OwlCloudUsageTelemetry.resetForTesting()
    try await super.tearDown()
  }

  func testDisabledStopsBeforeKeychainAndNetwork() async {
    // Default-off: no keychain read, no request.
    var keychainCalls = 0
    let transport = OwlRecordingTransport { _ in
      XCTFail("Default-off polish must not reach the network")
      return (Data(), URLResponse())
    }
    let service = OwlSelectionPolishService(gateway: OwlLLMGateway(transport: transport), apiKeyProvider: {
      keychainCalls += 1
      return "sk-test"
    })

    do {
      _ = try await service.polishSelection("他撤销了合同")
      XCTFail("disabled polish must throw")
    } catch let error as OwlSelectionPolishError {
      XCTAssertEqual(error, .disabled)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(keychainCalls, 0)
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testLengthCapStopsBeforeKeychainAndNetwork() async {
    OwlCloudPreferences.isEnabled = true
    var keychainCalls = 0
    let transport = OwlRecordingTransport { _ in
      XCTFail("Over-cap selection must not be uploaded")
      return (Data(), URLResponse())
    }
    let service = OwlSelectionPolishService(gateway: OwlLLMGateway(transport: transport), apiKeyProvider: {
      keychainCalls += 1
      return "sk-test"
    })

    let tooLong = String(repeating: "甲", count: OwlSelectionPolish.maxSelectionLength + 1)
    do {
      _ = try await service.polishSelection(tooLong)
      XCTFail("over-cap selection must throw")
    } catch let error as OwlSelectionPolishError {
      XCTAssertEqual(error, .selectionTooLong(OwlSelectionPolish.maxSelectionLength + 1))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(keychainCalls, 0, "length cap must stop before any keychain read")
    XCTAssertTrue(transport.requests.isEmpty, "length cap must stop before any upload")
  }

  func testMissingAPIKeyStopsBeforeNetwork() async {
    OwlCloudPreferences.isEnabled = true
    let transport = OwlRecordingTransport { _ in
      XCTFail("Missing key must stop before any request")
      return (Data(), URLResponse())
    }
    let service = OwlSelectionPolishService(
      gateway: OwlLLMGateway(transport: transport), apiKeyProvider: { nil }, profileProvider: { nil })

    do {
      _ = try await service.polishSelection("他撤销了合同")
      XCTFail("missing key must throw")
    } catch let error as OwlSelectionPolishError {
      XCTAssertEqual(error, .missingAPIKey)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testEnabledPolishReturnsRewritesBestFirst() async throws {
    OwlCloudPreferences.isEnabled = true
    let transport = OwlRecordingTransport.replying(
      polishReply(#"{"candidates": ["他解除了合同", "合同被其解除"]}"#))
    let service = OwlSelectionPolishService(
      gateway: OwlLLMGateway(transport: transport), apiKeyProvider: { "sk-test" }, profileProvider: { nil })

    let rewrites = try await service.polishSelection("他撤销了合同")

    XCTAssertEqual(transport.requests.count, 1)
    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    XCTAssertTrue(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("他撤销了合同"))
    XCTAssertEqual(rewrites, ["他解除了合同", "合同被其解除"])
  }

  func testPolishRoutesThroughActiveProviderProfileKey() async throws {
    // OWL-098: 润色选中 must use the ACTIVE provider profile's key (not only the legacy DeepSeek
    // key), so a user configured with OpenAI / Gemini / 自定义 can polish selections. The legacy
    // key reader must NOT be consulted when a profile with a secret is active.
    OwlCloudPreferences.isEnabled = true
    let transport = OwlRecordingTransport.replying(polishReply(#"{"candidates": ["他解除了合同"]}"#))
    let profile = OwlProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "owltype.provider.unit.apiKey",
      isDefault: true
    )
    let service = OwlSelectionPolishService(
      gateway: OwlLLMGateway(transport: transport),
      apiKeyProvider: { XCTFail("active profile must not read the legacy DeepSeek key"); return nil },
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-profile" }
    )

    let rewrites = try await service.polishSelection("他撤销了合同")

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url, profile.endpoint)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-profile",
                   "must use the per-profile key, not the legacy key")
    XCTAssertEqual(rewrites, ["他解除了合同"])
  }

  func testEmptyResultRetriesOnceThenSurfacesTheError() async throws {
    // Interactive rewrite purpose: empty content is transient → exactly one retry.
    OwlCloudPreferences.isEnabled = true
    let transport = OwlRecordingTransport.replying(Data(#"{"choices":[]}"#.utf8))
    let service = OwlSelectionPolishService(
      gateway: OwlLLMGateway(transport: transport), apiKeyProvider: { "sk-test" }, profileProvider: { nil })

    do {
      _ = try await service.polishSelection("他撤销了合同")
      XCTFail("persistent empty response should surface the error")
    } catch let error as OwlCloudRequestError {
      XCTAssertEqual(error, .emptyResponse)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(transport.requests.count, 2, "empty content is transient → exactly one retry")
  }
}
