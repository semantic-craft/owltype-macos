//
//  InstallerActivationPolicyTests.swift
//  OwltypeTests — GUI 安装器（OwlInstaller.app）激活决策的纯函数层
//
//  被测文件 installer/Sources/InstallerActivationPolicy.swift 直接编进 OwltypeTests target
//  （安装器是独立 xcodegen 工程、无测试 target；纯决策层无 TIS/IO，跨 target 编译零依赖）。
//  风格对标 ActivationPolicyTests：真值表 + 文案断言，TIS 副作用层（Installer/Verifier）
//  不可 headless 测，由干净机真人验收（见 `docs/operations/installation.md`）。
//

import Foundation
import XCTest

final class InstallerActivationPolicyTests: XCTestCase {

  func testParkingUsesUSWhenABCIsNotInstalled() {
    XCTAssertEqual(InstallerActivationPolicy.parkingSourceID(
      preferredID: "com.apple.keylayout.US", selectableASCIIKeyboardIDs: ["com.apple.keylayout.US"]),
      "com.apple.keylayout.US")
  }

  func testParkingHonorsAvailablePreferredKeyboardAndIgnoresStalePreference() {
    XCTAssertEqual(InstallerActivationPolicy.parkingSourceID(
      preferredID: "com.apple.keylayout.British",
      selectableASCIIKeyboardIDs: ["com.apple.keylayout.US", "com.apple.keylayout.British"]),
      "com.apple.keylayout.British")
    XCTAssertEqual(InstallerActivationPolicy.parkingSourceID(
      preferredID: "com.apple.keylayout.ABC", selectableASCIIKeyboardIDs: ["com.apple.keylayout.US"]),
      "com.apple.keylayout.US")
    XCTAssertNil(InstallerActivationPolicy.parkingSourceID(
      preferredID: "com.apple.keylayout.ABC", selectableASCIIKeyboardIDs: []))
  }

  // MARK: - 复合幂等判据真值表（历史观察：绝不信 IsEnabled；已有安装整段跳过 enable）

  func testCleanFirstInstallEnablesParentAndPrimaryModeOnceAndSelects() {
    // 历史观察：干净首装 enable「父条目 + Hans 主模式」各一次（父=菜单显形，Hans=select 需要的
    // 模式启用记录；enable 父条目在 macOS 26 上不级联 default-on 的 Hans——1.3.32 QA 实证）。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    XCTAssertEqual(
      plan,
      InstallerActivationPolicy.ActivationPlan(
        enableParentAndPrimaryModeOnce: true,
        selectOwltypeAfterInstall: true))
  }

  func testPreexistingBundleSkipsEnableAndSelect() {
    // 「bundle 装前已存在」单边即判更新：二次 enable → error 幽灵态（fcitx5 PR#4），必须整段跳过。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertFalse(plan.selectOwltypeAfterInstall, "更新绝不从其它输入法手里抢当前输入源")
  }

  func testRunningProcessSkipsEnableEvenWithoutBundle() {
    // 进程活着 ⟺ 已被 enable 过（IMK 只拉起已启用的输入法）——bundle 信号缺失时的副信号半边。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: true, owltypeWasCurrentSource: false)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertFalse(plan.selectOwltypeAfterInstall)
  }

  func testUpdateWhileOwltypeIsCurrentParksOnABCAndPairsSelectBack() {
    // 更新策略：kill 当前选中的 IME 前切出系统英文键盘；select 只允许作为配对的切回（不重新 enable）。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: true, owltypeWasCurrentSource: true)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertTrue(plan.selectOwltypeAfterInstall)
  }

  func testBothSignalsTrueStillSkipsEnable() {
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: true, owltypeWasCurrentSource: false)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertFalse(plan.selectOwltypeAfterInstall)
  }

  func testStaleCurrentSourceWithoutInstallIsCleanInstallAndStillParks() {
    // (F,F,T) 幽灵残留：TIS 说当前源是法墨，但 bundle/进程都无 → 按干净首装 enable；
    // 策略只看「当前源」信号，替换前照样先切出系统英文键盘，装完配对切回。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: false, owltypeWasCurrentSource: true)
    XCTAssertEqual(
      plan,
      InstallerActivationPolicy.ActivationPlan(
        enableParentAndPrimaryModeOnce: true,
        selectOwltypeAfterInstall: true))
  }

  func testPreexistingBundleCurrentSourceDeadProcessSkipsEnableButParksAndSelectsBack() {
    // (T,F,T) 装过 + 是当前源 + 进程死了（崩溃/被杀）：bundle 单边信号已足以跳过 enable
    // （防二次 enable 幽灵态），切出/切回配对保留。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: false, owltypeWasCurrentSource: true)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertTrue(plan.selectOwltypeAfterInstall)
  }

  func testRunningProcessCurrentSourceWithoutBundleSkipsEnableButParksAndSelectsBack() {
    // (F,T,T) bundle 缺失但进程活着且是当前源：进程信号单边 ⟺ 已被 enable 过，绝不二次 enable。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: true, owltypeWasCurrentSource: true)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertTrue(plan.selectOwltypeAfterInstall)
  }

  func testProbeOutputFormatIsStableMachineReadableLine() {
    XCTAssertEqual(
      InstallerActivationPolicy.probeOutput(
        InstallerActivationPolicy.ProbeSignals(
          parentEnabled: true, primaryModeEnabled: true, primaryModeSelectCapable: true)),
      "parent=1 hans=1 hansSelectCapable=1")
    XCTAssertEqual(
      InstallerActivationPolicy.probeOutput(
        InstallerActivationPolicy.ProbeSignals(
          parentEnabled: false, primaryModeEnabled: false, primaryModeSelectCapable: false)),
      "parent=0 hans=0 hansSelectCapable=0")
  }

  func testProbeOutputRoundTripsThroughParser() {
    for parent in [false, true] {
      for hans in [false, true] {
        for capable in [false, true] {
          let signals = InstallerActivationPolicy.ProbeSignals(
            parentEnabled: parent, primaryModeEnabled: hans, primaryModeSelectCapable: capable)
          XCTAssertEqual(
            InstallerActivationPolicy.parseProbeOutput(
              InstallerActivationPolicy.probeOutput(signals)),
            signals)
        }
      }
    }
  }

  func testProbeParserToleratesNewlineAndExtraTokens() {
    // Process 读回带尾换行是常态；未来加诊断 token 不破坏老解析。
    XCTAssertEqual(
      InstallerActivationPolicy.parseProbeOutput("parent=1 hans=0 hansSelectCapable=1\n"),
      InstallerActivationPolicy.ProbeSignals(
        parentEnabled: true, primaryModeEnabled: false, primaryModeSelectCapable: true))
    XCTAssertEqual(
      InstallerActivationPolicy.parseProbeOutput("noise=abc parent=1 hans=1\n"),
      InstallerActivationPolicy.ProbeSignals(
        parentEnabled: true, primaryModeEnabled: true, primaryModeSelectCapable: false),
      "缺 hansSelectCapable 容忍为 false（诊断位不进 verified 判定）")
  }

  func testProbeParserRejectsMissingKeysOrGarbage() {
    // 坏输出 → nil = 本 tick 无信号，绝不误判成功。
    XCTAssertNil(InstallerActivationPolicy.parseProbeOutput(""))
    XCTAssertNil(InstallerActivationPolicy.parseProbeOutput("parent=1"), "缺 hans 键")
    XCTAssertNil(InstallerActivationPolicy.parseProbeOutput("hans=1"), "缺 parent 键")
    XCTAssertNil(InstallerActivationPolicy.parseProbeOutput("parent=yes hans=1"), "取值非 0/1")
    XCTAssertNil(InstallerActivationPolicy.parseProbeOutput("❌ 探针进程崩了的任意噪声"))
  }

  // MARK: - 文案双态（成功=新开应用立即可用；超时=注销引导，绝不伪装成功）

  func testSuccessfulSelfCheckNeverSuggestsLogoutOrReopeningHost() {
    for first in [false, true] {
      let plan = InstallerActivationPolicy.plan(bundlePreexisted: !first,
        owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
      let text = InstallerActivationPolicy.successText(plan: plan)
      XCTAssertFalse(text.contains("注销"))
      XCTAssertFalse(text.contains("重新打开"))
      XCTAssertTrue(text.contains("自检通过"))
    }
  }

  func testVersionRelationNeverBlocksSameOrOlderVersionReinstall() {
    XCTAssertEqual(
      InstallerActivationPolicy.versionRelation(installedBuild: nil, embeddedBuild: "2.0.19"),
      .notInstalled)
    XCTAssertEqual(
      InstallerActivationPolicy.versionRelation(installedBuild: "2.0.18", embeddedBuild: "2.0.19"),
      .upgrade(installed: "2.0.18", embedded: "2.0.19"))
    XCTAssertEqual(
      InstallerActivationPolicy.versionRelation(installedBuild: "2.0.19", embeddedBuild: "2.0.19"),
      .sameVersion(version: "2.0.19"))
    XCTAssertEqual(
      InstallerActivationPolicy.versionRelation(installedBuild: "2.0.20", embeddedBuild: "2.0.19"),
      .reinstallOlder(installed: "2.0.20", embedded: "2.0.19"))
  }

  func testPreflightReportMapsPrimaryButtonAndAnomalyWarnings() {
    let cleanFirst = InstallerActivationPolicy.PreflightReport(
      installedShortVersion: nil,
      installedBuildVersion: nil,
      embeddedShortVersion: "2.0.19",
      embeddedBuildVersion: "2.0.19",
      strayCopyCount: 0,
      extraLaunchServicesClaimCount: 0)
    XCTAssertFalse(cleanFirst.isInstalled)
    XCTAssertFalse(cleanFirst.hasAnomalies)
    XCTAssertEqual(cleanFirst.primaryButtonTitle, "立即安装")
    XCTAssertNil(cleanFirst.anomalyWarning)

    let upgradeWithStrays = InstallerActivationPolicy.PreflightReport(
      installedShortVersion: "2.0.18",
      installedBuildVersion: "2.0.18",
      embeddedShortVersion: "2.0.19",
      embeddedBuildVersion: "2.0.19",
      strayCopyCount: 1,
      extraLaunchServicesClaimCount: 2)
    XCTAssertTrue(upgradeWithStrays.isInstalled)
    XCTAssertTrue(upgradeWithStrays.hasAnomalies)
    XCTAssertEqual(upgradeWithStrays.primaryButtonTitle, "更新输入法")
    XCTAssertNotNil(upgradeWithStrays.anomalyWarning)
    XCTAssertTrue(upgradeWithStrays.anomalyWarning?.contains("修复安装") == true)
    XCTAssertTrue(upgradeWithStrays.anomalyWarning?.contains("清空修复") == true)

    let reinstallSame = InstallerActivationPolicy.PreflightReport(
      installedShortVersion: "2.0.19",
      installedBuildVersion: "2.0.19",
      embeddedShortVersion: "2.0.19",
      embeddedBuildVersion: "2.0.19",
      strayCopyCount: 0,
      extraLaunchServicesClaimCount: 0)
    XCTAssertEqual(reinstallSame.primaryButtonTitle, "重新安装")
  }

  func testFinishInstallParserDistinguishesReadyAndDeferred() {
    XCTAssertEqual(
      InstallerActivationPolicy.parseFinishInstallStatus("INSTALL_SESSION_OK pid=420 version=2.0.19 status=ready\n"),
      .ready)
    XCTAssertEqual(
      InstallerActivationPolicy.parseFinishInstallStatus("INSTALL_SESSION_OK pid=0 version=2.0.19 status=deferred\n"),
      .deferred)
    XCTAssertNil(InstallerActivationPolicy.parseFinishInstallStatus("INSTALL_SESSION_FAILED: timeout"))
  }

  func testCompletionSummaryCoversAllFourMaintenanceActions() {
    let firstPlan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    let readySummary = InstallerActivationPolicy.completionSummary(
      for: .install(plan: firstPlan, status: .ready))
    XCTAssertEqual(readySummary.title, "安装完成")
    XCTAssertTrue(readySummary.showsActivateButton)
    XCTAssertFalse(readySummary.showsSystemSettingsButton)

    let deferredSummary = InstallerActivationPolicy.completionSummary(
      for: .install(plan: firstPlan, status: .deferred))
    XCTAssertEqual(deferredSummary.title, "安装已完成")
    XCTAssertTrue(deferredSummary.showsActivateButton)
    XCTAssertTrue(deferredSummary.showsSystemSettingsButton)

    let repairSummary = InstallerActivationPolicy.completionSummary(for: .repairInstall(status: .ready))
    XCTAssertEqual(repairSummary.title, "修复安装完成")
    XCTAssertTrue(repairSummary.detail.contains("个人词库"))

    let clearSummary = InstallerActivationPolicy.completionSummary(for: .clearAndRepair)
    XCTAssertEqual(clearSummary.title, "清空修复完成")
    XCTAssertTrue(clearSummary.showsActivateButton)

    let uninstallKeep = InstallerActivationPolicy.completionSummary(for: .uninstall(keepUserData: true))
    XCTAssertEqual(uninstallKeep.title, "卸载完成")
    XCTAssertFalse(uninstallKeep.showsActivateButton)
    XCTAssertTrue(uninstallKeep.detail.contains("已保留"))

    let uninstallPurge = InstallerActivationPolicy.completionSummary(for: .uninstall(keepUserData: false))
    XCTAssertTrue(uninstallPurge.detail.contains("清空个人词库"))
  }
}
