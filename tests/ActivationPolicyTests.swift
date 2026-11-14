//
//  ActivationPolicyTests.swift
//  OwltypeTests — input-source activation diagnostics
//
//  The enable/select path was reverted to upstream Squirrel's trust-the-TIS-bit logic
//  (see InputSource.swift), so the former OwlActivationPolicy decision-table / didEnableLand /
//  isUserEnabled tests are gone with the code they covered. What remains is the pure, TIS-free
//  half-state DIAGNOSTIC and its guidance text — still worth covering: they run on the
//  selected-source-change observer and from `--detect-activation`, and must never misfire.
//

import AppKit
import Foundation
import XCTest
@testable import Owltype

final class ActivationPolicyTests: XCTestCase {

  // MARK: - diagnoseHalfState (selected-but-not-enabled dead half-state detector)

  func testHalfStateDetectedWhenSelectedOwltypeNotEnabled() {
    let diag = OwlInstaller.diagnoseHalfState(
      currentSourceID: OwlInstaller.InputMode.hans.rawValue,
      trulyEnabledModes: []   // selected Owltype, but nothing is enabled → dead half-state
    )
    XCTAssertTrue(diag.brokenHalfState)
    XCTAssertEqual(diag.mode, .hans)
  }

  func testNoHalfStateWhenSelectedOwltypeIsEnabled() {
    let diag = OwlInstaller.diagnoseHalfState(
      currentSourceID: OwlInstaller.InputMode.hans.rawValue,
      trulyEnabledModes: [.hans]
    )
    XCTAssertFalse(diag.brokenHalfState)
    XCTAssertNil(diag.mode)
  }

  func testNoHalfStateWhenCurrentSourceIsNotOwltype() {
    let diag = OwlInstaller.diagnoseHalfState(
      currentSourceID: "com.apple.keylayout.ABC",
      trulyEnabledModes: []
    )
    XCTAssertFalse(diag.brokenHalfState)
    XCTAssertNil(diag.mode)
  }

  func testNoHalfStateWhenNoCurrentSource() {
    let diag = OwlInstaller.diagnoseHalfState(currentSourceID: nil, trulyEnabledModes: [])
    XCTAssertFalse(diag.brokenHalfState)
  }

  // MARK: - guidance text is non-empty & copyable, points at System Settings (not a stale pref read)

  func testGuidanceTextPointsToSystemSettingsAndDoesNotAdviseStalePref() {
    let text = OwlInstaller.activationGuidanceText(for: .hans)
    XCTAssertTrue(text.contains("系统设置"))
    XCTAssertTrue(text.contains("编辑"))
    XCTAssertTrue(text.contains("法墨"))
    // The recovery path must be the System Settings input-source list, NOT a `defaults read` of
    // AppleEnabledInputSources — that plist omits third-party IMEs on macOS 15/26 and misleads.
    XCTAssertFalse(text.contains("defaults read com.apple.HIToolbox AppleEnabledInputSources"))
  }

  func testActivationStatusReportsMissingHostKeyEvents() {
    let text = OwlInstaller.activationStatusText(
      currentInputSourceID: OwlInstaller.InputMode.hans.rawValue,
      lastHostKeyEventDate: nil
    )
    XCTAssertTrue(text.contains(OwlInstaller.InputMode.hans.rawValue))
    XCTAssertTrue(text.contains("尚未观察到宿主按键进入 Owltype handle()"))
    XCTAssertTrue(text.contains("系统设置"))
  }

  // MARK: - selectTarget (pure CLI dispatch for `--select-input-source <arg>`; no TIS touched)

  func testSelectTargetMapsOwltypeModeIDsToOwltypeModes() {
    XCTAssertEqual(
      OwlInstaller.selectTarget(for: OwlInstaller.InputMode.hans.rawValue),
      .owlMode(.hans)
    )
    XCTAssertEqual(
      OwlInstaller.selectTarget(for: OwlInstaller.InputMode.hant.rawValue),
      .owlMode(.hant)
    )
  }

  func testSelectTargetTreatsSystemSourceIDsAsGenericSelects() {
    // postinstall's update sequence parks the user on ABC before killing the old Owltype process
    // (TIS-ACTIVATION-NOTES 定律 12). That id must NEVER fall through to the "select Owltype"
    // default path — it would re-select Owltype instead of switching out.
    XCTAssertEqual(
      OwlInstaller.selectTarget(for: "com.apple.keylayout.ABC"),
      .systemSource("com.apple.keylayout.ABC")
    )
  }

  // The old Sogou-style `AppleEnabledInputSources` plist fallback is intentionally gone. On this
  // macOS version it created duplicate Owltype TIS rows and hid Owltype from the input menu.

  // MARK: - 「设为系统默认输入法」的纯决策层
  //
  // makeDefault() 本身要碰 TIS（不可 headless 测），但它是薄包装：全部判断都在下面这两个纯函数里
  // —— 做什么（plan）与结果怎么翻译（result）。UI 文案第三个纯函数一并钉住。

  func testMakeDefaultPlanEnablesAndSelectsPrimaryWhenNothingEnabled() {
    // 一个法墨模式都没启用：回落 primary（简体），由 select(mode:) 顺手 enable 再 select。
    let plan = OwlInstaller.makeDefaultPlan(enabledModes: [], currentSourceID: "com.apple.keylayout.ABC")
    XCTAssertEqual(plan, .select(OwlInstaller.InputMode.primary))
  }

  func testMakeDefaultPlanSelectsEnabledModeWhenCurrentSourceIsSomethingElse() {
    // 已启用但当前用着别家输入法：选中即可，无需 enable。
    let plan = OwlInstaller.makeDefaultPlan(enabledModes: [.hans], currentSourceID: "im.rime.inputmethod.Squirrel")
    XCTAssertEqual(plan, .select(.hans))
  }

  func testMakeDefaultPlanReportsAlreadyDefaultWithoutTouchingTIS() {
    // 判定先于动作：已启用且已选中 → 直接判「已是默认」，一个 TIS 调用都不发。
    let plan = OwlInstaller.makeDefaultPlan(
      enabledModes: [.hans, .hant], currentSourceID: OwlInstaller.InputMode.hans.rawValue)
    XCTAssertEqual(plan, .alreadyDefault(.hans))
  }

  func testMakeDefaultPlanPrefersEnabledHantOverPrimary() {
    // 只启用了繁体的用户点「设为默认」必须落在繁体。盲选 primary 会把人切到简体 —— 评审拦下的原提案。
    let plan = OwlInstaller.makeDefaultPlan(enabledModes: [.hant], currentSourceID: "com.apple.keylayout.ABC")
    XCTAssertEqual(plan, .select(.hant))
  }

  func testMakeDefaultPlanIgnoresSelectedOwltypeModeThatIsNotEnabled() {
    // 吞键死半态（选中但未真正启用）不算「已是默认」：仍要走 select 链路（其中含 enable）修一次。
    let plan = OwlInstaller.makeDefaultPlan(
      enabledModes: [], currentSourceID: OwlInstaller.InputMode.hans.rawValue)
    XCTAssertEqual(plan, .select(.hans))
  }

  func testMakeDefaultResultMapsParamErrToManualReAddGuidance() {
    let result = OwlInstaller.makeDefaultResult(mode: .hans, outcome: .selectFailed(-50))
    guard case .failed(let reason) = result else { return XCTFail("select 失败必须落 .failed") }
    XCTAssertTrue(reason.contains("-50"), "失败文案要带上 TIS 状态码，否则用户无从报障")
    XCTAssertTrue(reason.contains("系统设置"), "用户从输入法列表移除法墨后，恢复路径只能回到系统设置")
    XCTAssertTrue(reason.contains("重新加入"), "-50 必须明确告诉用户重新加入法墨，不能只报泛化系统拒绝")
  }

  func testMakeDefaultResultKeepsGenericGuidanceForOtherSelectFailures() {
    let result = OwlInstaller.makeDefaultResult(mode: .hans, outcome: .selectFailed(-43))
    guard case .failed(let reason) = result else { return XCTFail("select 失败必须落 .failed") }
    XCTAssertTrue(reason.contains("-43"))
    XCTAssertFalse(reason.contains("重新加入"), "只有已实证的 paramErr 才能给出重新加入的定向恢复路径")
  }

  func testMakeDefaultResultTreatsAlreadySelectedAsAlreadyDefaultNotFailure() {
    // 既有 select() 在「已经是当前输入源」时打印的是 "Failed to select"。那不是失败，UI 绝不能这么判。
    XCTAssertEqual(
      OwlInstaller.makeDefaultResult(mode: .hant, outcome: .alreadySelected),
      .alreadyDefault(mode: .hant))
  }

  func testMakeDefaultResultMapsSelectedToMadeDefault() {
    XCTAssertEqual(
      OwlInstaller.makeDefaultResult(mode: .hans, outcome: .selected),
      .madeDefault(mode: .hans))
  }

  func testMakeDefaultResultPointsUnselectableStatesAtSystemSettings() {
    for outcome in [OwlInstaller.SelectOutcome.notEnabled, .notSelectable] {
      guard case .failed(let reason) = OwlInstaller.makeDefaultResult(mode: .hans, outcome: outcome) else {
        return XCTFail("\(outcome) 必须落 .failed")
      }
      XCTAssertTrue(reason.contains("系统设置"), "不可选中的恢复路径只有系统设置的输入法列表")
    }
    guard case .failed(let missing) =
      OwlInstaller.makeDefaultResult(mode: .hans, outcome: .sourceMissing) else {
      return XCTFail("查不到输入源必须落 .failed")
    }
    XCTAssertTrue(missing.contains(OwlInstaller.InputMode.hans.rawValue))
  }

  // MARK: - 诊断页三态文案（+ 未点击时的说明）

  func testMakeDefaultStatusTextCoversThreeResultStatesAndTheUnclickedHint() {
    XCTAssertTrue(OwlDiagnosticsPage.makeDefaultStatusText(nil).contains("下次登录"))
    XCTAssertTrue(
      OwlDiagnosticsPage.makeDefaultStatusText(.alreadyDefault(mode: .hant)).contains("已经是当前系统输入源"))
    XCTAssertTrue(
      OwlDiagnosticsPage.makeDefaultStatusText(.madeDefault(mode: .hans)).contains("已设为默认"))
    let failed = OwlDiagnosticsPage.makeDefaultStatusText(.failed(reason: "系统拒绝切换（TIS 错误 -50）。"))
    XCTAssertTrue(failed.contains("未能设为默认"))
    XCTAssertTrue(failed.contains("-50"), "失败原因必须原样透出，不能被文案吃掉")
  }

  // MARK: - Six-layer read-only TIS diagnosis (W1.4; §6 root-cause matrix 活跃 rows = the cases)

  private static let hans = OwlInstaller.InputMode.hans.rawValue
  private static let hant = OwlInstaller.InputMode.hant.rawValue

  private func owlSource(
    _ id: String, enableCapable: Bool = true, selectCapable: Bool = true,
    enabled: Bool = false, selected: Bool = false
  ) -> TISSourceState {
    TISSourceState(
      id: id, bundleID: OwlInstaller.inputSourcePrefix, localizedName: "法墨输入法",
      enableCapable: enableCapable, selectCapable: selectCapable, enabled: enabled, selected: selected)
  }

  private func classify(_ sources: [TISSourceState], current: String?) -> TISDiagnosis {
    OwlTISDiagnostics.classify(
      sources: sources, currentSourceID: current,
      expectedIDs: [Self.hans, Self.hant], primaryID: Self.hans)
  }

  func testRegisterFailsWhenNoOwltypeSources() {  // matrix: register 未生效 → OWL-TIS-001
    let diag = classify([], current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .register)
    XCTAssertEqual(diag.code, "OWL-TIS-001")
  }

  func testEnableCapabilityFailure() {  // matrix: enable 打错条目/不可启用 → OWL-TIS-002
    let diag = classify([owlSource(Self.hans, enableCapable: false)], current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .enable)
    XCTAssertEqual(diag.code, "OWL-TIS-002")
  }

  func testWrongEntryEnabledIsCode002() {  // matrix: enabled id 非 .Hans/.Hant → OWL-TIS-002
    let stray = OwlInstaller.inputSourcePrefix + ".Stray"
    let diag = classify(
      [owlSource(Self.hans, enabled: false), owlSource(stray, enabled: true)],
      current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .enable)
    XCTAssertEqual(diag.code, "OWL-TIS-002")
  }

  func testEnableReadbackInconsistency() {  // capable but enabled=false and not current → OWL-TIS-003
    let diag = classify([owlSource(Self.hans, enabled: false)], current: "com.apple.keylayout.ABC")
    XCTAssertEqual(diag.firstFailingLayer, .enable)
    XCTAssertEqual(diag.code, "OWL-TIS-003")
  }

  func testSelectedButNotEnabledHalfState() {  // matrix: current=Owltype 但 enabled=false → OWL-TIS-004
    let diag = classify([owlSource(Self.hans, enabled: false, selected: true)], current: Self.hans)
    XCTAssertEqual(diag.firstFailingLayer, .select)
    XCTAssertEqual(diag.code, "OWL-TIS-004")
    // enable layer defers to select for the half-state instead of double-reporting.
    XCTAssertNil(diag.layers.first { $0.layer == .enable }?.ok)
  }

  func testEnabledNotSelectedIsNotAFailure() {  // enabled + selectable, just not current → healthy
    let diag = classify([owlSource(Self.hans, enabled: true, selected: false)], current: "com.apple.keylayout.ABC")
    XCTAssertNil(diag.code)
    XCTAssertEqual(diag.layers.first { $0.layer == .select }?.ok, true)
  }

  func testHealthyWhenPrimaryEnabledAndSelected() {
    let diag = classify([owlSource(Self.hans, enabled: true, selected: true)], current: Self.hans)
    XCTAssertNil(diag.code)
    XCTAssertNil(diag.firstFailingLayer)
  }

  func testMenuVisibleAndClientAttachAreReadOnlyCeilings() {  // matrix rows 006 / 005: never a headline
    let diag = classify([owlSource(Self.hans, enabled: true, selected: true)], current: Self.hans)
    XCTAssertNil(diag.layers.first { $0.layer == .menuVisible }?.ok)
    XCTAssertNil(diag.layers.first { $0.layer == .clientAttach }?.ok)
    XCTAssertNil(diag.layers.first { $0.layer == .menuVisible }?.code)
    XCTAssertNil(diag.layers.first { $0.layer == .clientAttach }?.code)
  }

  // MARK: - LaunchServices bundle-id claims

  // Fixture paths deliberately sit outside any home directory: check-public-privacy.sh blocks
  // home-directory paths anywhere in tracked files, so a realistic one fails the gate.
  private func claims(_ pairs: [(String, String?)]) -> LSClaimReport {
    OwlTISDiagnostics.classifyClaims(
      bundleID: OwlInstaller.inputSourcePrefix,
      claims: pairs.map { LSBundleClaim(path: $0.0, teamID: $0.1) })
  }

  func testSingleSignedClaimIsHealthy() {  // the shape after scripts/clean-dev.sh --apply
    let report = claims([("/Library/Input Methods/Owltype.app", "LQAVR62TK2")])
    XCTAssertNil(report.code)
    XCTAssertEqual(report.claimCount, 1)
    XCTAssertEqual(report.unsignedCount, 0)
  }

  func testMultipleSignedClaimsWarn() {  // a second signed copy still shadows the installed one
    let report = claims([
      ("/Library/Input Methods/Owltype.app", "LQAVR62TK2"),
      ("/Volumes/Work/owltype-macos/build/Release/Owltype.app", "LQAVR62TK2"),
    ])
    XCTAssertEqual(report.code, "OWL-LS-001")
    XCTAssertEqual(report.claimCount, 2)
    XCTAssertEqual(report.unsignedCount, 0)
  }

  func testUnsignedClaimTakesTheHeadline() {  // 结论 A: the ad-hoc build is what breaks login restore
    let report = claims([
      ("/Library/Input Methods/Owltype.app", "LQAVR62TK2"),
      ("/Volumes/Work/owltype-macos/build/Debug/Owltype.app", nil),
    ])
    XCTAssertEqual(report.code, "OWL-LS-002")
    XCTAssertEqual(report.unsignedCount, 1)
  }

  func testEmptyTeamIDCountsAsUnsigned() {  // ad-hoc signatures report "" rather than omitting it
    XCTAssertEqual(claims([("/Volumes/Work/build/Owltype.app", "")]).code, "OWL-LS-002")
  }

  func testLoneUnsignedClaimStillWarns() {  // a dev build alone claiming the id is not healthy
    let report = claims([("/Volumes/Work/owltype-macos/build/Debug/Owltype.app", nil)])
    XCTAssertEqual(report.code, "OWL-LS-002")
    XCTAssertEqual(report.claimCount, 1)
  }

  func testNoClaimsIsNotALaunchServicesCode() {  // not installed → register layer / OWL-INSTALL-001
    let report = claims([])
    XCTAssertNil(report.code)
    XCTAssertEqual(report.claimCount, 0)
  }

  func testClaimsAreSortedByPath() {  // stable JSON across runs; LaunchServices order is arbitrary
    let report = claims([("/b/Owltype.app", "LQAVR62TK2"), ("/a/Owltype.app", "LQAVR62TK2")])
    XCTAssertEqual(report.claims.map { $0.path }, ["/a/Owltype.app", "/b/Owltype.app"])
  }

  func testLaunchServicesCodesCarryUserMessageAndAction() {
    for code in ["OWL-LS-001", "OWL-LS-002"] {
      XCTAssertNotNil(OwlTISDiagnostics.userMessage[code])
      XCTAssertTrue(OwlTISDiagnostics.actionText(for: code).contains("clean-dev.sh --apply"))
    }
  }

  // MARK: - IMK endpoint ownership (2026-09-27: a build-dir copy squatted Owltype_Connection)

  func testOnlyBundlesDirectlyInInputMethodsFoldersMayServeIMK() throws {
    let home = FileManager.default.temporaryDirectory
      .appending(component: "owl-imk-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
    let library = home.appending(component: "Library", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let installed: [URL] = [
      URL(fileURLWithPath: "/Library/Input Methods/Owltype.app", isDirectory: true),
      library.appending(components: "Input Methods", "Owltype.app", directoryHint: .isDirectory)
    ]
    for url in installed {
      XCTAssertTrue(OwlApp.isInstalledInputMethodBundle(url, libraryDir: library), url.path)
    }
    let squatters: [URL] = [
      URL(fileURLWithPath: "/opt/src/owltype-macos/build/Build/Products/Debug/Owltype.app", isDirectory: true),
      URL(fileURLWithPath: "/Library/Input Methods/.disabled-backup/Owltype.app", isDirectory: true),
      URL(fileURLWithPath: "/tmp/Input Methods/Owltype.app", isDirectory: true)
    ]
    for url in squatters {
      XCTAssertFalse(OwlApp.isInstalledInputMethodBundle(url, libraryDir: library), url.path)
    }

    // A symlink placed in Input Methods that points at a build product is still the build product.
    let inputMethods = library.appending(component: "Input Methods", directoryHint: .isDirectory)
    let products = home.appending(components: "build", "Owltype.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inputMethods, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let link = inputMethods.appending(component: "Owltype.app", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: products)
    XCTAssertFalse(OwlApp.isInstalledInputMethodBundle(link, libraryDir: library))
  }

  // MARK: - Bundled menu bar icon PDF renders in CoreGraphics/AppKit

  func testBundledMenuIconPDFRendersNonEmptyTemplateInAppKit() throws {
    let bundle = Bundle(for: OwlApplicationDelegate.self)
    let iconURL = try XCTUnwrap(bundle.url(forResource: "OwlMenuIcon", withExtension: "pdf"))
    let pdfData = try Data(contentsOf: iconURL)
    XCTAssertNil(
      pdfData.range(of: Data("/SMask".utf8)),
      "OwlMenuIcon.pdf must be pure vector without Cairo /SMask bitmaps that CoreGraphics renders blank"
    )

    let image = try XCTUnwrap(NSImage(contentsOf: iconURL))
    XCTAssertEqual(image.size, NSSize(width: 16, height: 16))

    let width = 32
    let height = 32
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()

    var opaquePixels = 0
    for y in 0..<height {
      for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        opaquePixels += 1
      }
    }
    XCTAssertGreaterThan(opaquePixels, 300, "OwlMenuIcon.pdf rendered blank in AppKit")
    XCTAssertGreaterThan(rep.colorAt(x: 19, y: 10)?.alphaComponent ?? 0, 0.9)
    XCTAssertGreaterThan(rep.colorAt(x: 16, y: 20)?.alphaComponent ?? 0, 0.9)
    XCTAssertLessThan(rep.colorAt(x: 4, y: 4)?.alphaComponent ?? 1, 0.05)
    XCTAssertLessThan(rep.colorAt(x: 28, y: 24)?.alphaComponent ?? 1, 0.05)
  }
}
