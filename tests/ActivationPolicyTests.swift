//
//  ActivationPolicyTests.swift
//  FamoTests — input-source activation diagnostics
//
//  The enable/select path was reverted to upstream Squirrel's trust-the-TIS-bit logic
//  (see InputSource.swift), so the former FamoActivationPolicy decision-table / didEnableLand /
//  isUserEnabled tests are gone with the code they covered. What remains is the pure, TIS-free
//  half-state DIAGNOSTIC and its guidance text — still worth covering: they run on the
//  selected-source-change observer and from `--detect-activation`, and must never misfire.
//

import Foundation
import XCTest
@testable import Famo

final class ActivationPolicyTests: XCTestCase {

  // MARK: - diagnoseHalfState (selected-but-not-enabled dead half-state detector)

  func testHalfStateDetectedWhenSelectedFamoNotEnabled() {
    let diag = FamoInstaller.diagnoseHalfState(
      currentSourceID: FamoInstaller.InputMode.hans.rawValue,
      trulyEnabledModes: []   // selected Famo, but nothing is enabled → dead half-state
    )
    XCTAssertTrue(diag.brokenHalfState)
    XCTAssertEqual(diag.mode, .hans)
  }

  func testNoHalfStateWhenSelectedFamoIsEnabled() {
    let diag = FamoInstaller.diagnoseHalfState(
      currentSourceID: FamoInstaller.InputMode.hans.rawValue,
      trulyEnabledModes: [.hans]
    )
    XCTAssertFalse(diag.brokenHalfState)
    XCTAssertNil(diag.mode)
  }

  func testNoHalfStateWhenCurrentSourceIsNotFamo() {
    let diag = FamoInstaller.diagnoseHalfState(
      currentSourceID: "com.apple.keylayout.ABC",
      trulyEnabledModes: []
    )
    XCTAssertFalse(diag.brokenHalfState)
    XCTAssertNil(diag.mode)
  }

  func testNoHalfStateWhenNoCurrentSource() {
    let diag = FamoInstaller.diagnoseHalfState(currentSourceID: nil, trulyEnabledModes: [])
    XCTAssertFalse(diag.brokenHalfState)
  }

  // MARK: - guidance text is non-empty & copyable, points at System Settings (not a stale pref read)

  func testGuidanceTextPointsToSystemSettingsAndDoesNotAdviseStalePref() {
    let text = FamoInstaller.activationGuidanceText(for: .hans)
    XCTAssertTrue(text.contains("系统设置"))
    XCTAssertTrue(text.contains("编辑"))
    XCTAssertTrue(text.contains("法墨"))
    // The recovery path must be the System Settings input-source list, NOT a `defaults read` of
    // AppleEnabledInputSources — that plist omits third-party IMEs on macOS 15/26 and misleads.
    XCTAssertFalse(text.contains("defaults read com.apple.HIToolbox AppleEnabledInputSources"))
  }

  func testActivationStatusReportsMissingHostKeyEvents() {
    let text = FamoInstaller.activationStatusText(
      currentInputSourceID: FamoInstaller.InputMode.hans.rawValue,
      lastHostKeyEventDate: nil
    )
    XCTAssertTrue(text.contains(FamoInstaller.InputMode.hans.rawValue))
    XCTAssertTrue(text.contains("尚未观察到宿主按键进入 Famo handle()"))
    XCTAssertTrue(text.contains("系统设置"))
  }

  // MARK: - selectTarget (pure CLI dispatch for `--select-input-source <arg>`; no TIS touched)

  func testSelectTargetMapsFamoModeIDsToFamoModes() {
    XCTAssertEqual(
      FamoInstaller.selectTarget(for: FamoInstaller.InputMode.hans.rawValue),
      .famoMode(.hans)
    )
    XCTAssertEqual(
      FamoInstaller.selectTarget(for: FamoInstaller.InputMode.hant.rawValue),
      .famoMode(.hant)
    )
  }

  func testSelectTargetTreatsSystemSourceIDsAsGenericSelects() {
    // postinstall's update sequence parks the user on ABC before killing the old Famo process
    // (TIS-ACTIVATION-NOTES 定律 12). That id must NEVER fall through to the "select Famo"
    // default path — it would re-select Famo instead of switching out.
    XCTAssertEqual(
      FamoInstaller.selectTarget(for: "com.apple.keylayout.ABC"),
      .systemSource("com.apple.keylayout.ABC")
    )
  }

  // The old Sogou-style `AppleEnabledInputSources` plist fallback is intentionally gone. On this
  // macOS version it created duplicate Famo TIS rows and hid Famo from the input menu.

  // MARK: - 「设为系统默认输入法」的纯决策层（docs/default-input-method-plan.md §4）
  //
  // makeDefault() 本身要碰 TIS（不可 headless 测），但它是薄包装：全部判断都在下面这两个纯函数里
  // —— 做什么（plan）与结果怎么翻译（result）。UI 文案第三个纯函数一并钉住。

  func testMakeDefaultPlanEnablesAndSelectsPrimaryWhenNothingEnabled() {
    // 一个法墨模式都没启用：回落 primary（简体），由 select(mode:) 顺手 enable 再 select。
    let plan = FamoInstaller.makeDefaultPlan(enabledModes: [], currentSourceID: "com.apple.keylayout.ABC")
    XCTAssertEqual(plan, .select(FamoInstaller.InputMode.primary))
  }

  func testMakeDefaultPlanSelectsEnabledModeWhenCurrentSourceIsSomethingElse() {
    // 已启用但当前用着别家输入法：选中即可，无需 enable。
    let plan = FamoInstaller.makeDefaultPlan(enabledModes: [.hans], currentSourceID: "im.rime.inputmethod.Squirrel")
    XCTAssertEqual(plan, .select(.hans))
  }

  func testMakeDefaultPlanReportsAlreadyDefaultWithoutTouchingTIS() {
    // 判定先于动作：已启用且已选中 → 直接判「已是默认」，一个 TIS 调用都不发。
    let plan = FamoInstaller.makeDefaultPlan(
      enabledModes: [.hans, .hant], currentSourceID: FamoInstaller.InputMode.hans.rawValue)
    XCTAssertEqual(plan, .alreadyDefault(.hans))
  }

  func testMakeDefaultPlanPrefersEnabledHantOverPrimary() {
    // 只启用了繁体的用户点「设为默认」必须落在繁体。盲选 primary 会把人切到简体 —— 评审拦下的原提案。
    let plan = FamoInstaller.makeDefaultPlan(enabledModes: [.hant], currentSourceID: "com.apple.keylayout.ABC")
    XCTAssertEqual(plan, .select(.hant))
  }

  func testMakeDefaultPlanIgnoresSelectedFamoModeThatIsNotEnabled() {
    // 吞键死半态（选中但未真正启用）不算「已是默认」：仍要走 select 链路（其中含 enable）修一次。
    let plan = FamoInstaller.makeDefaultPlan(
      enabledModes: [], currentSourceID: FamoInstaller.InputMode.hans.rawValue)
    XCTAssertEqual(plan, .select(.hans))
  }

  func testMakeDefaultResultMapsSelectFailureToFailedWithReason() {
    let result = FamoInstaller.makeDefaultResult(mode: .hans, outcome: .selectFailed(-50))
    guard case .failed(let reason) = result else { return XCTFail("select 失败必须落 .failed") }
    XCTAssertTrue(reason.contains("-50"), "失败文案要带上 TIS 状态码，否则用户无从报障")
  }

  func testMakeDefaultResultTreatsAlreadySelectedAsAlreadyDefaultNotFailure() {
    // 既有 select() 在「已经是当前输入源」时打印的是 "Failed to select"。那不是失败，UI 绝不能这么判。
    XCTAssertEqual(
      FamoInstaller.makeDefaultResult(mode: .hant, outcome: .alreadySelected),
      .alreadyDefault(mode: .hant))
  }

  func testMakeDefaultResultMapsSelectedToMadeDefault() {
    XCTAssertEqual(
      FamoInstaller.makeDefaultResult(mode: .hans, outcome: .selected),
      .madeDefault(mode: .hans))
  }

  func testMakeDefaultResultPointsUnselectableStatesAtSystemSettings() {
    for outcome in [FamoInstaller.SelectOutcome.notEnabled, .notSelectable] {
      guard case .failed(let reason) = FamoInstaller.makeDefaultResult(mode: .hans, outcome: outcome) else {
        return XCTFail("\(outcome) 必须落 .failed")
      }
      XCTAssertTrue(reason.contains("系统设置"), "不可选中的恢复路径只有系统设置的输入法列表")
    }
    guard case .failed(let missing) =
      FamoInstaller.makeDefaultResult(mode: .hans, outcome: .sourceMissing) else {
      return XCTFail("查不到输入源必须落 .failed")
    }
    XCTAssertTrue(missing.contains(FamoInstaller.InputMode.hans.rawValue))
  }

  // MARK: - 诊断页三态文案（+ 未点击时的说明）

  func testMakeDefaultStatusTextCoversThreeResultStatesAndTheUnclickedHint() {
    XCTAssertTrue(FamoDiagnosticsPage.makeDefaultStatusText(nil).contains("下次登录"))
    XCTAssertTrue(
      FamoDiagnosticsPage.makeDefaultStatusText(.alreadyDefault(mode: .hant)).contains("已经是当前系统输入源"))
    XCTAssertTrue(
      FamoDiagnosticsPage.makeDefaultStatusText(.madeDefault(mode: .hans)).contains("已设为默认"))
    let failed = FamoDiagnosticsPage.makeDefaultStatusText(.failed(reason: "系统拒绝切换（TIS 错误 -50）。"))
    XCTAssertTrue(failed.contains("未能设为默认"))
    XCTAssertTrue(failed.contains("-50"), "失败原因必须原样透出，不能被文案吃掉")
  }

  // MARK: - Six-layer read-only TIS diagnosis (W1.4; §6 root-cause matrix 活跃 rows = the cases)

  private static let hans = FamoInstaller.InputMode.hans.rawValue
  private static let hant = FamoInstaller.InputMode.hant.rawValue

  private func famoSource(
    _ id: String, enableCapable: Bool = true, selectCapable: Bool = true,
    enabled: Bool = false, selected: Bool = false
  ) -> TISSourceState {
    TISSourceState(
      id: id, bundleID: FamoInstaller.inputSourcePrefix, localizedName: "法墨输入法",
      enableCapable: enableCapable, selectCapable: selectCapable, enabled: enabled, selected: selected)
  }

  private func classify(_ sources: [TISSourceState], current: String?) -> TISDiagnosis {
    FamoTISDiagnostics.classify(
      sources: sources, currentSourceID: current,
      expectedIDs: [Self.hans, Self.hant], primaryID: Self.hans)
  }

  func testRegisterFailsWhenNoFamoSources() {  // matrix: register 未生效 → FAMO-TIS-001
    let diag = classify([], current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .register)
    XCTAssertEqual(diag.code, "FAMO-TIS-001")
  }

  func testEnableCapabilityFailure() {  // matrix: enable 打错条目/不可启用 → FAMO-TIS-002
    let diag = classify([famoSource(Self.hans, enableCapable: false)], current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .enable)
    XCTAssertEqual(diag.code, "FAMO-TIS-002")
  }

  func testWrongEntryEnabledIsCode002() {  // matrix: enabled id 非 .Hans/.Hant → FAMO-TIS-002
    let stray = FamoInstaller.inputSourcePrefix + ".Stray"
    let diag = classify(
      [famoSource(Self.hans, enabled: false), famoSource(stray, enabled: true)],
      current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .enable)
    XCTAssertEqual(diag.code, "FAMO-TIS-002")
  }

  func testEnableReadbackInconsistency() {  // capable but enabled=false and not current → FAMO-TIS-003
    let diag = classify([famoSource(Self.hans, enabled: false)], current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .enable)
    XCTAssertEqual(diag.code, "FAMO-TIS-003")
  }

  func testSelectedButNotEnabledHalfState() {  // matrix: current=Famo 但 enabled=false → FAMO-TIS-004
    let diag = classify([famoSource(Self.hans, enabled: false, selected: true)], current: Self.hans)
    XCTAssertEqual(diag.firstFailingLayer, .select)
    XCTAssertEqual(diag.code, "FAMO-TIS-004")
    // enable layer defers to select for the half-state instead of double-reporting.
    XCTAssertNil(diag.layers.first { $0.layer == .enable }?.ok)
  }

  func testEnabledNotSelectedIsNotAFailure() {  // enabled + selectable, just not current → healthy
    let diag = classify([famoSource(Self.hans, enabled: true, selected: false)], current: "com.apple.keylayout.ABC")
    XCTAssertNil(diag.code)
    XCTAssertEqual(diag.layers.first { $0.layer == .select }?.ok, true)
  }

  func testHealthyWhenPrimaryEnabledAndSelected() {
    let diag = classify([famoSource(Self.hans, enabled: true, selected: true)], current: Self.hans)
    XCTAssertNil(diag.code)
    XCTAssertNil(diag.firstFailingLayer)
  }

  func testMenuVisibleAndClientAttachAreReadOnlyCeilings() {  // matrix rows 006 / 005: never a headline
    let diag = classify([famoSource(Self.hans, enabled: true, selected: true)], current: Self.hans)
    XCTAssertNil(diag.layers.first { $0.layer == .menuVisible }?.ok)
    XCTAssertNil(diag.layers.first { $0.layer == .clientAttach }?.ok)
    XCTAssertNil(diag.layers.first { $0.layer == .menuVisible }?.code)
    XCTAssertNil(diag.layers.first { $0.layer == .clientAttach }?.code)
  }
}
