//
//  OwlUpdateLogoutPromptTests.swift
//  OwltypeTests — 注销线（#116/#109/#111）
//
//  Locks:
//   - #109 A1「处置后才记录，首装立即播种」：`shouldSuggest`（纯）+ `planPrompt`（更新路径【不】记录、
//     首装/同版本播种）+ `recordDisposition`（处置后记录）的可注入 UserDefaults 副作用。
//   - #111 失败遥测 `OwlLogoutDiagnostics`：分类、覆盖式写入/读回/清除、诊断包章节。
//   - #131 B2 纯判定层 `OwlLogoutPromptTiming`：安全时机归因（合成/输入/loginwindow）、搁浅合成阀、
//     激活确认阀、条件读不到不阻塞、日志变化键——锁「任何门控条件都不得造成不可观测的永久静默」。
//  NSAlert 呈现 / 注销 AppleEvent / 调度器与系统信号的接线 = 真机手验（modal UI，不进 XCTest）。
//

import XCTest
@testable import Owltype

final class OwlUpdateLogoutPromptTests: XCTestCase {
  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "test.owltype.logout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  func testUpgradeDowngradeAndFirstLaunchNeverPromptWithoutFailedSelfCheck() {
    for old in [nil, "", "2.0.12", "2.0.13", "2.0.14"] as [String?] {
      let (defaults, suite) = freshDefaults()
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(old, forKey: OwlUpdateLogoutPrompt.lastRunVersionKey)
      XCTAssertFalse(OwlUpdateLogoutPrompt.planPrompt(current: "2.0.13", defaults: defaults))
    }
  }

  func testOnlyFailureForCurrentBuildAllowsPrompt() {
    XCTAssertTrue(OwlUpdateLogoutPrompt.shouldSuggest(failedVersion: "2.0.13", current: "2.0.13"))
    XCTAssertFalse(OwlUpdateLogoutPrompt.shouldSuggest(failedVersion: "2.0.12", current: "2.0.13"))
    XCTAssertFalse(OwlUpdateLogoutPrompt.shouldSuggest(failedVersion: nil, current: "2.0.13"))
    XCTAssertFalse(OwlUpdateLogoutPrompt.shouldSuggest(failedVersion: "", current: ""))
  }

  func testFailedSelfCheckPromptsUntilDispositionAndSuccessClearsFailure() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("2.0.13", forKey: OwlUpdateLogoutPrompt.failureVersionKey)
    XCTAssertTrue(OwlUpdateLogoutPrompt.planPrompt(current: "2.0.13", defaults: defaults))
    OwlUpdateLogoutPrompt.recordDisposition(current: "2.0.13", defaults: defaults)
    XCTAssertFalse(OwlUpdateLogoutPrompt.planPrompt(current: "2.0.13", defaults: defaults))
    defaults.set("2.0.13", forKey: OwlUpdateLogoutPrompt.failureVersionKey)
    OwlUpdateLogoutPrompt.recordSelfCheck(current: "2.0.13", passed: true, defaults: defaults)
    XCTAssertFalse(OwlUpdateLogoutPrompt.planPrompt(current: "2.0.13", defaults: defaults))
  }

  // MARK: #111 遥测 —— OwlLogoutDiagnostics

  func test_classify_errorCodes() {
    XCTAssertEqual(OwlLogoutDiagnostics.classify(errorNumber: -1743), .automationDenied)
    XCTAssertEqual(OwlLogoutDiagnostics.classify(errorNumber: -1712), .timeout)
    XCTAssertEqual(OwlLogoutDiagnostics.classify(errorNumber: -128), .other)
    XCTAssertEqual(OwlLogoutDiagnostics.classify(errorNumber: nil), .other)
  }

  func test_diagnostics_recordThenReadBack_roundtrip() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    OwlLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    let f = OwlLogoutDiagnostics.lastFailure(defaults: defaults)
    XCTAssertNotNil(f)
    XCTAssertEqual(f?.errorNumber, -1743)
    XCTAssertEqual(f?.category, "automationDenied")
    XCTAssertEqual(f?.phase, "appleScriptSend")
    XCTAssertEqual(f?.schemaVersion, OwlLogoutDiagnostics.schemaVersion)
    XCTAssertFalse(f?.timestampUTC.isEmpty ?? true, "有 UTC 时间戳")
  }

  func test_diagnostics_recordIsOverwrite_keepsLatest() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    OwlLogoutDiagnostics.record(errorNumber: -1712, category: .timeout, defaults: defaults)
    OwlLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    XCTAssertEqual(OwlLogoutDiagnostics.lastFailure(defaults: defaults)?.errorNumber, -1743,
                   "覆盖式：只留最新一条")
  }

  func test_diagnostics_clear_removesFailure() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    OwlLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    OwlLogoutDiagnostics.clear(defaults: defaults)
    XCTAssertNil(OwlLogoutDiagnostics.lastFailure(defaults: defaults))
  }

  func test_diagnostics_supportBundleSection_emptyAndPopulated() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(OwlLogoutDiagnostics.supportBundleSection(defaults: defaults).contains("无最近失败记录"))
    OwlLogoutDiagnostics.record(errorNumber: -1743, category: .automationDenied, defaults: defaults)
    let section = OwlLogoutDiagnostics.supportBundleSection(defaults: defaults)
    XCTAssertTrue(section.contains("## 注销诊断"))
    XCTAssertTrue(section.contains("-1743"))
    XCTAssertTrue(section.contains("automationDenied"))
  }

  // MARK: #131 —— B2 纯判定层 OwlLogoutPromptTiming：安全时机归因 + 反「永久静默」两阀

  func test_timing_safe_whenNoCompositionAndIdle() {
    let v = OwlLogoutPromptTiming.safeVerdict(
      .init(snapshotID: nil, idleSeconds: 5.0, isLoginWindow: false), blockedTicks: 0)
    XCTAssertEqual(v, .safe(staleCompositionOverride: false))
  }

  func test_timing_blocked_byFreshComposition() {
    let v = OwlLogoutPromptTiming.safeVerdict(
      .init(snapshotID: 7, idleSeconds: 5.0, isLoginWindow: false), blockedTicks: 3)
    XCTAssertEqual(v, .blocked(.composing(snapshotID: 7, blockedTicks: 3)),
                   "真合成必须阻塞（B2 语义不变）")
  }

  func test_timing_staleComposition_overridesAfterThreshold() {
    let v = OwlLogoutPromptTiming.safeVerdict(
      .init(snapshotID: 7, idleSeconds: 5.0, isLoginWindow: false),
      blockedTicks: OwlLogoutPromptTiming.staleCompositionTicks)
    XCTAssertEqual(v, .safe(staleCompositionOverride: true),
                   "#131 根因场景：搁浅合成(#37 类)不得造成永久静默")
  }

  func test_timing_staleOverride_stillBlockedByInputBusy() {
    let v = OwlLogoutPromptTiming.safeVerdict(
      .init(snapshotID: 7, idleSeconds: 0.5, isLoginWindow: false),
      blockedTicks: OwlLogoutPromptTiming.staleCompositionTicks)
    XCTAssertEqual(v, .blocked(.inputBusy(idleSeconds: 0.5)),
                   "搁浅阀只旁路合成判据；用户正在输入仍不弹")
  }

  func test_timing_blocked_byLoginWindow() {
    let v = OwlLogoutPromptTiming.safeVerdict(
      .init(snapshotID: nil, idleSeconds: 5.0, isLoginWindow: true), blockedTicks: 0)
    XCTAssertEqual(v, .blocked(.loginWindow))
  }

  func test_timing_idleUnknown_doesNotBlock() {
    let v = OwlLogoutPromptTiming.safeVerdict(
      .init(snapshotID: nil, idleSeconds: nil, isLoginWindow: false), blockedTicks: 0)
    XCTAssertEqual(v, .safe(staleCompositionOverride: false),
                   "#131 类别禁令：条件读不到 ≠ 永久阻塞")
  }

  func test_timing_snapshotTracker_accruesResetsAndClears() {
    var t = OwlLogoutPromptTiming.SnapshotBlockTracker()
    XCTAssertEqual(t.observe(7), 1)
    XCTAssertEqual(t.observe(7), 2)
    XCTAssertEqual(t.observe(7), 3, "同一快照连续观测累计")
    XCTAssertEqual(t.observe(9), 1, "新快照（用户在打字）计数归一")
    XCTAssertEqual(t.observe(nil), 0, "合成结束清零")
    XCTAssertEqual(t.observe(9), 1, "清零后重新累计")
  }

  func test_timing_activation_presentsImmediatelyWhenActive() {
    XCTAssertEqual(OwlLogoutPromptTiming.activationVerdict(isActive: true, awaitingTicks: 1),
                   .present(forcedWithoutActiveConfirm: false))
  }

  func test_timing_activation_waitsBelowThreshold() {
    XCTAssertEqual(
      OwlLogoutPromptTiming.activationVerdict(
        isActive: false, awaitingTicks: OwlLogoutPromptTiming.activationConfirmTicks - 1),
      .waitNextTick)
  }

  func test_timing_activation_forcesPresentAtThreshold() {
    XCTAssertEqual(
      OwlLogoutPromptTiming.activationVerdict(
        isActive: false, awaitingTicks: OwlLogoutPromptTiming.activationConfirmTicks),
      .present(forcedWithoutActiveConfirm: true),
      "#131 阀：isActive 永不确认也不得永久静默（OwlAIWindow 先例本就不查 isActive）")
  }

  func test_timing_transitionKey_collapsesComposingDetail() {
    let a = OwlLogoutPromptTiming.SafeVerdict.blocked(.composing(snapshotID: 1, blockedTicks: 1))
    let b = OwlLogoutPromptTiming.SafeVerdict.blocked(.composing(snapshotID: 2, blockedTicks: 9))
    XCTAssertEqual(a.transitionKey, b.transitionKey, "连续打字不因快照更迭刷屏（细节走心跳行）")
    XCTAssertNotEqual(
      OwlLogoutPromptTiming.SafeVerdict.safe(staleCompositionOverride: true).transitionKey,
      OwlLogoutPromptTiming.SafeVerdict.safe(staleCompositionOverride: false).transitionKey,
      "搁浅放行与正常放行必须留下可区分的日志键")
  }
}
