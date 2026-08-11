//
//  CandidateStoreTests.swift
//  FamoTests — P0 candidate-store staleness gate (spec P0-03 / P0-06)
//
//  Verifies the store DROPS an upsert whose snapshotID is stale, KEEPS one for the live
//  snapshot, and clears smart/cloud on a composition change. No network, no librime.
//
//  Note: the store consults `FamoSnapshotRegistry.shared` (the singleton the live emitter
//  also writes), so these tests drive that shared registry. Each test resets it to a known
//  state, exercising the cross-check exactly as production code will.
//

import AppKit
import SwiftUI
import XCTest
@testable import Famo

@MainActor
final class CandidateStoreTests: XCTestCase {

  private func makeSnapshot(id: UInt64, rawInput: String = "byrw") -> FamoCompositionSnapshot {
    FamoCompositionSnapshot(
      id: id,
      sessionID: 100,
      schemaID: "wubi86_jidian",
      rawInput: rawInput,
      preedit: "本院",
      cursor: 2,
      pageNo: 0,
      candidates: [],
      commitSerial: 0
    )
  }

  private func makeCandidate(
    snapshotID: UInt64,
    lane: EnhancedCandidate.Lane,
    text: String
  ) -> EnhancedCandidate {
    EnhancedCandidate(
      snapshotID: snapshotID,
      source: .localStat,
      lane: lane,
      text: text,
      commitMode: .externalText
    )
  }

  override func setUp() async throws {
    try await super.setUp()
    // Clear any state left by a prior test in this process.
    FamoSnapshotRegistry.shared.update(nil)
    FamoCandidateStore.shared.clearForSnapshotChange()
  }

  override func tearDown() async throws {
    // Reset the process-wide registry at the source so a leftover snapshot can't leak
    // into later test classes (the symmetric reset to setUp).
    FamoSnapshotRegistry.shared.update(nil)
    try await super.tearDown()
  }

  func testUpsertWithCurrentSnapshotIsKept() {
    let store = FamoCandidateStore.shared
    let live = makeSnapshot(id: 10)
    FamoSnapshotRegistry.shared.update(live)

    store.upsertSmartCandidates(
      [makeCandidate(snapshotID: 10, lane: .smart, text: "本院认为")],
      snapshotID: 10
    )
    XCTAssertEqual(store.smart.count, 1)
    XCTAssertEqual(store.smart.first?.text, "本院认为")
  }

  func testStaleSmartUpsertIsDropped() {
    let store = FamoCandidateStore.shared
    FamoSnapshotRegistry.shared.update(makeSnapshot(id: 21))

    store.upsertSmartCandidates(
      [makeCandidate(snapshotID: 20, lane: .smart, text: "本院")],
      snapshotID: 20
    )
    XCTAssertTrue(store.smart.isEmpty)
  }

  func testUpsertWithMismatchedLaneIsDropped() {
    let store = FamoCandidateStore.shared
    FamoSnapshotRegistry.shared.update(makeSnapshot(id: 30))

    // Candidate tagged .main fed into the smart upsert → rejected as inconsistent.
    store.upsertSmartCandidates(
      [makeCandidate(snapshotID: 30, lane: .main, text: "本院")],
      snapshotID: 30
    )
    XCTAssertTrue(store.smart.isEmpty)
  }

  func testClearForSnapshotChangeEmptiesNonMainLanes() {
    let store = FamoCandidateStore.shared
    FamoSnapshotRegistry.shared.update(makeSnapshot(id: 40))
    store.upsertSmartCandidates(
      [makeCandidate(snapshotID: 40, lane: .smart, text: "本院")],
      snapshotID: 40
    )
    store.showError("decode error", lane: .smart, snapshotID: 40)
    XCTAssertFalse(store.smart.isEmpty)
    XCTAssertNotNil(store.laneError)

    store.clearForSnapshotChange()
    XCTAssertTrue(store.smart.isEmpty)
    XCTAssertNil(store.laneError)
  }

  func testStaleErrorIsDropped() {
    let store = FamoCandidateStore.shared
    FamoSnapshotRegistry.shared.update(makeSnapshot(id: 51))
    store.showError("decode error", lane: .smart, snapshotID: 50)
    XCTAssertNil(store.laneError)
  }

  func testExternalCommitBrokerCommitsOnlyCurrentCandidateAndClearsEnhancementLanes() {
    let store = FamoCandidateStore.shared
    FamoSnapshotRegistry.shared.update(makeSnapshot(id: 60))
    store.upsertSmartCandidates(
      [makeCandidate(snapshotID: 60, lane: .smart, text: "本院")],
      snapshotID: 60
    )
    XCTAssertFalse(store.smart.isEmpty)

    var inserted: [String] = []
    let candidate = makeCandidate(snapshotID: 60, lane: .smart, text: "本院认为")
    FamoExternalCommitBroker.shared.commit(candidate) { inserted.append($0) }

    XCTAssertEqual(inserted, ["本院认为"])
    XCTAssertTrue(store.smart.isEmpty)
  }

  func testExternalCommitBrokerDropsStaleCandidateWithoutInsert() {
    let store = FamoCandidateStore.shared
    FamoSnapshotRegistry.shared.update(makeSnapshot(id: 71, rawInput: "byrwr"))

    var inserted: [String] = []
    let stale = makeCandidate(snapshotID: 70, lane: .smart, text: "本院认为")
    FamoExternalCommitBroker.shared.commit(stale) { inserted.append($0) }

    XCTAssertTrue(inserted.isEmpty)
    XCTAssertTrue(store.smart.isEmpty)
  }
}

/// G3: the pure (lane, source[, law signals]) → Provenance? mapping. No registry, no
/// MainActor — it's a deterministic function, exactly the property that keeps it off the
/// key hot path.
final class ProvenanceMappingTests: XCTestCase {
  private func prov(
    _ source: EnhancedCandidate.Source,
    _ lane: EnhancedCandidate.Lane,
    law: Bool = false,
    version: Bool = false
  ) -> FamoProvenance? {
    EnhancedCandidate.provenance(source: source, lane: lane, isLawObject: law, lawVersionKnown: version)
  }

  func testSmartLaneSplitsBySource() {
    XCTAssertEqual(prov(.localStat, .smart), .personal)    // 个人词频
    XCTAssertEqual(prov(.localNeural, .smart), .project)   // 项目排序
  }

  func testOrdinaryRimeMainLaneHasNoLabel() {
    XCTAssertNil(prov(.rime, .main), "普通拼音主词典候选不加来源标签（避免噪声）")
  }

  func testLawObjectVersionKnownIsVerifiedElseRule() {
    XCTAssertEqual(prov(.rime, .main, law: true, version: true), .verified)
    XCTAssertEqual(prov(.rime, .main, law: true, version: false), .rule)
    // Law signal overrides lane bucketing (even a smart-lane law object stays verified/rule).
    XCTAssertEqual(prov(.localNeural, .smart, law: true, version: true), .verified)
  }

  func testAINeedsConfirmation() {
    XCTAssertTrue(FamoProvenance.ai.needsConfirmation)
    XCTAssertFalse(FamoProvenance.verified.needsConfirmation)
  }
}

/// Shared cloud-AI base coverage: the canonical DeepSeek model mapping, the error→message
/// strings, the usage telemetry, the numbered-rewrite parser, and the retry-policy classifier.
/// All are used by the kept 划词润色 / 任意提问 paths; the candidate pipeline is gone.
@MainActor
final class FamoCloudSharedBaseTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    FamoCloudPreferences.resetForTesting()
    FamoCloudUsageTelemetry.resetForTesting()
  }

  override func tearDown() async throws {
    FamoCloudPreferences.resetForTesting()
    FamoCloudUsageTelemetry.resetForTesting()
    try await super.tearDown()
  }

  func testDeepSeekModelDefaultsToV4AndCanonicalizesLegacyAliases() {
    XCTAssertEqual(FamoCloudPreferences.deepSeekModel, "deepseek-v4-flash")

    FamoCloudPreferences.deepSeekModel = "deepseek-reasoner"
    XCTAssertEqual(FamoCloudPreferences.deepSeekModel, "deepseek-v4-pro")

    FamoCloudPreferences.deepSeekModel = "deepseek-chat"
    XCTAssertEqual(FamoCloudPreferences.deepSeekModel, "deepseek-v4-flash")
  }

  func testDeepSeekStatusMessagesAreSpecific() {
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(400)), "云端 AI 拒绝了此请求")
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(401)), "云端 AI 的 API Key 无效")
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(402)), "云端 AI 账户余额不足")
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(422)), "云端 AI 不支持的请求格式")
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(429)), "云端 AI 请求过于频繁，请稍后再试")
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(500)), "云端 AI 服务器错误，请稍后重试")
    XCTAssertEqual(FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(503)), "云端 AI 服务繁忙，请稍后重试")
    XCTAssertEqual(
      FamoCloudPreferences.message(for: FamoCloudRequestError.badHTTPStatus(418)),
      "云端 AI 请求失败（418）"
    )
  }

  // 任意提问的专属云闸测试（FamoAskAnythingGate）已随状态栏入口一并删除（2026-07-26）：无选区入口
  // 没了之后它只剩划词菜单一条路，关闸由 `FamoSelectionMenuAction.enabledActions(cloudEnabled:)`
  // 统一挡下（断言在 FamoSettingsActionTests，关闸返空数组＝连 .ask 都不出现）。

  func testDeepSeekUsageTelemetryStoresOnlyCountsAndCache() {
    FamoCloudUsageTelemetry.record(
      FamoCloudUsageSnapshot(
        model: "deepseek-v4-flash",
        completionTokens: 3,
        promptTokens: 10,
        promptCacheHitTokens: 7,
        promptCacheMissTokens: 3,
        totalTokens: 13
      )
    )

    XCTAssertEqual(
      FamoCloudUsageTelemetry.lastUsage,
      FamoCloudUsageSnapshot(
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
    XCTAssertEqual(FamoNumberedRewriteParser.parse("{not valid json"), [])
    XCTAssertEqual(FamoNumberedRewriteParser.parse("[oops"), [])
    // Object form parsed; empties dropped, duplicates de-duped, order preserved.
    XCTAssertEqual(
      FamoNumberedRewriteParser.parse("{\"candidates\": [\"本院认为\", \"\", \"本院认为\", \"依法驳回\"]}"),
      ["本院认为", "依法驳回"]
    )
    // Bare array form still accepted.
    XCTAssertEqual(FamoNumberedRewriteParser.parse("[\"甲\", \"乙\"]"), ["甲", "乙"])
  }

  func testRetryPolicyClassifiesErrors() {
    XCTAssertTrue(FamoCloudRetry.isRetryable(FamoCloudRequestError.emptyResponse))
    XCTAssertTrue(FamoCloudRetry.isRetryable(FamoCloudRequestError.badHTTPStatus(500)))
    XCTAssertTrue(FamoCloudRetry.isRetryable(FamoCloudRequestError.badHTTPStatus(503)))
    XCTAssertTrue(FamoCloudRetry.isRetryable(URLError(.timedOut)))
    XCTAssertTrue(FamoCloudRetry.isRetryable(URLError(.networkConnectionLost)))
    XCTAssertFalse(FamoCloudRetry.isRetryable(FamoCloudRequestError.badHTTPStatus(429)))
    XCTAssertFalse(FamoCloudRetry.isRetryable(FamoCloudRequestError.badHTTPStatus(400)))
    XCTAssertFalse(FamoCloudRetry.isRetryable(URLError(.notConnectedToInternet)))
  }
}

@MainActor
final class FamoNumberedRewriteParserTests: XCTestCase {

  func testSharedCandidateTextParserHandlesJsonObjectAndDedupes() {
    let parsed = FamoNumberedRewriteParser.parse(#"{"candidates":["本院认为","本院认为","依法驳回"]}"#)
    XCTAssertEqual(parsed, ["本院认为", "依法驳回"])
  }

  func testSharedCandidateTextParserTreatsInvalidJsonAsNoResult() {
    XCTAssertEqual(FamoNumberedRewriteParser.parse(#"{"candidates":["本院认为""#), [])
    XCTAssertEqual(FamoNumberedRewriteParser.parse("[]"), [])
    XCTAssertEqual(FamoNumberedRewriteParser.parse(""), [])
  }
}

final class FamoCommitTransformTests: XCTestCase {
  func testDisabledKeepsText() {
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "Famo输入法2", cjkEnglishSpacing: false, cjkNumberSpacing: false),
      "Famo输入法2"
    )
  }

  func testCJKEnglishSpacing() {
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "法墨AI", cjkEnglishSpacing: true, cjkNumberSpacing: false),
      "法墨 AI"
    )
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "AI法墨", cjkEnglishSpacing: true, cjkNumberSpacing: false),
      "AI 法墨"
    )
  }

  func testCJKNumberSpacing() {
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "第3条", cjkEnglishSpacing: false, cjkNumberSpacing: true),
      "第 3 条"
    )
  }

  func testBothModesAvoidDoubleSpacing() {
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "法墨 AI", cjkEnglishSpacing: true, cjkNumberSpacing: true),
      "法墨 AI"
    )
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "Famo输入法2", cjkEnglishSpacing: true, cjkNumberSpacing: true),
      "Famo 输入法 2"
    )
  }

  // Regression (2026-06-28): the real-world bug — 中文 and 英文 arrive in SEPARATE commits, so the
  // string-only transform never saw the boundary and no space appeared. The `previous:` seed (the
  // trailing char of the prior commit, threaded by FamoInputController.lastCommittedCharacter)
  // restores the boundary space.
  func testCrossCommitBoundarySpacing() {
    // 法墨 committed, then AI committed separately → leading space before AI.
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "AI", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: "墨"),
      " AI"
    )
    // AI committed, then 法墨 → leading space before 法墨.
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "法墨", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: "I"),
      " 法墨"
    )
    // 第 committed, then 3条 → number spacing across the boundary.
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "3条", cjkEnglishSpacing: false, cjkNumberSpacing: true, previous: "第"),
      " 3 条"
    )
    // Same script across the boundary → no leading space.
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "天", cjkEnglishSpacing: true, cjkNumberSpacing: true, previous: "今"),
      "天"
    )
    // Previous char is a space/punctuation (BoundaryKind nil) → no double space.
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "AI", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: " "),
      "AI"
    )
    // nil previous (first commit after focus change) → unchanged.
    XCTAssertEqual(
      FamoCommitTransform.apply(to: "AI", cjkEnglishSpacing: true, cjkNumberSpacing: false, previous: nil),
      "AI"
    )
  }

}

@MainActor
final class FamoModernUISmokeTests: XCTestCase {

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
      .appending(component: "famo-onboarding-snapshots", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    for step in 0..<5 {
      let view = FamoOnboardingView(
        onOpenSystemSettings: {},
        onSelectSchema: { _ in },
        onOpenInputSettings: {},
        onFinish: {},
        isFamoEnabled: { step > 2 },   // 走到「启用」之后的步骤按已启用渲染
        initialStep: step
      )
      // 必须挂进真窗口：`initialStep` 经 onAppear 落到 @State，离屏裸 hosting view 不触发。
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(
        x: 0, y: 0,
        width: FamoOnboardingMetrics.width, height: FamoOnboardingMetrics.height)
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
      print("Famo onboarding snapshot: \(url.path)")

      XCTAssertEqual(rep.pixelsWide, Int(FamoOnboardingMetrics.width * window.backingScaleFactor))
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
    let panelSize = fittingSize(of: FamoCandidatePanelView(
      state: panelState,
      onSelect: { _ in },
      onPage: { _ in }
    ))
    XCTAssertGreaterThanOrEqual(panelSize.width, 196)
    XCTAssertGreaterThan(panelSize.height, 0)

    let settingsState = FamoSettingsState()
    settingsState.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    let settingsSize = fittingSize(of: FamoSettingsView(
      state: settingsState,
      onSelectSchema: { _ in },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { true },
      onApplyFuzzyConfigFast: { true },
      onSyncUserData: {},
      onResetUserDict: {},
      onChooseSyncDirectory: {},
      onOpenRimeFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    ))
    XCTAssertGreaterThan(settingsSize.width, 0)
    XCTAssertGreaterThan(settingsSize.height, 0)

    settingsState.selectedPage = .ai
    let aiSettingsSize = fittingSize(of: FamoSettingsView(
      state: settingsState,
      onSelectSchema: { _ in },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { true },
      onApplyFuzzyConfigFast: { true },
      onSyncUserData: {},
      onResetUserDict: {},
      onChooseSyncDirectory: {},
      onOpenRimeFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    ))
    XCTAssertGreaterThan(aiSettingsSize.width, 0)
    XCTAssertGreaterThan(aiSettingsSize.height, 0)

    let onboardingSize = fittingSize(of: FamoOnboardingView(
      onOpenSystemSettings: {},
      onSelectSchema: { _ in },
      onOpenInputSettings: {},
      onFinish: {},
      isFamoEnabled: { true }
    ))
    // 视图与窗口共用同一组数，锁的是「两边没走散」——窗口比内容大会露底色、小会裁掉底部按钮。
    XCTAssertEqual(onboardingSize.width, FamoOnboardingMetrics.width)
    XCTAssertEqual(onboardingSize.height, FamoOnboardingMetrics.height)

    let emojiSize = fittingSize(of: FamoEmojiPanelView(onPick: { _ in }, onClose: {}))
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

  func testKeyboardPageExposesFirstClassInputModesAndDoublePinyinPickerState() {
    XCTAssertFalse(FamoSettingsPage.visibleCases.contains(.schemes))
    XCTAssertEqual(
      FamoInputMethod.allCases.map(\.displayName),
      ["拼音输入", "双拼输入", "五笔输入"]
    )
    XCTAssertEqual(FamoWubiScheme.allCases.map(\.displayName), ["86 版五笔", "五笔拼音混输"])
    XCTAssertEqual(FamoInputMethod.pinyin.schemaId(doublePinyin: .flypy, wubiScheme: .jidian86), "rime_ice")
    XCTAssertEqual(FamoInputMethod.doublePinyin.schemaId(doublePinyin: .flypy, wubiScheme: .jidian86), "double_pinyin_flypy")
    XCTAssertEqual(FamoInputMethod.wubi.schemaId(doublePinyin: .flypy, wubiScheme: .jidian86), "wubi86_jidian")
    XCTAssertEqual(FamoInputMethod.wubi.schemaId(doublePinyin: .flypy, wubiScheme: .pinyinMix), "wubi86_jidian_pinyin")
    XCTAssertFalse(FamoKeyboardPage.isDoublePinyinPickerEnabled(for: .pinyin))
    XCTAssertTrue(FamoKeyboardPage.isDoublePinyinPickerEnabled(for: .doublePinyin))
    XCTAssertFalse(FamoKeyboardPage.isDoublePinyinPickerEnabled(for: .wubi))
    XCTAssertEqual(FamoKeyboardPage.doublePinyinPickerOpacity(for: .pinyin), 0.4)
    XCTAssertEqual(FamoKeyboardPage.doublePinyinPickerOpacity(for: .doublePinyin), 1)
  }

  func testInputMenuTitlesExposeRuntimeToggles() {
    XCTAssertEqual(FamoInputMenuTitles.cjkInput(asciiMode: true), "切换至中文输入")
    XCTAssertEqual(FamoInputMenuTitles.cjkInput(asciiMode: false), "切换至英文输入")
    XCTAssertEqual(FamoInputMenuTitles.traditionalInput(traditional: false), "切换至繁体输入")
    XCTAssertEqual(FamoInputMenuTitles.traditionalInput(traditional: true), "切换至简体输入")
    XCTAssertEqual(FamoInputMenuTitles.asciiPunctuation(asciiPunct: false), "使用英文标点符号")
    XCTAssertEqual(FamoInputMenuTitles.asciiPunctuation(asciiPunct: true), "使用中文标点符号")
    XCTAssertEqual(FamoInputMenuTitles.fullShape(fullShape: false), "使用全角输入")
    XCTAssertEqual(FamoInputMenuTitles.fullShape(fullShape: true), "使用半角输入")
  }

  func testInputMenuTitlesExposeHighFrequencyTools() {
    XCTAssertEqual(FamoInputMenuTitles.clipboard, "剪贴板…")
    XCTAssertEqual(FamoInputMenuTitles.emoji, "表情符号…")
    XCTAssertEqual(FamoInputMenuTitles.quickSend, "快捷短语…")
    XCTAssertEqual(FamoInputMenuTitles.deploy, "应用配置改动")
    XCTAssertEqual(FamoInputMenuTitles.syncDirectory, "设置同步目录...")
    XCTAssertEqual(FamoInputMenuTitles.syncUserData, "同步用户数据")
  }

  func testWritePreviewReportsDeployFailureAfterSuccessfulWrite() {
    let status = FamoWritePreviewSheet.applyStatusMessage(
      written: ["default.custom.yaml"],
      deploySucceeded: false
    )

    XCTAssertTrue(status.contains("已写入 default.custom.yaml"))
    XCTAssertTrue(status.contains("应用配置失败"))
    XCTAssertFalse(status.contains("已写入并应用配置"))
  }

  func testAboutPageFormatsVersionAndBuildIdentity() {
    XCTAssertEqual(
      FamoAboutPage.versionDisplay(info: [
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "42"
      ]),
      "1.0 (42)"
    )
    XCTAssertEqual(FamoAboutPage.versionDisplay(info: nil), "未知")
    XCTAssertEqual(
      FamoAboutPage.buildIdentityDisplay(bundleIdentifier: "im.famo.inputmethod.Famo"),
      "im.famo.inputmethod.Famo"
    )
    XCTAssertEqual(FamoAboutPage.buildIdentityDisplay(bundleIdentifier: ""), "未知")
  }

  func testFloatingPanelsDoNotStealHostFocus() {
    XCTAssertFalse(FamoSwiftUICandidatePanel().canBecomeKey)
    XCTAssertFalse(FamoEmojiPanel().canBecomeKey)
    // The status HUD is also a non-activating panel — it must never steal host focus.
    XCTAssertFalse(FamoStatusHUD().canBecomeKey)
  }

  // NOTE: `testSwiftUICandidatePanelDefaultsOnButCanOptOut` was removed when the
  // `FamoSwiftUIPanel` feature flag was retired — SwiftUI is now the sole candidate
  // renderer, so there is no opt-out flag left to test.
}

/// G8 候选显示设置 — panel prefs (orientation/typeface/animation/expanded) + Rime page_size.
@MainActor
final class FamoCandidateDisplayTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    for key in ["FamoPanelOrientation", "FamoPanelFontDesign", "FamoPanelAnimations",
                "FamoPanelExpandedByDefault", "FamoPanelPreviewPages", "FamoKeyboardPageSize"] {
      FamoDefaults.standard.removeObject(forKey: key)
    }
  }
  override func tearDown() async throws {
    for key in ["FamoPanelOrientation", "FamoPanelFontDesign", "FamoPanelAnimations",
                "FamoPanelExpandedByDefault", "FamoPanelPreviewPages", "FamoKeyboardPageSize"] {
      FamoDefaults.standard.removeObject(forKey: key)
    }
    try await super.tearDown()
  }

  func testPanelDisplayPrefsDefaultsAndRoundTrip() {
    let settings = FamoCandidatePanelSettings.live
    let state = FamoSettingsState()
    // Defaults.
    XCTAssertEqual(FamoPanelPreferences.orientation, .auto)
    settings.seed(state)
    XCTAssertEqual(state.candidateFont.selection, .default)
    XCTAssertTrue(FamoPanelPreferences.animationsEnabled)
    // Round-trip.
    FamoPanelPreferences.orientation = .vertical
    settings.editFont(.mapleMono, state: state, onChange: {})
    FamoPanelPreferences.animationsEnabled = false
    XCTAssertEqual(FamoPanelPreferences.orientation, .vertical)
    XCTAssertEqual(settings.snapshot().font.selection, .mapleMono)
    XCTAssertFalse(FamoPanelPreferences.animationsEnabled)
  }

  /// 迁移（2026-07-22，「默认形态 单行/卷轴」并入排列方向）：未显式选过排列方向但开过 legacy
  /// `FamoPanelExpandedByDefault` 的老用户，`orientation` 回落到 `.vertical`（原「卷轴」= 展开纵列，
  /// 与竖排同渲染）；一旦显式选任一方向即以新键为准。
  func testOrientationMigratesFromLegacyExpandedByDefault() {
    // 干净起点（setUp 已清两键）：无新键 + legacy 卷轴开 → 竖排。
    FamoDefaults.standard.set(true, forKey: "FamoPanelExpandedByDefault")
    XCTAssertEqual(FamoPanelPreferences.orientation, .vertical)
    // 显式选择压过 legacy 迁移。
    FamoPanelPreferences.orientation = .horizontal
    XCTAssertEqual(FamoPanelPreferences.orientation, .horizontal)
    // legacy 关（或未设）→ 回默认 .auto。
    FamoDefaults.standard.removeObject(forKey: "FamoPanelOrientation")
    FamoDefaults.standard.set(false, forKey: "FamoPanelExpandedByDefault")
    XCTAssertEqual(FamoPanelPreferences.orientation, .auto)
  }

  /// 迁移②（2026-07-26，卷轴取代折行）：存过 `"flow"` 的老用户读出 `.scroll`。
  /// `FamoPanelOrientation(rawValue: "flow")` 已是 nil，靠裸串比对这一支兜住。
  func testOrientationMigratesLegacyFlowToScroll() {
    FamoDefaults.standard.set("flow", forKey: "FamoPanelOrientation")
    XCTAssertEqual(FamoPanelPreferences.orientation, .scroll)
    // 显式改选压过迁移。
    FamoPanelPreferences.orientation = .horizontal
    XCTAssertEqual(FamoPanelPreferences.orientation, .horizontal)
  }

  /// 迁移②：卷轴吸收了「预览后页」开关，开过它的老用户读出 `.scroll`，保住后页行观感。
  /// 关键回归：这一支排在「已存方向」之前，所以显式选过**横排**+开着预览后页的用户也要迁；
  /// 而竖排下预览本就被门控掉，必须维持竖排。
  func testOrientationMigratesLegacyPreviewPagesToScroll() {
    FamoDefaults.standard.set(true, forKey: "FamoPanelPreviewPages")
    // 未显式选过方向。
    XCTAssertEqual(FamoPanelPreferences.orientation, .scroll)
    // 显式选过横排 —— 仍迁到卷轴（否则后页行静默消失）。
    FamoDefaults.standard.set("horizontal", forKey: "FamoPanelOrientation")
    XCTAssertEqual(FamoPanelPreferences.orientation, .scroll)
    // 竖排不迁。
    FamoDefaults.standard.set("vertical", forKey: "FamoPanelOrientation")
    XCTAssertEqual(FamoPanelPreferences.orientation, .vertical)
  }

  /// 写入任一方向即清掉 legacy 开关——否则迁移会一直生效，用户再也选不回单行横排。
  func testWritingOrientationClearsLegacyPreviewPagesKey() {
    FamoDefaults.standard.set(true, forKey: "FamoPanelPreviewPages")
    FamoPanelPreferences.orientation = .horizontal
    XCTAssertNil(FamoDefaults.standard.object(forKey: "FamoPanelPreviewPages"))
    XCTAssertEqual(FamoPanelPreferences.orientation, .horizontal)
  }

  /// 卷轴后页行数：默认 4（2026-07-28 截图定案），钳到 1...4（抵御手改 defaults 写出的
  /// 越界值）；老用户存过的 1/2 落在新区间内原样生效。
  func testScrollRowsDefaultAndClamp() {
    FamoDefaults.standard.removeObject(forKey: "FamoPanelPreviewRows")
    XCTAssertEqual(FamoPanelPreferences.scrollRows, 4)
    FamoPanelPreferences.scrollRows = 1
    XCTAssertEqual(FamoPanelPreferences.scrollRows, 1)
    FamoDefaults.standard.set(9, forKey: "FamoPanelPreviewRows")
    XCTAssertEqual(FamoPanelPreferences.scrollRows, 4)
    FamoDefaults.standard.set(0, forKey: "FamoPanelPreviewRows")
    XCTAssertEqual(FamoPanelPreferences.scrollRows, 1)
    FamoDefaults.standard.set(2, forKey: "FamoPanelPreviewRows")
    XCTAssertEqual(FamoPanelPreferences.scrollRows, 2)
    FamoDefaults.standard.removeObject(forKey: "FamoPanelPreviewRows")
  }

  func testOrientationResolution() {
    // With no schema default, .auto follows Rime's _vertical; explicit overrides ignore it.
    XCTAssertTrue(FamoPanelOrientation.auto.isVertical(rimeVertical: true))
    XCTAssertFalse(FamoPanelOrientation.auto.isVertical(rimeVertical: false))
    XCTAssertFalse(FamoPanelOrientation.horizontal.isVertical(rimeVertical: true))
    XCTAssertTrue(FamoPanelOrientation.vertical.isVertical(rimeVertical: false))
    // 卷轴是横排的一种：`isVertical` 恒 false，`scrolls` 才是它与单行横排的区别。
    XCTAssertFalse(FamoPanelOrientation.scroll.isVertical(rimeVertical: true))
    XCTAssertTrue(FamoPanelOrientation.scroll.scrolls)
    XCTAssertFalse(FamoPanelOrientation.horizontal.scrolls)
  }

  func testAutoOrientationIsHorizontalForWubiSchemas() {
    // Fix #2 (2026-06-22): the old Wubi-forces-vertical special case was removed. With
    // orientation 自动, every schema — including Wubi — follows ONLY rime's _vertical, so a
    // Wubi schema with rimeVertical:false now resolves to horizontal like rime_ice.
    XCTAssertFalse(FamoPanelOrientation.auto.isVertical(rimeVertical: false, schemaID: "wubi86_jidian"))
    XCTAssertFalse(FamoPanelOrientation.auto.isVertical(rimeVertical: false, schemaID: "wubi86_jidian_pinyin"))
    XCTAssertFalse(FamoPanelOrientation.auto.isVertical(rimeVertical: false, schemaID: "wubi86_jidian_trad"))
    XCTAssertFalse(FamoPanelOrientation.auto.isVertical(rimeVertical: false, schemaID: "wubi86_jidian_trad_pinyin"))
    XCTAssertFalse(FamoPanelOrientation.auto.isVertical(rimeVertical: false, schemaID: "rime_ice"))
    // …but a schema that DOES set rime _vertical still goes vertical under 自动.
    XCTAssertTrue(FamoPanelOrientation.auto.isVertical(rimeVertical: true, schemaID: "wubi86_jidian"))
  }

  func testExplicitOrientationStillOverridesForAnySchema() {
    // Explicit 横排/竖排 win regardless of schema and regardless of rime _vertical.
    XCTAssertFalse(FamoPanelOrientation.horizontal.isVertical(rimeVertical: true, schemaID: "wubi86_jidian"))
    XCTAssertTrue(FamoPanelOrientation.vertical.isVertical(rimeVertical: false, schemaID: "wubi86_jidian"))
    XCTAssertTrue(FamoPanelOrientation.vertical.isVertical(rimeVertical: false, schemaID: "rime_ice"))
  }

  func testCandidateFontDownloadURL() {
    XCTAssertEqual(
      FamoCandidateFontSelection.mapleMonoDownloadURL.absoluteString,
      "https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-CN.zip"
    )
  }

  func testPageSizeDefaultAndClamp() {
    XCTAssertEqual(FamoKeyboardPreferences.pageSize, 8)       // default
    FamoKeyboardPreferences.pageSize = 5
    XCTAssertEqual(FamoKeyboardPreferences.pageSize, 5)
    FamoKeyboardPreferences.pageSize = 99                     // clamp high
    XCTAssertEqual(FamoKeyboardPreferences.pageSize, 9)
    FamoKeyboardPreferences.pageSize = 1                      // clamp low
    XCTAssertEqual(FamoKeyboardPreferences.pageSize, 3)
  }

  func testKeyboardPatchEmitsConfiguredPageSize() {
    FamoKeyboardPreferences.pageSize = 6
    let yaml = famoDefaultCustomYAML(from: FamoKeyboardSnapshot.current())
    XCTAssertTrue(yaml.contains("\"menu/page_size\": 6"), "patch must carry the chosen 候选个数")
    XCTAssertFalse(yaml.contains("\"menu/page_size\": 8"), "no stale hardcoded 8")
  }

  func testCandidatePageSizeApplyStatusReportsDeployFailureAsNotEffective() {
    let status = FamoSettingsView.candidatePageSizeApplyStatusMessage(
      written: ["default.custom.yaml"],
      deploySucceeded: false
    )

    // PR3: copy moved from deploy-implying "重新部署失败" to immediate "应用失败".
    XCTAssertTrue(status.contains("应用失败"))
    XCTAssertFalse(status.contains("重新部署"))
    XCTAssertTrue(status.contains("候选个数未生效"))
  }
}

// MARK: - B4 选中润色 (FamoSelectionPolish) — pure prompt/policy + service guards

@MainActor
private final class FakePolishFetcher: FamoSelectionPolishFetching {
  var calls = 0
  var capturedSelection: String?
  var capturedAPIKey: String?
  let handler: (String) async throws -> [String]

  init(handler: @escaping (String) async throws -> [String]) {
    self.handler = handler
  }

  func fetchPolishedRewrites(for selection: String, apiKey: String) async throws -> [String] {
    calls += 1
    capturedSelection = selection
    capturedAPIKey = apiKey
    return try await handler(selection)
  }
}

final class FamoSelectionPolishPromptTests: XCTestCase {

  func testPolishPromptAsksForJSONCandidatesAndRewrite() {
    // B4 reuses the json_object {"candidates":[...]} contract so the shared parser is reused.
    let prompt = FamoSelectionPolish.systemPrompt
    XCTAssertTrue(prompt.contains("{\"candidates\":"), "polish prompt must demand the {\"candidates\":[...]} shape")
    XCTAssertTrue(prompt.lowercased().contains("json"), "polish prompt must ask for JSON (json_object mode)")
    XCTAssertTrue(
      prompt.contains("改写") || prompt.lowercased().contains("rewrite") || prompt.lowercased().contains("polish"),
      "polish prompt must ask for a rewrite / polish"
    )
  }

  func testRejectionReasonRejectsEmptyAndWhitespaceOnly() {
    XCTAssertEqual(FamoSelectionPolish.rejectionReason(for: ""), .emptySelection)
    XCTAssertEqual(FamoSelectionPolish.rejectionReason(for: "   \n\t "), .emptySelection)
  }

  func testRejectionReasonCapsLongSelections() {
    let ok = String(repeating: "甲", count: FamoSelectionPolish.maxSelectionLength)
    XCTAssertNil(FamoSelectionPolish.rejectionReason(for: ok), "selection at the cap is acceptable")

    let tooLong = String(repeating: "甲", count: FamoSelectionPolish.maxSelectionLength + 1)
    XCTAssertEqual(
      FamoSelectionPolish.rejectionReason(for: tooLong),
      .selectionTooLong(FamoSelectionPolish.maxSelectionLength + 1),
      "selection beyond the cap must be rejected (privacy + cost guard)"
    )
  }

  func testPolishRequestUsesFlashModelAndJSONObjectAndCarriesSelectedText() throws {
    FamoCloudPreferences.resetForTesting()
    defer { FamoCloudPreferences.resetForTesting() }

    let request = try FamoSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(request.model, FamoCloudPreferences.deepSeekModel, "polish uses the flash model")
    XCTAssertEqual(request.responseFormat, .jsonObject)
    // The selected text IS the payload here — the documented CodeOnly exception.
    let userContent = request.messages.first(where: { $0.role == "user" })?.content ?? ""
    XCTAssertTrue(userContent.contains("他撤销了合同"), "the user payload carries the selected text")
  }

  func testPolishRequestContainsOnlyPromptAndExplicitSelection() throws {
    let request = try FamoSelectionPolish.chatRequest(for: "好的")
    XCTAssertEqual(request.messages.map(\.role), ["system", "user"])
    XCTAssertTrue(request.messages[1].content.contains("好的"))
  }

  /// Redaction is removed: B4 sends the selected document text VERBATIM (raw). PII in the selection
  /// reaches the wire as-is — the privacy trade-off was an explicit user decision (2026-06-23).
  func testPolishRequestSendsSelectionRawWithoutMasking() throws {
    FamoCloudPreferences.resetForTesting()
    defer { FamoCloudPreferences.resetForTesting() }

    let selection = "原告联系方式PHONE_SENTINEL邮箱EMAIL_SENTINEL案号CASE_SENTINEL依据第107条撤销合同"
    let request = try FamoSelectionPolish.chatRequest(for: selection)
    let userContent = request.messages.first(where: { $0.role == "user" })?.content ?? ""

    // Raw passthrough: every field is carried verbatim, no masking placeholder.
    XCTAssertTrue(userContent.contains("PHONE_SENTINEL"), "explicit phone placeholder is sent raw")
    XCTAssertTrue(userContent.contains("EMAIL_SENTINEL"), "explicit e-mail placeholder is sent raw")
    XCTAssertTrue(userContent.contains("CASE_SENTINEL"), "explicit case placeholder is sent raw")
    XCTAssertTrue(userContent.contains("第107条"), "legal article number survives")
    XCTAssertTrue(userContent.contains("撤销合同"), "ordinary legal text survives")
  }
}

final class FamoSourceVerificationServiceTests: XCTestCase {

  func testParseResponseExtractsSummaryAndDedupedSources() throws {
    let json = """
    {
      "choices": [
        {
          "message": {
            "content": "该表述需要以正式法规文本和监管说明交叉核验。",
            "annotations": [
              {
                "type": "url_citation",
                "title": "全国人大常委会法工委",
                "url": "https://www.npc.gov.cn/example"
              },
              {
                "title": "重复来源",
                "url": "https://www.npc.gov.cn/example"
              }
            ]
          }
        }
      ],
      "search_results": [
        {
          "title": "国务院政策文件库",
          "url": "https://www.gov.cn/example"
        }
      ]
    }
    """

    let parsed = FamoSourceVerificationService.parseResponse(Data(json.utf8))

    XCTAssertTrue(parsed.content.contains("正式法规文本"))
    XCTAssertEqual(Set(parsed.sources.map(\.url)), [
      "https://www.npc.gov.cn/example",
      "https://www.gov.cn/example",
    ])
    XCTAssertEqual(parsed.sources.count, 2, "duplicate URLs should be collapsed")
  }

  func testRenderWithSourcesMarksResultAsVerifiable() {
    let rendered = FamoSourceVerificationService.render(
      content: "检索到正式来源，但仍需核对条文适用范围。",
      sources: [
        FamoVerifiedSource(title: "正式来源", url: "https://www.gov.cn/example"),
      ]
    )

    XCTAssertTrue(rendered.contains("已找到可核来源"))
    XCTAssertTrue(rendered.contains("https://www.gov.cn/example"))
    XCTAssertFalse(rendered.contains("未找到可核来源"))
  }

  func testRenderWithoutSourcesKeepsManualCheckBoundary() {
    let summaryOnly = FamoSourceVerificationService.render(
      content: "模型给出了摘要，但没有可抽取 URL。",
      sources: []
    )
    XCTAssertTrue(summaryOnly.contains("需要人工确认"))
    XCTAssertTrue(summaryOnly.contains("不要把下面内容当作已完成核验"))

    let empty = FamoSourceVerificationService.render(content: "", sources: [])
    XCTAssertTrue(empty.contains("未找到可核来源"))
    XCTAssertTrue(empty.contains("不等于事实不存在"))
  }
}

@MainActor
final class FamoSelectionPolishServiceTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    FamoCloudPreferences.resetForTesting()
    FamoCloudUsageTelemetry.resetForTesting()
  }

  override func tearDown() async throws {
    FamoCloudPreferences.resetForTesting()
    FamoCloudUsageTelemetry.resetForTesting()
    try await super.tearDown()
  }

  func testDisabledStopsBeforeKeychainAndFetcher() async {
    // Default-off: no keychain read, no fetch.
    var keychainCalls = 0
    let fetcher = FakePolishFetcher { _ in
      XCTFail("Default-off polish must not call the fetcher")
      return []
    }
    let service = FamoSelectionPolishService(fetcher: fetcher, apiKeyProvider: {
      keychainCalls += 1
      return "sk-test"
    })

    do {
      _ = try await service.polishSelection("他撤销了合同")
      XCTFail("disabled polish must throw")
    } catch let error as FamoSelectionPolishError {
      XCTAssertEqual(error, .disabled)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(keychainCalls, 0)
    XCTAssertEqual(fetcher.calls, 0)
  }

  func testLengthCapStopsBeforeKeychainAndFetcher() async {
    FamoCloudPreferences.isEnabled = true
    var keychainCalls = 0
    let fetcher = FakePolishFetcher { _ in
      XCTFail("Over-cap selection must not be uploaded")
      return []
    }
    let service = FamoSelectionPolishService(fetcher: fetcher, apiKeyProvider: {
      keychainCalls += 1
      return "sk-test"
    })

    let tooLong = String(repeating: "甲", count: FamoSelectionPolish.maxSelectionLength + 1)
    do {
      _ = try await service.polishSelection(tooLong)
      XCTFail("over-cap selection must throw")
    } catch let error as FamoSelectionPolishError {
      XCTAssertEqual(error, .selectionTooLong(FamoSelectionPolish.maxSelectionLength + 1))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(keychainCalls, 0, "length cap must stop before any keychain read")
    XCTAssertEqual(fetcher.calls, 0, "length cap must stop before any upload")
  }

  func testMissingAPIKeyStopsBeforeFetcher() async {
    FamoCloudPreferences.isEnabled = true
    let fetcher = FakePolishFetcher { _ in
      XCTFail("Missing key must stop before any fetch")
      return []
    }
    let service = FamoSelectionPolishService(fetcher: fetcher, apiKeyProvider: { nil }, profileProvider: { nil })

    do {
      _ = try await service.polishSelection("他撤销了合同")
      XCTFail("missing key must throw")
    } catch let error as FamoSelectionPolishError {
      XCTAssertEqual(error, .missingAPIKey)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(fetcher.calls, 0)
  }

  func testEnabledPolishReturnsRewritesBestFirst() async throws {
    FamoCloudPreferences.isEnabled = true
    let fetcher = FakePolishFetcher { _ in ["他解除了合同", "合同被其解除"] }
    let service = FamoSelectionPolishService(fetcher: fetcher, apiKeyProvider: { "sk-test" }, profileProvider: { nil })

    let rewrites = try await service.polishSelection("他撤销了合同")

    XCTAssertEqual(fetcher.calls, 1)
    XCTAssertEqual(fetcher.capturedSelection, "他撤销了合同")
    XCTAssertEqual(fetcher.capturedAPIKey, "sk-test")
    XCTAssertEqual(rewrites, ["他解除了合同", "合同被其解除"])
  }

  func testPolishRoutesThroughActiveProviderProfileKey() async throws {
    // FAMO-098: 润色选中 must use the ACTIVE provider profile's key (not only the legacy DeepSeek
    // key), so a user configured with OpenAI / Gemini / 自定义 can polish selections. The legacy
    // key reader must NOT be consulted when a profile with a secret is active.
    FamoCloudPreferences.isEnabled = true
    let fetcher = FakePolishFetcher { _ in ["他解除了合同"] }
    let profile = FamoProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "famo.provider.unit.apiKey",
      isDefault: true
    )
    let service = FamoSelectionPolishService(
      fetcher: fetcher,
      apiKeyProvider: { XCTFail("active profile must not read the legacy DeepSeek key"); return nil },
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-profile" }
    )

    let rewrites = try await service.polishSelection("他撤销了合同")

    XCTAssertEqual(fetcher.capturedAPIKey, "sk-profile", "must use the per-profile key, not the legacy key")
    XCTAssertEqual(rewrites, ["他解除了合同"])
  }

  func testEmptyResultRetriesOnceThenReturnsEmpty() async throws {
    // Reuses the candidate lane's bounded-retry policy: empty content is transient → one retry.
    FamoCloudPreferences.isEnabled = true
    let fetcher = FakePolishFetcher { _ in throw FamoCloudRequestError.emptyResponse }
    let service = FamoSelectionPolishService(fetcher: fetcher, apiKeyProvider: { "sk-test" }, profileProvider: { nil })

    do {
      _ = try await service.polishSelection("他撤销了合同")
      XCTFail("persistent empty response should surface the error")
    } catch let error as FamoCloudRequestError {
      XCTAssertEqual(error, .emptyResponse)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(fetcher.calls, 2, "empty content is transient → exactly one retry")
  }
}
