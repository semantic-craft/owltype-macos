//
//  InstallerActivationPolicyTests.swift
//  OwltypeTests — GUI 安装器（OwlInstaller.app）激活决策的纯函数层
//
//  被测文件 installer/Sources/InstallerActivationPolicy.swift 直接编进 OwltypeTests target
//  （安装器是独立 xcodegen 工程、无测试 target；纯决策层无 TIS/IO，跨 target 编译零依赖）。
//  风格对标 ActivationPolicyTests：真值表 + 文案断言，TIS 副作用层（Installer/Verifier）
//  不可 headless 测，由干净机真人验收（TIS-ACTIVATION-NOTES 定律 3/10）。
//

import Foundation
import XCTest

final class InstallerActivationPolicyTests: XCTestCase {

  // MARK: - 复合幂等判据真值表（定律 4/11：绝不信 IsEnabled；已有安装整段跳过 enable）

  func testCleanFirstInstallEnablesParentAndPrimaryModeOnceAndSelects() {
    // 定律 13：干净首装 enable「父条目 + Hans 主模式」各一次（父=菜单显形，Hans=select 需要的
    // 模式启用记录；enable 父条目在 macOS 26 上不级联 default-on 的 Hans——1.3.32 QA 实证）。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    XCTAssertEqual(
      plan,
      InstallerActivationPolicy.ActivationPlan(
        enableParentAndPrimaryModeOnce: true, parkOnABCBeforeReplace: false,
        selectOwltypeAfterInstall: true))
  }

  func testPreexistingBundleSkipsEnableAndSelect() {
    // 「bundle 装前已存在」单边即判更新：二次 enable → error 幽灵态（fcitx5 PR#4），必须整段跳过。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertFalse(plan.parkOnABCBeforeReplace)
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
    // 定律 12：kill 当前选中的 IME 前切出 ABC；select 只允许作为配对的切回（不重新 enable）。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: true, owltypeWasCurrentSource: true)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertTrue(plan.parkOnABCBeforeReplace)
    XCTAssertTrue(plan.selectOwltypeAfterInstall)
  }

  func testBothSignalsTrueStillSkipsEnable() {
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: true, owltypeWasCurrentSource: false)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertFalse(plan.selectOwltypeAfterInstall)
  }

  func testStaleCurrentSourceWithoutInstallIsCleanInstallAndStillParks() {
    // (F,F,T) 幽灵残留：TIS 说当前源是猫头鹰，但 bundle/进程都无 → 按干净首装 enable；
    // 定律 12 只看「当前源」信号，替换前照样先切出 ABC，装完配对切回。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: false, owltypeWasCurrentSource: true)
    XCTAssertEqual(
      plan,
      InstallerActivationPolicy.ActivationPlan(
        enableParentAndPrimaryModeOnce: true, parkOnABCBeforeReplace: true,
        selectOwltypeAfterInstall: true))
  }

  func testPreexistingBundleCurrentSourceDeadProcessSkipsEnableButParksAndSelectsBack() {
    // (T,F,T) 装过 + 是当前源 + 进程死了（崩溃/被杀）：bundle 单边信号已足以跳过 enable
    // （防二次 enable 幽灵态），切出/切回配对保留。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: false, owltypeWasCurrentSource: true)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertTrue(plan.parkOnABCBeforeReplace)
    XCTAssertTrue(plan.selectOwltypeAfterInstall)
  }

  func testRunningProcessCurrentSourceWithoutBundleSkipsEnableButParksAndSelectsBack() {
    // (F,T,T) bundle 缺失但进程活着且是当前源：进程信号单边 ⟺ 已被 enable 过，绝不二次 enable。
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: true, owltypeWasCurrentSource: true)
    XCTAssertFalse(plan.enableParentAndPrimaryModeOnce)
    XCTAssertTrue(plan.parkOnABCBeforeReplace)
    XCTAssertTrue(plan.selectOwltypeAfterInstall)
  }

  // MARK: - consent 等待 + 读回验证状态机（fix2：needsLogout 非吸收态 + 迟到自愈）
  //
  // 信号 =「父 enabled ∧ Hans 在 enabled-only 列表」，由 `--tis-probe` fresh 进程探针读回
  // （安装器老进程 TIS 快照陈旧，进程内读回已退役；select 随之退役出输入信号——改在 verified
  // 时刻由 fresh 进程 Owltype CLI 执行）。软超时 → needsLogout(stillTrying: true) 显示引导但继续等；
  // 扩展截止 → needsLogout(stillTrying: false) 终态；信号任何时刻到都翻 verified（迟到自愈）。

  func testVerificationKeepsWaitingWithoutSignalBeforeDeadline() {
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: false,
        deadlineReached: false, extendedDeadlineReached: false),
      .waiting)
  }

  func testParentEnabledAloneIsGhostComboAndKeepsWaiting() {
    // 1.3.32 真机幽灵组合：父条目 enabled（菜单显形）但 Hans 无启用记录（点不中）——
    // 不能被判 verified，软超时前继续等（Hans 可能随 consent 稍后跟上）。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: false,
        deadlineReached: false, extendedDeadlineReached: false),
      .waiting)
  }

  func testPrimaryModeAloneWithoutParentKeepsWaiting() {
    // Hans 在 enabled-only 而父不在：不完整（菜单显形靠父条目），保守继续等。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: true,
        deadlineReached: false, extendedDeadlineReached: false),
      .waiting)
  }

  func testFullSignalVerifiesBeforeDeadline() {
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: true,
        deadlineReached: false, extendedDeadlineReached: false),
      .verified)
  }

  func testSoftDeadlineWithoutSignalShowsLogoutGuidanceButKeepsTrying() {
    // 软超时 → 橙窗注销引导，但非吸收态：verifier 后台继续 tick（fix1 QA 的假阴性一半 =
    // 人点「允许」晚于 30s，旧版 needsLogout 一落就终态、迟到 consent 无人接）。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: false,
        deadlineReached: true, extendedDeadlineReached: false),
      .needsLogout(stillTrying: true))
  }

  func testGhostComboAtSoftDeadlineShowsLogoutGuidanceButKeepsTrying() {
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: false,
        deadlineReached: true, extendedDeadlineReached: false),
      .needsLogout(stillTrying: true))
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: true,
        deadlineReached: true, extendedDeadlineReached: false),
      .needsLogout(stillTrying: true))
  }

  func testLateSignalAfterSoftDeadlineVerifies() {
    // 迟到自愈核心行：软超时已过（橙窗已显示），consent 信号才到 → 照样翻 verified 绿窗。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: true,
        deadlineReached: true, extendedDeadlineReached: false),
      .verified)
  }

  func testLateSignalOnExtendedDeadlineTickStillVerifies() {
    // 恰在扩展截止那一 tick 凑齐信号：信号优先，不吞成终态注销。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: true,
        deadlineReached: true, extendedDeadlineReached: true),
      .verified)
  }

  func testExtendedDeadlineWithoutSignalIsTerminalNeedsLogout() {
    // 扩展截止仍无信号 → 终态注销引导（stillTrying=false，verifier 停止 tick）。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: false,
        deadlineReached: true, extendedDeadlineReached: true),
      .needsLogout(stillTrying: false))
  }

  func testGhostComboAtExtendedDeadlineIsTerminalNeedsLogout() {
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: false,
        deadlineReached: true, extendedDeadlineReached: true),
      .needsLogout(stillTrying: false))
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: true,
        deadlineReached: true, extendedDeadlineReached: true),
      .needsLogout(stillTrying: false))
  }

  func testExtendedDeadlineDominatesEvenWithoutSoftFlag() {
    // (deadline=false, extended=true) 是不可能输入（扩展截止 > 软超时），纯函数仍取保守终态；
    // 信号在场照样 verified（补齐 16 行真值表的最后 4 行）。
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: false,
        deadlineReached: false, extendedDeadlineReached: true),
      .needsLogout(stillTrying: false))
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: false,
        deadlineReached: false, extendedDeadlineReached: true),
      .needsLogout(stillTrying: false))
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: false, primaryModeEnabledObserved: true,
        deadlineReached: false, extendedDeadlineReached: true),
      .needsLogout(stillTrying: false))
    XCTAssertEqual(
      InstallerActivationPolicy.verificationState(
        parentEnabledObserved: true, primaryModeEnabledObserved: true,
        deadlineReached: false, extendedDeadlineReached: true),
      .verified)
  }

  // MARK: - --tis-probe 探针输出协议（喂字符串，不跑进程）

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

  func testSuccessTextLeadsWithNewlyOpenedAppsAndDropsNoLogoutClaim() {
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: false, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    let text = InstallerActivationPolicy.successText(plan: plan)
    // QA 三轮拍板（07-02）：领句只承诺「新打开的应用立即可用」，预期与体验对齐。
    XCTAssertTrue(text.contains("新打开的应用"))
    XCTAssertFalse(text.contains("无需注销"), "「无需注销」绝对承诺已移除（07-02 用户拍板）")
    // squirrel#68 边界的诚实话术：装前已开的个别应用打不出，重开该应用即可。
    XCTAssertTrue(text.contains("重新打开该应用"))
    // 诚实兜底：重开仍打不出 → 注销一次。
    XCTAssertTrue(text.contains("注销一次"))
  }

  func testUpdateSuccessTextDoesNotAskUserToPickOwltype() {
    let plan = InstallerActivationPolicy.plan(
      bundlePreexisted: true, owltypeProcessWasRunning: false, owltypeWasCurrentSource: false)
    let text = InstallerActivationPolicy.successText(plan: plan)
    XCTAssertTrue(text.contains("更新"))
    XCTAssertFalse(text.contains("选择「猫头鹰」"), "更新不改用户的输入法选择，不该引导去选")
  }

  func testNeedsLogoutTextGuidesLogoutAndNeverClaimsSuccess() {
    for stillTrying in [false, true] {
      let text = InstallerActivationPolicy.needsLogoutText(stillTrying: stillTrying)
      XCTAssertTrue(text.contains("注销"))
      XCTAssertTrue(text.contains("系统设置"))
      XCTAssertFalse(text.contains("✅"), "验证失败不伪装成功（R1）")
    }
    // fix2 迟到自愈：橙窗非终态，明示「刚点了允许会自动更新」，避免用户误判没装成后乱抢修。
    XCTAssertTrue(
      InstallerActivationPolicy.needsLogoutText(stillTrying: true).contains("自动更新"))
    // 扩展截止终态 verifier 已停：再承诺「会自动更新」就是假话（R1 诚实兜底）。
    XCTAssertFalse(
      InstallerActivationPolicy.needsLogoutText(stillTrying: false).contains("自动更新"))
  }
}
