//
//  FamoUpdateLogoutPromptTests.swift
//  FamoTests — 注销线（#116/#109/#111）
//
//  Locks:
//   - #109 A1「处置后才记录，首装立即播种」：`shouldSuggest`（纯）+ `planPrompt`（更新路径【不】记录、
//     首装/同版本播种）+ `recordDisposition`（处置后记录）的可注入 UserDefaults 副作用。
//   - #111 失败遥测 `FamoLogoutDiagnostics`：分类、覆盖式写入/读回/清除、诊断包章节。
//   - #131 B2 纯判定层 `FamoLogoutPromptTiming`：安全时机归因（合成/输入/loginwindow）、搁浅合成阀、
//     激活确认阀、条件读不到不阻塞、日志变化键——锁「任何门控条件都不得造成不可观测的永久静默」。
//  NSAlert 呈现 / 注销 AppleEvent / 调度器与系统信号的接线 = 真机手验（modal UI，不进 XCTest）。
//

import XCTest
@testable import Famo

final class FamoUpdateLogoutPromptTests: XCTestCase {
  // MARK: shouldSuggest (pure) —— 不变

  func test_shouldSuggest_firstLaunchNil_false() {
    XCTAssertFalse(FamoUpdateLogoutPrompt.shouldSuggest(lastRun: nil, current: "1.4.8"))
  }

  func test_shouldSuggest_emptyLast_false() {
    XCTAssertFalse(FamoUpdateLogoutPrompt.shouldSuggest(lastRun: "", current: "1.4.8"))
  }

  func test_shouldSuggest_emptyCurrent_false() {
    XCTAssertFalse(FamoUpdateLogoutPrompt.shouldSuggest(lastRun: "1.4.7", current: ""))
  }

  func test_shouldSuggest_versionChanged_true() {
    XCTAssertTrue(FamoUpdateLogoutPrompt.shouldSuggest(lastRun: "1.4.7", current: "1.4.8"))
  }

  func test_shouldSuggest_sameVersion_false() {
    XCTAssertFalse(FamoUpdateLogoutPrompt.shouldSuggest(lastRun: "1.4.8", current: "1.4.8"))
  }

  // MARK: A1 —— planPrompt（更新不记录 / 首装/同版本播种）+ recordDisposition（处置后记录）

  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "test.famo.logout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  func test_planPrompt_firstLaunch_seedsAndNoPrompt() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(FamoUpdateLogoutPrompt.planPrompt(current: "1.4.8", defaults: defaults),
                   "首启（无 lastRun）不弹")
    XCTAssertEqual(defaults.string(forKey: FamoUpdateLogoutPrompt.lastRunVersionKey), "1.4.8",
                   "首装立即播种当前版本")
  }

  func test_planPrompt_sameVersion_noPromptAndRecorded() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.4.8", forKey: FamoUpdateLogoutPrompt.lastRunVersionKey)
    XCTAssertFalse(FamoUpdateLogoutPrompt.planPrompt(current: "1.4.8", defaults: defaults),
                   "同版本不弹")
    XCTAssertEqual(defaults.string(forKey: FamoUpdateLogoutPrompt.lastRunVersionKey), "1.4.8")
  }

  func test_planPrompt_afterUpdate_promptsWithoutRecording() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.4.7", forKey: FamoUpdateLogoutPrompt.lastRunVersionKey)
    XCTAssertTrue(FamoUpdateLogoutPrompt.planPrompt(current: "1.4.8", defaults: defaults),
                  "版本变化应弹")
    XCTAssertEqual(defaults.string(forKey: FamoUpdateLogoutPrompt.lastRunVersionKey), "1.4.7",
                   "A1：更新路径【不】在 planPrompt 里记录——仍是旧版本，待处置后才记录")
  }

  func test_recordDisposition_recordsCurrent() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.4.7", forKey: FamoUpdateLogoutPrompt.lastRunVersionKey)
    FamoUpdateLogoutPrompt.recordDisposition(current: "1.4.8", defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: FamoUpdateLogoutPrompt.lastRunVersionKey), "1.4.8")
  }

  func test_recordDisposition_emptyCurrent_noOp() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.4.7", forKey: FamoUpdateLogoutPrompt.lastRunVersionKey)
    FamoUpdateLogoutPrompt.recordDisposition(current: "", defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: FamoUpdateLogoutPrompt.lastRunVersionKey), "1.4.7",
                   "空版本不覆盖已有记录")
  }

  func test_updateLifecycle_planThenRecord_noRepeat() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.4.7", forKey: FamoUpdateLogoutPrompt.lastRunVersionKey)
    // 首次更新：待弹、未记录
    XCTAssertTrue(FamoUpdateLogoutPrompt.planPrompt(current: "1.4.8", defaults: defaults))
    XCTAssertEqual(defaults.string(forKey: FamoUpdateLogoutPrompt.lastRunVersionKey), "1.4.7",
                   "未处置前不记录")
    // 处置后记录
    FamoUpdateLogoutPrompt.recordDisposition(current: "1.4.8", defaults: defaults)
    // 再次启动：同版本不再弹
    XCTAssertFalse(FamoUpdateLogoutPrompt.planPrompt(current: "1.4.8", defaults: defaults),
                   "处置并记录后，同版本再启动不重弹")
  }

  // MARK: #111 遥测 —— FamoLogoutDiagnostics

  func test_classify_errorCodes() {
    XCTAssertEqual(FamoLogoutDiagnostics.classify(errorNumber: -1743), .automationDenied)
    XCTAssertEqual(FamoLogoutDiagnostics.classify(errorNumber: -1712), .timeout)
    XCTAssertEqual(FamoLogoutDiagnostics.classify(errorNumber: -128), .other)
    XCTAssertEqual(FamoLogoutDiagnostics.classify(errorNumber: nil), .other)
  }

  func test_diagnostics_recordThenReadBack_roundtrip() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    FamoLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    let f = FamoLogoutDiagnostics.lastFailure(defaults: defaults)
    XCTAssertNotNil(f)
    XCTAssertEqual(f?.errorNumber, -1743)
    XCTAssertEqual(f?.category, "automationDenied")
    XCTAssertEqual(f?.phase, "appleScriptSend")
    XCTAssertEqual(f?.schemaVersion, FamoLogoutDiagnostics.schemaVersion)
    XCTAssertFalse(f?.timestampUTC.isEmpty ?? true, "有 UTC 时间戳")
  }

  func test_diagnostics_recordIsOverwrite_keepsLatest() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    FamoLogoutDiagnostics.record(errorNumber: -1712, category: .timeout, defaults: defaults)
    FamoLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    XCTAssertEqual(FamoLogoutDiagnostics.lastFailure(defaults: defaults)?.errorNumber, -1743,
                   "覆盖式：只留最新一条")
  }

  func test_diagnostics_clear_removesFailure() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    FamoLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    FamoLogoutDiagnostics.clear(defaults: defaults)
    XCTAssertNil(FamoLogoutDiagnostics.lastFailure(defaults: defaults))
  }

  func test_diagnostics_supportBundleSection_emptyAndPopulated() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(FamoLogoutDiagnostics.supportBundleSection(defaults: defaults).contains("无最近失败记录"))
    FamoLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    let section = FamoLogoutDiagnostics.supportBundleSection(defaults: defaults)
    XCTAssertTrue(section.contains("## 注销诊断"))
    XCTAssertTrue(section.contains("-1743"))
    XCTAssertTrue(section.contains("automationDenied"))
  }

  // MARK: #131 —— B2 纯判定层 FamoLogoutPromptTiming：安全时机归因 + 反「永久静默」两阀

  func test_timing_safe_whenNoCompositionAndIdle() {
    let v = FamoLogoutPromptTiming.safeVerdict(
      .init(snapshotID: nil, idleSeconds: 5.0, isLoginWindow: false), blockedTicks: 0)
    XCTAssertEqual(v, .safe(staleCompositionOverride: false))
  }

  func test_timing_blocked_byFreshComposition() {
    let v = FamoLogoutPromptTiming.safeVerdict(
      .init(snapshotID: 7, idleSeconds: 5.0, isLoginWindow: false), blockedTicks: 3)
    XCTAssertEqual(v, .blocked(.composing(snapshotID: 7, blockedTicks: 3)),
                   "真合成必须阻塞（B2 语义不变）")
  }

  func test_timing_staleComposition_overridesAfterThreshold() {
    let v = FamoLogoutPromptTiming.safeVerdict(
      .init(snapshotID: 7, idleSeconds: 5.0, isLoginWindow: false),
      blockedTicks: FamoLogoutPromptTiming.staleCompositionTicks)
    XCTAssertEqual(v, .safe(staleCompositionOverride: true),
                   "#131 根因场景：搁浅合成(#37 类)不得造成永久静默")
  }

  func test_timing_staleOverride_stillBlockedByInputBusy() {
    let v = FamoLogoutPromptTiming.safeVerdict(
      .init(snapshotID: 7, idleSeconds: 0.5, isLoginWindow: false),
      blockedTicks: FamoLogoutPromptTiming.staleCompositionTicks)
    XCTAssertEqual(v, .blocked(.inputBusy(idleSeconds: 0.5)),
                   "搁浅阀只旁路合成判据；用户正在输入仍不弹")
  }

  func test_timing_blocked_byLoginWindow() {
    let v = FamoLogoutPromptTiming.safeVerdict(
      .init(snapshotID: nil, idleSeconds: 5.0, isLoginWindow: true), blockedTicks: 0)
    XCTAssertEqual(v, .blocked(.loginWindow))
  }

  func test_timing_idleUnknown_doesNotBlock() {
    let v = FamoLogoutPromptTiming.safeVerdict(
      .init(snapshotID: nil, idleSeconds: nil, isLoginWindow: false), blockedTicks: 0)
    XCTAssertEqual(v, .safe(staleCompositionOverride: false),
                   "#131 类别禁令：条件读不到 ≠ 永久阻塞")
  }

  func test_timing_snapshotTracker_accruesResetsAndClears() {
    var t = FamoLogoutPromptTiming.SnapshotBlockTracker()
    XCTAssertEqual(t.observe(7), 1)
    XCTAssertEqual(t.observe(7), 2)
    XCTAssertEqual(t.observe(7), 3, "同一快照连续观测累计")
    XCTAssertEqual(t.observe(9), 1, "新快照（用户在打字）计数归一")
    XCTAssertEqual(t.observe(nil), 0, "合成结束清零")
    XCTAssertEqual(t.observe(9), 1, "清零后重新累计")
  }

  func test_timing_activation_presentsImmediatelyWhenActive() {
    XCTAssertEqual(FamoLogoutPromptTiming.activationVerdict(isActive: true, awaitingTicks: 1),
                   .present(forcedWithoutActiveConfirm: false))
  }

  func test_timing_activation_waitsBelowThreshold() {
    XCTAssertEqual(
      FamoLogoutPromptTiming.activationVerdict(
        isActive: false, awaitingTicks: FamoLogoutPromptTiming.activationConfirmTicks - 1),
      .waitNextTick)
  }

  func test_timing_activation_forcesPresentAtThreshold() {
    XCTAssertEqual(
      FamoLogoutPromptTiming.activationVerdict(
        isActive: false, awaitingTicks: FamoLogoutPromptTiming.activationConfirmTicks),
      .present(forcedWithoutActiveConfirm: true),
      "#131 阀：isActive 永不确认也不得永久静默（FamoAIWindow 先例本就不查 isActive）")
  }

  func test_timing_transitionKey_collapsesComposingDetail() {
    let a = FamoLogoutPromptTiming.SafeVerdict.blocked(.composing(snapshotID: 1, blockedTicks: 1))
    let b = FamoLogoutPromptTiming.SafeVerdict.blocked(.composing(snapshotID: 2, blockedTicks: 9))
    XCTAssertEqual(a.transitionKey, b.transitionKey, "连续打字不因快照更迭刷屏（细节走心跳行）")
    XCTAssertNotEqual(
      FamoLogoutPromptTiming.SafeVerdict.safe(staleCompositionOverride: true).transitionKey,
      FamoLogoutPromptTiming.SafeVerdict.safe(staleCompositionOverride: false).transitionKey,
      "搁浅放行与正常放行必须留下可区分的日志键")
  }
}
