import AppKit
import Carbon
import CoreGraphics
import os

/// 更新完成后强推注销提示。#16 新方向：`免注销自动保持选中态`（preinstall 记录 + postinstall
/// 还原）在真机不可靠（1.4.6 更新后法墨掉到 com.apple.keylayout.US 复现），改为诚实强推注销——
/// 更新后弹一次「建议注销」对话框，`立即注销` 为默认动作、`稍后自己注销` 可选。
/// 首启（首装）不弹：首装走 Famo.pkg 的 `RequireLogout` 强制注销。
///
/// 2026-08 起选中态还原由本文件的 app 侧事件驱动还原器接管（`FamoUpdateSelectionRestorer`：
/// 1.4.6 失败的根因已定位为 PackageKit 最终注册晚于 postinstall 退出——postinstall 0e 写交接
/// 标记，第 4 步 `open -g` 拉起的新 app 天然活过注册边界，监听踢回事件按预算重选；接替曾经的
/// shell 轮询延迟任务 `schedule_deferred_update_restore`）。本提示不因此退役：已开启的旧 App
/// 不重开挂不上新 IMKServer（squirrel#68 系统天花板），注销仍是一次性恢复所有 App 的诚实收尾；
/// 两者各管一段，互不替代。
///
/// 本文件承载更新收尾线七个类型（同一功能面、同居一处，避免新增源文件带来的 pbxproj 手术）：
///   - `FamoUpdateLogoutPrompt`      判定 + A1「处置后才记录」+ C1 文案 + 呈现（#109）
///   - `FamoLogoutPromptTiming`      B2 门控的纯判定层 + 反「永久静默」阀（#131，XCTest 可锁）
///   - `FamoUpdateLogoutScheduler`   B2 安全时机门控 + 激活确认 + 焦点还原（#109/#131）
///   - `FamoLogoutAction`            可复用的正式注销动作 + -1743 分流恢复 UI（#111，更新提示与菜单共用）
///   - `FamoLogoutDiagnostics`       覆盖式失败遥测 + 诊断包章节（#111）
///   - `FamoUpdateSelectionRestorePolicy`  更新后选中态还原的纯判定层（XCTest 可锁）
///   - `FamoUpdateSelectionRestorer`       更新后选中态还原的事件驱动层（标记消费 + 踢回重选）
enum FamoUpdateLogoutPrompt {
  static let lastRunVersionKey = "FamoLastRunVersion"

  /// 用户对建议注销对话框的处置。
  enum Choice {
    case logoutNow
    case later
  }

  /// 是否因版本变化而建议注销（纯函数）。
  /// - `lastRun` 为 nil/空（首启/首装）→ false（由 pkg RequireLogout 承载注销）。
  /// - `current` 空 → false（拿不到版本，不判定）。
  /// - `lastRun != current`（刚更新）→ true。
  static func shouldSuggest(lastRun: String?, current: String) -> Bool {
    guard let lastRun, !lastRun.isEmpty, !current.isEmpty else { return false }
    return lastRun != current
  }

  /// A1：判定本次启动的处置，返回是否需要（在安全时机）弹窗。
  /// 副作用仅「首装/同版本播种」——把 `current` 写进 defaults（首装立即播种，保留首装语义，避免下次
  /// 升级被误判成首装而永不弹）。**更新路径【不在此处记录】**：记录推迟到 `recordDisposition`
  /// （即 `runModal` 返回、执行动作之前），使 alert 未处置就被进程杀掉时下次启动会重弹（窄异常路径，
  /// 用有限重弹换永久静音）。可注入 `defaults`，不碰 UI，可单测。
  @discardableResult
  static func planPrompt(current: String, defaults: UserDefaults) -> Bool {
    let last = defaults.string(forKey: lastRunVersionKey)
    if shouldSuggest(lastRun: last, current: current) {
      return true // 更新：待弹，先不记录
    }
    if !current.isEmpty {
      defaults.set(current, forKey: lastRunVersionKey) // 首启/同版本：播种
    }
    return false
  }

  /// A1：用户处置后（`runModal` 返回）记录已消费版本。必须在执行动作【之前】调用——「立即注销」会
  /// 启动注销链、可能终止进程，先落盘否则重启后重弹。
  static func recordDisposition(current: String, defaults: UserDefaults) {
    guard !current.isEmpty else { return }
    defaults.set(current, forKey: lastRunVersionKey)
  }

  /// 启动时调用（`applicationWillFinishLaunching`）。B2：只判定 + 播种，需要弹则**武装调度器**（非阻塞
  /// 返回），不再在启动回调里同步 `runModal`——真机已证同步弹会在用户开始输入后中途夺焦点、打断输入。
  @MainActor
  static func runIfNeeded(current: String, defaults: UserDefaults = FamoDefaults.standard) {
    guard planPrompt(current: current, defaults: defaults) else { return }
    FamoUpdateLogoutScheduler.shared.arm(current: current, defaults: defaults)
  }

  /// C1：建议注销对话框。标题不变；informative text 加 TCC 授权预告两句（首次点【立即注销】macOS 可能
  /// 问是否允许法墨控制「系统事件」、允许后仍有注销确认可取消），降低把正常授权当越权而拒绝的概率。
  /// **返回用户选择、不自己执行动作**——记录已处置与执行动作由外层（调度器）统一编排，以满足 A1 的
  /// 「记录在执行之前」。
  @MainActor
  static func presentAlert(current: String) -> Choice {
    let alert = NSAlert()
    alert.messageText = "法墨已更新到 \(current)，建议注销后重新登录"
    alert.informativeText = """
    注销并重新登录能让系统完整刷新输入法，法墨会稳定留在输入菜单——避免更新后法墨从菜单消失、或切换后打不出字。

    首次点「立即注销」时，macOS 可能会问你是否允许「法墨」控制「系统事件」——这是执行注销所必需的，请点允许；之后系统还会再弹一次注销确认，你仍可取消。

    你也可以选「稍后自己注销」，需要时从苹果菜单手动注销即可。
    """
    alert.addButton(withTitle: "立即注销")     // 第一个 = 默认
    alert.addButton(withTitle: "稍后自己注销")
    return alert.runModal() == .alertFirstButtonReturn ? .logoutNow : .later
  }
}

/// #131：B2 门控的**纯判定层**——值进值出，XCTest 可锁。#131 真机教训：不可测 + 不可观测的门控
/// 等于没有门控（一次搁浅合成让弹窗在整个进程生命周期静默，事后无从取证）。
/// 两个反「永久静默」阀：
///   - **搁浅合成阀**：同一快照 id 连续阻塞 `staleCompositionTicks` 个轮询周期（≈3 分钟）判为搁浅
///     （#37 类：宿主被杀/IMK client 静默消失时 `deactivateServer`/`emitCleared()` 不会跑，快照永不清空），
///     不再让它阻塞弹窗。真合成不受影响——任何按键/翻页都产生新快照 id，计数即归零。
///   - **激活确认阀**：`NSApp.activate` 后 `isActive` 连续 `activationConfirmTicks` 个周期未确认则直接
///     呈现（对齐 `FamoAIWindow` 先例——它从不检查 isActive；`runModal` 自会把窗口带到前台）。
enum FamoLogoutPromptTiming {
  /// 轮询间隔（秒）。
  static let pollInterval: TimeInterval = 1.5
  /// 输入空闲门槛（秒）。
  static let idleThreshold: TimeInterval = 2.0
  /// 同一快照连续阻塞多少个 tick 判为搁浅合成（120 × 1.5s ≈ 3 分钟）。
  static let staleCompositionTicks = 120
  /// 激活确认最多等多少个 tick（4 × 1.5s ≈ 6 秒），到limit直接呈现。
  static let activationConfirmTicks = 4
  /// 心跳日志间隔（40 × 1.5s ≈ 60 秒）。
  static let heartbeatTicks = 40

  struct SafeInput: Equatable {
    /// 当前合成快照 id；nil = 无合成。
    var snapshotID: UInt64?
    /// 距上次任意输入事件的秒数；nil = 读不到（异常态，不据此阻塞——宁可弹也不永久静默）。
    var idleSeconds: TimeInterval?
    var isLoginWindow: Bool
  }

  enum BlockReason: Equatable {
    case composing(snapshotID: UInt64, blockedTicks: Int)
    case inputBusy(idleSeconds: TimeInterval)
    case loginWindow
  }

  enum SafeVerdict: Equatable {
    /// `staleCompositionOverride`：放行时是否踩了搁浅合成阀（调用方须记日志）。
    case safe(staleCompositionOverride: Bool)
    case blocked(BlockReason)

    /// 变化检测键：用于「归因变化才记日志」。composing 不含快照 id / tick 数——连续打字时快照 id
    /// 逐键更新，含 id 会让每 tick 都算「变化」刷屏；细节由心跳行承载。
    var transitionKey: String {
      switch self {
      case .safe(true): return "safe+staleOverride"
      case .safe(false): return "safe"
      case .blocked(.composing): return "composing"
      case .blocked(.inputBusy): return "inputBusy"
      case .blocked(.loginWindow): return "loginWindow"
      }
    }
  }

  /// 同一快照连续阻塞计数器（值语义，可测）。每 tick 喂入当前快照 id，返回该 id 已连续观测的 tick 数。
  struct SnapshotBlockTracker: Equatable {
    private(set) var snapshotID: UInt64?
    private(set) var consecutiveTicks = 0

    mutating func observe(_ current: UInt64?) -> Int {
      guard let current else {
        snapshotID = nil
        consecutiveTicks = 0
        return 0
      }
      if current == snapshotID {
        consecutiveTicks += 1
      } else {
        snapshotID = current
        consecutiveTicks = 1
      }
      return consecutiveTicks
    }
  }

  /// 安全时机判定：合成（含搁浅阀）→ 输入空闲 → loginwindow，全过才 safe。
  static func safeVerdict(_ input: SafeInput, blockedTicks: Int) -> SafeVerdict {
    var stale = false
    if let id = input.snapshotID {
      if blockedTicks >= staleCompositionTicks {
        stale = true // 搁浅合成：不再阻塞，但要在日志中留痕
      } else {
        return .blocked(.composing(snapshotID: id, blockedTicks: blockedTicks))
      }
    }
    if let idle = input.idleSeconds, idle < idleThreshold {
      return .blocked(.inputBusy(idleSeconds: idle))
    }
    if input.isLoginWindow {
      return .blocked(.loginWindow)
    }
    return .safe(staleCompositionOverride: stale)
  }

  enum ActivationVerdict: Equatable {
    case waitNextTick
    /// `forcedWithoutActiveConfirm`：isActive 迟迟未确认、按阀直接呈现（调用方须记日志）。
    case present(forcedWithoutActiveConfirm: Bool)
  }

  static func activationVerdict(isActive: Bool, awaitingTicks: Int) -> ActivationVerdict {
    if isActive { return .present(forcedWithoutActiveConfirm: false) }
    if awaitingTicks >= activationConfirmTicks { return .present(forcedWithoutActiveConfirm: true) }
    return .waitNextTick
  }
}

/// B2：把「更新后建议注销」从「启动同步弹」改为「安全时机门控 + 激活确认 + 焦点还原」。
/// 真机已证同步弹（无 activation）会在用户开始输入后中途夺焦点、打断输入。编排复用 `FamoAIWindow` 的
/// 「先捕获宿主、稍后还原」思路：低频轮询等无合成 + 输入空闲，激活法墨自身后 `runModal`；
/// 「稍后自己注销」还原宿主焦点，「立即注销」保持前台进 TCC→系统注销确认链。
/// **不设「不安全也强弹」的全局超时**（用户持续输入/登录中永不打断）；但 #131 后「安全条件被卡死」的
/// 两类永久静默有阀（搁浅合成/激活未确认，见 `FamoLogoutPromptTiming`），且每步可观测：
///   `log stream --predicate 'subsystem == "im.famo.inputmethod.Famo" AND category == "logoutPrompt"'`
@MainActor
final class FamoUpdateLogoutScheduler {
  static let shared = FamoUpdateLogoutScheduler()
  private init() {}

  private enum Phase {
    case pending      // 等安全时机
    case activating   // 已请求激活法墨，等 isActive（有阀，不会永等）
  }

  private static let log = Logger(subsystem: "im.famo.inputmethod.Famo", category: "logoutPrompt")

  private var phase: Phase = .pending
  private var pendingVersion: String?
  private var defaults: UserDefaults = FamoDefaults.standard
  private var capturedApp: NSRunningApplication?
  private var timer: Timer?
  // #131 观测/反静默状态
  private var snapshotBlock = FamoLogoutPromptTiming.SnapshotBlockTracker()
  private var awaitingActiveTicks = 0
  private var tickCount = 0
  private var lastTransitionKey: String?

  /// 武装：记下待弹版本，启动低频轮询。同次启动只处理一次（已 pending 则忽略）。
  func arm(current: String, defaults: UserDefaults) {
    guard pendingVersion == nil else { return }
    pendingVersion = current
    self.defaults = defaults
    phase = .pending
    capturedApp = nil
    snapshotBlock = FamoLogoutPromptTiming.SnapshotBlockTracker()
    awaitingActiveTicks = 0
    tickCount = 0
    lastTransitionKey = nil
    Self.log.log("armed: version=\(current, privacy: .public)")
    startTimer()
  }

  private func startTimer() {
    timer?.invalidate()
    // Timer 回调是 @Sendable，非静态 @MainActor 隔离；但它跑在 main runloop 上，用 assumeIsolated 断言。
    let t = Timer(timeInterval: FamoLogoutPromptTiming.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard let version = pendingVersion else { stopTimer(); return }
    tickCount += 1
    let input = readSafeInput()
    let blockedTicks = snapshotBlock.observe(input.snapshotID)
    let verdict = FamoLogoutPromptTiming.safeVerdict(input, blockedTicks: blockedTicks)
    logVerdict(verdict, input: input, blockedTicks: blockedTicks)

    switch phase {
    case .pending:
      guard case .safe(let stale) = verdict else { return }
      if stale {
        let snapText = input.snapshotID.map(String.init) ?? "?"
        Self.log.log("stale-composition override: snapshotID=\(snapText, privacy: .public) blocked \(blockedTicks, privacy: .public) ticks — stranded (#37 class), proceeding")
      }
      capturedApp = NSWorkspace.shared.frontmostApplication
      NSApp.activate(ignoringOtherApps: true) // 对齐 FamoAIWindow 先例
      awaitingActiveTicks = 0
      phase = .activating
      Self.log.log("safe timing → activating; hostCaptured=\(self.capturedApp != nil, privacy: .public)")
    case .activating:
      guard case .safe = verdict else {
        // 等激活期间用户又开始输入/合成 → 撤回激活、还原宿主、退回等待
        capturedApp?.activate(options: [])
        capturedApp = nil
        phase = .pending
        Self.log.log("retreat: unsafe while awaiting activation (\(verdict.transitionKey, privacy: .public))")
        return
      }
      awaitingActiveTicks += 1
      switch FamoLogoutPromptTiming.activationVerdict(isActive: NSApp.isActive, awaitingTicks: awaitingActiveTicks) {
      case .waitNextTick:
        return
      case .present(let forced):
        present(version: version, forced: forced)
      }
    }
  }

  /// 呈现 + A1 记录 + 处置分派（从 `tick()` 抽出以受 cyclomatic_complexity 门）。
  private func present(version: String, forced: Bool) {
    if forced {
      Self.log.log("isActive unconfirmed after \(self.awaitingActiveTicks, privacy: .public) ticks → presenting anyway (FamoAIWindow precedent)")
    }
    stopTimer()
    pendingVersion = nil
    Self.log.log("presenting alert: version=\(version, privacy: .public)")
    let action = FamoUpdateLogoutPrompt.presentAlert(current: version)
    FamoUpdateLogoutPrompt.recordDisposition(current: version, defaults: defaults) // A1：执行前记录
    switch action {
    case .logoutNow:
      Self.log.log("disposition=logoutNow")
      capturedApp = nil // 保持前台进 TCC 链，不还原宿主
      FamoLogoutAction.requestLogout()
    case .later:
      Self.log.log("disposition=later — restoring host focus")
      capturedApp?.activate(options: []) // 还原宿主焦点
      capturedApp = nil
    }
  }

  /// 读安全时机三要素（impure 层，仅此一处碰系统 API）。
  private func readSafeInput() -> FamoLogoutPromptTiming.SafeInput {
    let snapshotID = FamoSnapshotRegistry.shared.current?.id
    // 自上次任意输入事件以来的秒数（kCGAnyInputEventType = 0xFFFFFFFF）。构造失败＝读不到空闲态：
    // 记错误但【不】据此阻塞——「条件读不到 → 永久静默」正是 #131 要消灭的失败类别。
    var idle: TimeInterval?
    if let anyInput = CGEventType(rawValue: ~0) {
      idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    } else {
      Self.log.error("CGEventType(~0) unavailable — idle unknown, not blocking on it")
    }
    let isLoginWindow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    return FamoLogoutPromptTiming.SafeInput(snapshotID: snapshotID, idleSeconds: idle, isLoginWindow: isLoginWindow)
  }

  /// 归因变化才记一行；心跳（≈60s）无论变没变都记一行带全量细节——保证「等着不弹」永远可从
  /// `log show` 取证（#131 验收：不允许「条件不满足 → 无日志」）。
  private func logVerdict(_ verdict: FamoLogoutPromptTiming.SafeVerdict,
                          input: FamoLogoutPromptTiming.SafeInput,
                          blockedTicks: Int) {
    let heartbeat = tickCount % FamoLogoutPromptTiming.heartbeatTicks == 0
    guard verdict.transitionKey != lastTransitionKey || heartbeat else { return }
    lastTransitionKey = verdict.transitionKey
    let idleText = input.idleSeconds.map { String(format: "%.1f", $0) } ?? "?"
    let snapText = input.snapshotID.map(String.init) ?? "nil"
    let kind = heartbeat ? "heartbeat" : "verdict"
    let summary = "\(kind): \(verdict.transitionKey) phase=\(phase) tick=\(tickCount)"
      + " snapshotID=\(snapText) blockedTicks=\(blockedTicks) idle=\(idleText)s"
    Self.log.log("\(summary, privacy: .public)")
  }
}

/// #111 问3 B：可复用的正式注销动作，更新提示【立即注销】与输入菜单「注销并重新登录…」共用一处，
/// 避免复制分流逻辑。发「tell System Events to log out」（走系统注销确认框，用户可存工作/取消），并按
/// `NSAppleScriptErrorNumber` 分流失败呈现。
enum FamoLogoutAction {
  /// hardening（#111 顺带发现）：`NSAppleScript.executeAndReturnError` 同步跑，`-1712` 超时可能把 IME
  /// 主线程（按键热路径）卡约 2 分钟。故 **off-main 执行**——NSAppleScript 在本 bg 线程构造+执行、不跨
  /// 线程共享（既定可接受用法），只把 `delivered`/`code` 两个原始值跨回主线程呈现 UI。
  /// 不加硬超时：硬超时会与用户在【系统注销确认框】的决定竞态，而 off-main 已解「卡主线程」这个被点名的
  /// 问题；`-1712` 的通用文案本就写成「以系统界面为准」，与「事件已送达、系统仍在等用户」自洽。
  ///
  /// nonisolated（不强制 @MainActor）：入口只是启动异步工作，不需主线程隔离；这样非 @MainActor 的
  /// IMK 菜单 handler（`FamoInputController` 非 @MainActor）与 @MainActor 调度器都能直接调。UI 呈现在
  /// `handleResult` 里经 `MainActor.assumeIsolated` 跳回主线程。
  static func requestLogout() {
    DispatchQueue.global(qos: .userInitiated).async {
      var error: NSDictionary?
      NSAppleScript(source: "tell application \"System Events\" to log out")?
        .executeAndReturnError(&error)
      let delivered = (error == nil)
      let code = error?["NSAppleScriptErrorNumber"] as? Int
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          handleResult(delivered: delivered, code: code)
        }
      }
    }
  }

  @MainActor
  private static func handleResult(delivered: Bool, code: Int?) {
    if delivered {
      // 事件送达即成功（系统随后弹注销确认框）——清除旧失败遥测，避免诊断包持续报告已恢复的问题。
      FamoLogoutDiagnostics.clear()
      return
    }
    FamoLogoutDiagnostics.record(errorNumber: code,
                                 category: FamoLogoutDiagnostics.classify(errorNumber: code))
    if code == -1743 {
      presentAutomationDeniedRecovery(code: code)
    } else {
      presentGenericManualLogout(code: code)
    }
  }

  /// 仅 -1743（`errAEEventNotPermitted`）：专属恢复 UI + 深链。
  /// ⚠️ 依赖 Part 1 前置：只有出厂产物带齐 `com.apple.security.automation.apple-events` +
  /// `NSAppleEventsUsageDescription`（`scripts/check-release.sh` 的 `assert_apple_events_prereqs` 守门），
  /// `-1743` 才只可能是「用户拒绝/关闭授权」；缺前置的包同样 `-1743`，那是包装缺陷、不是用户拒绝——
  /// 所以这段「你拒绝过授权」的文案必须与前置**同批出厂**（顺序硬约束）。
  @MainActor
  private static func presentAutomationDeniedRecovery(code: Int?) {
    let alert = NSAlert()
    alert.messageText = "无法自动注销：请重新开启「自动化」权限"
    alert.informativeText = """
    你曾拒绝或关闭了「法墨」控制「系统事件」的授权，系统因此静默拦下了自动注销，也不会再弹授权框。

    恢复方法：打开 系统设置 → 隐私与安全性 → 自动化，找到「法墨」，把「系统事件」重新打开；然后再点一次「注销并重新登录」即可。你也可以直接点屏幕左上角的苹果菜单 → 注销。

    诊断码：\(code.map(String.init) ?? "?")
    """
    alert.addButton(withTitle: "打开「自动化」设置") // 第一个 = 默认
    alert.addButton(withTitle: "好")
    if alert.runModal() == .alertFirstButtonReturn {
      openAutomationPrivacyPane()
    }
  }

  /// 深链直达 隐私与安全性 → 自动化（legacy ID，同 `FamoSkillsPage` 的 Accessibility 深链形式）。
  /// anchor 非稳定 Developer API，故上面文案同时给了完整手动路径兜底。
  private static func openAutomationPrivacyPane() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
      NSWorkspace.shared.open(url)
    }
  }

  /// 其余错误码（-1712 超时 / -128 / -1711 / 其它）：通用手动注销指引。
  /// **不**断言「注销一定没启动」（-1712 时事件可能已在途）；**不**把 -128/-1711 写成「你取消了注销」
  /// （AppleScript 无错误=事件已送达，用户随后在系统注销确认框点取消时 Famo 收不到码）。
  @MainActor
  private static func presentGenericManualLogout(code: Int?) {
    let alert = NSAlert()
    alert.messageText = "请从苹果菜单手动注销"
    alert.informativeText = """
    系统没有确认自动注销已启动。请点屏幕左上角的苹果菜单 → 注销，再重新登录即可；若系统的注销确认已经出现，请以系统界面为准。

    诊断码：\(code.map(String.init) ?? "?")
    """
    alert.addButton(withTitle: "好")
    alert.runModal()
  }
}

/// #111 问4 B：失败遥测。当场 UI 显示「诊断码：X」，同时把**最近一次**结构化失败**覆盖式**存进
/// UserDefaults（只留最新一条）；成功送达后清除；由 `FamoSettingsPages.supportBundleText` 的固定章节带出。
/// 不存 raw `NSDictionary` / route / 脚本源，不新建常驻文件日志。
enum FamoLogoutDiagnostics {
  static let lastFailureKey = "FamoLogoutLastFailure"
  static let schemaVersion = 1

  enum Category: String, Codable {
    case automationDenied
    case timeout
    case other
  }

  struct Failure: Codable {
    let schemaVersion: Int
    let timestampUTC: String
    let errorNumber: Int?
    let category: String
    let famoVersion: String
    let famoBuild: String
    let osVersion: String
    let phase: String
  }

  /// 按 #116 实测把错误码分类：-1743=自动化被拒、-1712=超时、其余=other。
  static func classify(errorNumber: Int?) -> Category {
    switch errorNumber {
    case -1743: return .automationDenied
    case -1712: return .timeout
    default: return .other
    }
  }

  /// 覆盖式写入最近一次结构化失败。
  static func record(errorNumber: Int?, category: Category, defaults: UserDefaults = FamoDefaults.standard) {
    let failure = Failure(
      schemaVersion: schemaVersion,
      timestampUTC: iso8601Now(),
      errorNumber: errorNumber,
      category: category.rawValue,
      famoVersion: bundleString("CFBundleShortVersionString"),
      famoBuild: bundleString("CFBundleVersion"),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      phase: "appleScriptSend"
    )
    guard let data = try? JSONEncoder().encode(failure) else { return }
    defaults.set(data, forKey: lastFailureKey)
  }

  /// 成功送达后清除（避免诊断包持续报告已恢复的问题）。
  static func clear(defaults: UserDefaults = FamoDefaults.standard) {
    defaults.removeObject(forKey: lastFailureKey)
  }

  static func lastFailure(defaults: UserDefaults = FamoDefaults.standard) -> Failure? {
    guard let data = defaults.data(forKey: lastFailureKey) else { return nil }
    return try? JSONDecoder().decode(Failure.self, from: data)
  }

  /// 诊断包固定章节（自带 `## 注销诊断` 段头，随 `supportBundleText` 的 `redact` 一并脱敏）。
  static func supportBundleSection(defaults: UserDefaults = FamoDefaults.standard) -> String {
    guard let f = lastFailure(defaults: defaults) else {
      return "## 注销诊断\n（无最近失败记录）"
    }
    return """
    ## 注销诊断（最近一次失败）
    时间(UTC): \(f.timestampUTC)
    错误码: \(f.errorNumber.map(String.init) ?? "?")
    分类: \(f.category)
    阶段: \(f.phase)
    版本: \(f.famoVersion) (\(f.famoBuild))
    系统: \(f.osVersion)
    """
  }

  private static func iso8601Now() -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: Date())
  }

  private static func bundleString(_ key: String) -> String {
    (Bundle.main.infoDictionary?[key] as? String) ?? ""
  }
}

/// 更新后选中态还原的**纯判定层**（2026-08-12，接替 postinstall 的 shell 轮询延迟任务）。
/// 值进值出，XCTest 可锁——门控不可测就等于没有门控（#131 教训，同 `FamoLogoutPromptTiming`）。
///
/// 机制背景（PR #130 定谳的根因）：更新 pkg 的 postinstall 里 `TISSelectInputSource` 返回 noErr
/// 也会在 PackageKit 对被替换 bundle 的**最终 LaunchServices 注册**落地时被踢回（macOS 26 两次
/// 实测）——注册边界晚于 postinstall 退出，脚本侧结构性追不到。app 由 postinstall 第 4 步
/// `open -g` 拉起，天然活过该边界，于是把还原做成 app 内事件驱动：
///   信号   postinstall 0e 在杀旧进程前写交接标记（内容 = epoch 秒；只在「更新打断了既有选中态」
///          时写——绝不劫持，首装/更新前不在法墨上都不写）。app 启动读后即删 = 有界一次性。
///   事件   `kTISNotifySelectedKeyboardInputSourceChanged` 分布式通知。轮询版只能看采样点状态，
///          事件版能拿到每次切换的精确时刻，从而用「踢回事件与自家 select 的时间相关性」区分
///          系统踢回（紧跟自家 select，重选）与用户主动切换（与自家 select 无时间相关，立即
///          收手）——这是 shell 轮询版无法根除的残余。
///   边界   武装窗 + 重选预算双重有界；窗口到期只留取证日志，绝不常驻。
/// 不变量：更新路径零 TISEnableInputSource（`--select-input-source` 无参对未启用态只打印即返回）、
/// 只还原被打断的既有选中态、有界一次性、不强制注销。
enum FamoUpdateSelectionRestorePolicy {
  /// 武装窗（秒）。shell 版实测边界：收据落盘 ≤30s、更晚的最终注册踢回再 ≤20s，合计 ~50s，留裕量。
  static let armWindowSeconds: TimeInterval = 90
  /// 踢回相关窗（秒）：非法墨事件距「自家最近一次 select」（武装时刻起算，postinstall 4b 的即时
  /// select 就在其前后一两秒）超过此值 → 判为用户主动切换，立即解除武装。
  static let bounceCorrelationSeconds: TimeInterval = 60
  /// 交接标记新鲜度（秒）：postinstall 写标记到 app 启动消费的最大可信间隔（安装失败残留 /
  /// 用户手动重开 app 的旧标记据此拒收；容忍 60s 时钟前跳）。
  static let markerStaleSeconds: TimeInterval = 600
  /// 重选总预算：1 次武装对账（踢回可能发生在 app 启动之前，事件已错过）+ 最多 3 次事件踢回。
  /// shell 版预算 8 覆盖 60s 盲轮询；事件版每次都先 fresh 读回确认非法墨才花，严格更省。
  static let reselectBudget = 4

  struct State: Equatable {
    let armedAt: Date
    var lastOwnSelectAt: Date
    var budgetLeft: Int
  }

  enum Verdict: Equatable {
    /// 法墨在位——按兵不动，窗口内继续观察（select 生效本身也触发一次事件，走到这里即闭环确认）。
    case keep
    /// 判为系统踢回——重选一次（调用方花预算并刷新 `lastOwnSelectAt`）。
    case reselect
    /// 与自家 select 无时间相关——用户主动切换，立即解除武装（对用户的让步优先于还原）。
    case userSwitchDisarm
    case windowExpiredDisarm
    case budgetExhaustedDisarm
  }

  /// 标记是否可信：epoch 可解析且距 now 在 [-60s, markerStaleSeconds] 内。
  static func shouldArm(markerEpoch: TimeInterval?, now: Date) -> Bool {
    guard let epoch = markerEpoch else { return false }
    let age = now.timeIntervalSince1970 - epoch
    return age >= -60 && age <= markerStaleSeconds
  }

  /// 一次「当前源读回」的归因。判定次序是硬约束：窗口先于一切（到期即收）；法墨在位不花预算；
  /// 预算先于相关性（花完只观察）；相关性最后裁「系统踢回 vs 用户切换」。
  static func verdict(state: State, currentIsFamo: Bool, now: Date) -> Verdict {
    if now.timeIntervalSince(state.armedAt) > armWindowSeconds { return .windowExpiredDisarm }
    if currentIsFamo { return .keep }
    guard state.budgetLeft > 0 else { return .budgetExhaustedDisarm }
    guard now.timeIntervalSince(state.lastOwnSelectAt) <= bounceCorrelationSeconds else {
      return .userSwitchDisarm
    }
    return .reselect
  }

  /// `--current-input-source` fresh 进程输出解析：取最后一个非空行（进程可能先打印别的行，
  /// shell 版同用 `tail -n 1`）。
  static func parseCurrentSourceID(_ output: String?) -> String? {
    guard let output else { return nil }
    let lines = output.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.last
  }
}

/// 更新后选中态还原的**事件驱动层**（impure 壳，判定全在 `FamoUpdateSelectionRestorePolicy`）。
/// 生命周期：`applicationWillFinishLaunching` 里 `armIfMarkerPresent()` 消费 postinstall 0e 的
/// 交接标记（读后即删）→ 武装对账一次 → 自注册 TIS 选中源变化观察者 → 每个事件 fresh 读回归因
/// → 窗口到期/预算花完/用户切换即解除武装并注销观察者。未武装时零观察者、零开销。
///
/// 读回与 select 都 spawn 自家可执行文件 fresh 进程（`--current-input-source` /
/// `--select-input-source`），与 `InstallerActivationVerifier`（DMG 路径）、shell 延迟任务
/// （被本类型接替）同一套已实证机器：本进程 TIS 快照在注册窗口内会撒谎（定律 13′），fresh 进程
/// 读值为真；fresh select 也绕开定律 2 的嵌套 runloop -50。spawn 只在武装窗内、事件触发时发生，
/// 不在 IMK 按键热路径上。
///
/// 观察者是**自注册的 selector + `.deliverImmediately`**，不复用 `addObservers()` 里的 block
/// 观察者：block API 只有默认 `.coalesce` 挂起行为，而注销提示（`FamoUpdateLogoutScheduler`）
/// 恰会在本窗口内激活又失活 app——那正是 NSApplication 挂起 DNC 投递的触发条件（2026-07-24
/// `--reload` 静默失效同根因），挂起后踢回事件将静默丢失。
///
/// 可观测（真机红灯/绿灯取证入口）：
///   log show --last 5m --predicate 'subsystem == "im.famo.inputmethod.Famo" AND category == "updateRestore"'
@MainActor
final class FamoUpdateSelectionRestorer: NSObject {
  static let shared = FamoUpdateSelectionRestorer()
  override private init() {}

  static let markerPath = "/private/tmp/im.famo.inputmethod.update-restore-pending"
  private static let log = Logger(subsystem: "im.famo.inputmethod.Famo", category: "updateRestore")

  private var state: FamoUpdateSelectionRestorePolicy.State?
  private var probeInFlight = false
  private var selectInFlight = false
  private var recheckQueued = false
  private var selectCount = 0
  private var observing = false

  /// 启动时调用一次：有新鲜交接标记才武装。标记读后即删（一次性）；单测进程不消费真机标记。
  func armIfMarkerPresent(now: Date = Date()) {
    guard !FamoDefaults.isRunningUnitTests, state == nil else { return }
    guard let raw = try? String(contentsOfFile: Self.markerPath, encoding: .utf8) else { return }
    try? FileManager.default.removeItem(atPath: Self.markerPath)
    let epoch = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    guard FamoUpdateSelectionRestorePolicy.shouldArm(markerEpoch: epoch, now: now) else {
      Self.log.log("marker stale — not arming (epoch=\(raw.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public))")
      return
    }
    state = .init(
      armedAt: now,
      lastOwnSelectAt: now, // postinstall 4b 的即时 select 就在武装前后一两秒，作初始相关锚
      budgetLeft: FamoUpdateSelectionRestorePolicy.reselectBudget)
    startObserving()
    Self.log.log("armed: window=\(Int(FamoUpdateSelectionRestorePolicy.armWindowSeconds), privacy: .public)s budget=\(FamoUpdateSelectionRestorePolicy.reselectBudget, privacy: .public)")
    probeAndAct() // 武装对账：踢回可能已发生在 app 启动之前
    DispatchQueue.main.asyncAfter(deadline: .now() + FamoUpdateSelectionRestorePolicy.armWindowSeconds + 1) {
      MainActor.assumeIsolated { Self.shared.closeWindowIfStillArmed() }
    }
  }

  private func startObserving() {
    guard !observing else { return }
    observing = true
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(selectedSourceChanged(_:)),
      name: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      suspensionBehavior: .deliverImmediately)
  }

  private func stopObserving() {
    guard observing else { return }
    observing = false
    DistributedNotificationCenter.default().removeObserver(
      self,
      name: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil)
  }

  @objc private nonisolated func selectedSourceChanged(_ notification: Notification) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { Self.shared.probeAndAct() }
    }
  }

  /// fresh 读回 → 主线程归因。in-flight 防重入（同 `InstallerActivationVerifier.tick`）：撞上
  /// 在途探针/select 只置补查旗标，评估后总会再跑一轮——绝不吞掉最后一个事件。
  private func probeAndAct() {
    guard state != nil else { return }
    if probeInFlight || selectInFlight {
      recheckQueued = true
      return
    }
    probeInFlight = true
    DispatchQueue.global(qos: .userInitiated).async {
      let output = Self.runOwnBinary(["--current-input-source"])
      DispatchQueue.main.async {
        MainActor.assumeIsolated { Self.shared.evaluate(probeOutput: output) }
      }
    }
  }

  private func evaluate(probeOutput: String?) {
    probeInFlight = false
    defer {
      if recheckQueued && state != nil && !selectInFlight {
        recheckQueued = false
        probeAndAct()
      }
    }
    guard var current = state else { return }
    guard let sourceID = FamoUpdateSelectionRestorePolicy.parseCurrentSourceID(probeOutput) else {
      Self.log.log("probe-empty — keeping watch (spawn 失败不花预算也不误判)")
      return
    }
    let isFamo = sourceID.hasPrefix(FamoInstaller.inputSourcePrefix)
    let now = Date()
    let verdict = FamoUpdateSelectionRestorePolicy.verdict(state: current, currentIsFamo: isFamo, now: now)
    switch verdict {
    case .keep:
      Self.log.log("keep: current=\(sourceID, privacy: .public) selects=\(self.selectCount, privacy: .public)")
    case .reselect:
      current.budgetLeft -= 1
      current.lastOwnSelectAt = now
      state = current
      selectCount += 1
      selectInFlight = true
      Self.log.log("reselect #\(self.selectCount, privacy: .public): bounced-to=\(sourceID, privacy: .public) budgetLeft=\(current.budgetLeft, privacy: .public)")
      DispatchQueue.global(qos: .userInitiated).async {
        _ = Self.runOwnBinary(["--select-input-source"])
        DispatchQueue.main.async {
          MainActor.assumeIsolated { Self.shared.noteSelectFinished() }
        }
      }
    case .userSwitchDisarm:
      disarm(reason: "user-switch: to=\(sourceID) uncorrelated with own select — respecting user")
    case .windowExpiredDisarm:
      disarm(reason: "window-expired: current=\(sourceID) selects=\(selectCount)")
    case .budgetExhaustedDisarm:
      disarm(reason: "budget-exhausted: current=\(sourceID) selects=\(selectCount)")
    }
  }

  private func noteSelectFinished() {
    selectInFlight = false
    if recheckQueued && state != nil {
      recheckQueued = false
      probeAndAct()
    }
  }

  /// 窗口到期收尾：解除武装后再补一发终态探针，把绿灯/红灯写成可取证的最后一行。
  private func closeWindowIfStillArmed() {
    guard state != nil else { return }
    let selects = selectCount
    disarm(reason: "window-closed: selects=\(selects) — final readback follows")
    DispatchQueue.global(qos: .utility).async {
      let sourceID = FamoUpdateSelectionRestorePolicy.parseCurrentSourceID(
        Self.runOwnBinary(["--current-input-source"])) ?? "?"
      Self.log.log("final: current=\(sourceID, privacy: .public) selects=\(selects, privacy: .public)")
    }
  }

  private func disarm(reason: String) {
    state = nil
    recheckQueued = false
    stopObserving()
    Self.log.log("disarmed: \(reason, privacy: .public)")
  }

  /// spawn 自家可执行文件 fresh 进程（先排空管道再等退出——1.3.32 Bug A 同病同修）。
  /// 输出坏/进程失败 → nil = 本轮无信号，绝不据此行动。
  private nonisolated static func runOwnBinary(_ arguments: [String]) -> String? {
    guard let executable = Bundle.main.executablePath else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
