import AppKit
import CoreGraphics
import os

/// Recovery guidance only after an explicit installation-session self-check failure.
/// Version changes (including downgrades) are not evidence that a login session is broken.
enum OwlUpdateLogoutPrompt {
  static let lastRunVersionKey = "OwlLastRunVersion"
  static let failureVersionKey = "OwlInstallSelfCheckFailedVersion"
  static let selfCheckNotification = Notification.Name("OwlInstallSelfCheckChanged")

  /// 用户对建议注销对话框的处置。
  enum Choice {
    case logoutNow
    case later
  }

  static func shouldSuggest(failedVersion: String?, current: String) -> Bool {
    !current.isEmpty && failedVersion == current
  }

  @discardableResult
  static func planPrompt(current: String, defaults: UserDefaults) -> Bool {
    if shouldSuggest(failedVersion: defaults.string(forKey: failureVersionKey), current: current) { return true }
    if !current.isEmpty { defaults.set(current, forKey: lastRunVersionKey) }
    return false
  }

  static func recordSelfCheck(current: String, passed: Bool, defaults: UserDefaults = OwlDefaults.standard) {
    guard !current.isEmpty else { return }
    if passed { defaults.removeObject(forKey: failureVersionKey) } else { defaults.set(current, forKey: failureVersionKey) }
    defaults.synchronize()
  }

  /// A1：用户处置后（`runModal` 返回）记录已消费版本。必须在执行动作【之前】调用——「立即注销」会
  /// 启动注销链、可能终止进程，先落盘否则重启后重弹。
  static func recordDisposition(current: String, defaults: UserDefaults) {
    guard !current.isEmpty else { return }
    defaults.set(current, forKey: lastRunVersionKey)
    defaults.removeObject(forKey: failureVersionKey)
  }

  /// Called when the installation session reports a result, never because the app version changed.
  @MainActor
  static func runIfNeeded(current: String, defaults: UserDefaults = OwlDefaults.standard) {
    defaults.synchronize()
    guard planPrompt(current: current, defaults: defaults) else {
      OwlUpdateLogoutScheduler.shared.cancelPendingPrompt()
      return
    }
    OwlUpdateLogoutScheduler.shared.arm(current: current, defaults: defaults)
  }

  /// Optional recovery after a failed self-check; the default button leaves the session running.
  /// **返回用户选择、不自己执行动作**——记录已处置与执行动作由外层（调度器）统一编排，以满足 A1 的
  /// 「记录在执行之前」。
  @MainActor
  static func presentAlert(current: String) -> Choice {
    let alert = NSAlert()
    alert.messageText = "猫头鹰 \(current) 安装后的会话自检未通过"
    alert.informativeText = """
    请先在输入菜单中选择猫头鹰并试输入；也可以重试安装或在系统设置检查输入法。若仍无法恢复，可尝试注销并重新登录。

    首次选择注销时，macOS 可能会问你是否允许「猫头鹰」控制「系统事件」——这是执行注销所必需的，请点允许；之后系统还会再弹一次注销确认，你仍可取消。

    你也可以选「稍后处理」，需要时从苹果菜单手动注销即可。
    """
    alert.addButton(withTitle: "稍后处理")
    alert.addButton(withTitle: "注销并重新登录…")
    return alert.runModal() == .alertSecondButtonReturn ? .logoutNow : .later
  }
}

/// #131：B2 门控的**纯判定层**——值进值出，XCTest 可锁。#131 真机教训：不可测 + 不可观测的门控
/// 等于没有门控（一次搁浅合成让弹窗在整个进程生命周期静默，事后无从取证）。
/// 两个反「永久静默」阀：
///   - **搁浅合成阀**：同一快照 id 连续阻塞 `staleCompositionTicks` 个轮询周期（≈3 分钟）判为搁浅
///     （#37 类：宿主被杀/IMK client 静默消失时 `deactivateServer`/`emitCleared()` 不会跑，快照永不清空），
///     不再让它阻塞弹窗。真合成不受影响——任何按键/翻页都产生新快照 id，计数即归零。
///   - **激活确认阀**：`NSApp.activate` 后 `isActive` 连续 `activationConfirmTicks` 个周期未确认则直接
///     呈现（对齐 `OwlAIWindow` 先例——它从不检查 isActive；`runModal` 自会把窗口带到前台）。
enum OwlLogoutPromptTiming {
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
/// 真机已证同步弹（无 activation）会在用户开始输入后中途夺焦点、打断输入。编排复用 `OwlAIWindow` 的
/// 「先捕获宿主、稍后还原」思路：低频轮询等无合成 + 输入空闲，激活猫头鹰自身后 `runModal`；
/// 「稍后自己注销」还原宿主焦点，「立即注销」保持前台进 TCC→系统注销确认链。
/// **不设「不安全也强弹」的全局超时**（用户持续输入/登录中永不打断）；但 #131 后「安全条件被卡死」的
/// 两类永久静默有阀（搁浅合成/激活未确认，见 `OwlLogoutPromptTiming`），且每步可观测：
///   `log stream --predicate 'subsystem == "im.owltype.inputmethod.Owltype" AND category == "logoutPrompt"'`
@MainActor
final class OwlUpdateLogoutScheduler {
  static let shared = OwlUpdateLogoutScheduler()
  private init() {}

  private enum Phase {
    case pending      // 等安全时机
    case activating   // 已请求激活猫头鹰，等 isActive（有阀，不会永等）
  }

  private static let log = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "logoutPrompt")

  private var phase: Phase = .pending
  private var pendingVersion: String?
  private var defaults: UserDefaults = OwlDefaults.standard
  private var capturedApp: NSRunningApplication?
  private var timer: Timer?
  // #131 观测/反静默状态
  private var snapshotBlock = OwlLogoutPromptTiming.SnapshotBlockTracker()
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
    snapshotBlock = OwlLogoutPromptTiming.SnapshotBlockTracker()
    awaitingActiveTicks = 0
    tickCount = 0
    lastTransitionKey = nil
    Self.log.log("armed: version=\(current, privacy: .public)")
    startTimer()
  }

  func cancelPendingPrompt() {
    stopTimer()
    pendingVersion = nil
  }

  private func startTimer() {
    timer?.invalidate()
    // Timer 回调是 @Sendable，非静态 @MainActor 隔离；但它跑在 main runloop 上，用 assumeIsolated 断言。
    let t = Timer(timeInterval: OwlLogoutPromptTiming.pollInterval, repeats: true) { [weak self] _ in
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
    let verdict = OwlLogoutPromptTiming.safeVerdict(input, blockedTicks: blockedTicks)
    logVerdict(verdict, input: input, blockedTicks: blockedTicks)

    switch phase {
    case .pending:
      guard case .safe(let stale) = verdict else { return }
      if stale {
        let snapText = input.snapshotID.map(String.init) ?? "?"
        Self.log.log("stale-composition override: snapshotID=\(snapText, privacy: .public) blocked \(blockedTicks, privacy: .public) ticks — stranded (#37 class), proceeding")
      }
      capturedApp = NSWorkspace.shared.frontmostApplication
      NSApp.activate(ignoringOtherApps: true) // 对齐 OwlAIWindow 先例
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
      switch OwlLogoutPromptTiming.activationVerdict(isActive: NSApp.isActive, awaitingTicks: awaitingActiveTicks) {
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
      Self.log.log("isActive unconfirmed after \(self.awaitingActiveTicks, privacy: .public) ticks → presenting anyway (OwlAIWindow precedent)")
    }
    stopTimer()
    pendingVersion = nil
    Self.log.log("presenting alert: version=\(version, privacy: .public)")
    let action = OwlUpdateLogoutPrompt.presentAlert(current: version)
    OwlUpdateLogoutPrompt.recordDisposition(current: version, defaults: defaults) // A1：执行前记录
    switch action {
    case .logoutNow:
      Self.log.log("disposition=logoutNow")
      capturedApp = nil // 保持前台进 TCC 链，不还原宿主
      OwlLogoutAction.requestLogout()
    case .later:
      Self.log.log("disposition=later — restoring host focus")
      capturedApp?.activate(options: []) // 还原宿主焦点
      capturedApp = nil
    }
  }

  /// 读安全时机三要素（impure 层，仅此一处碰系统 API）。
  private func readSafeInput() -> OwlLogoutPromptTiming.SafeInput {
    let snapshotID = OwlSnapshotRegistry.shared.current?.id
    // 自上次任意输入事件以来的秒数（kCGAnyInputEventType = 0xFFFFFFFF）。构造失败＝读不到空闲态：
    // 记错误但【不】据此阻塞——「条件读不到 → 永久静默」正是 #131 要消灭的失败类别。
    var idle: TimeInterval?
    if let anyInput = CGEventType(rawValue: ~0) {
      idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    } else {
      Self.log.error("CGEventType(~0) unavailable — idle unknown, not blocking on it")
    }
    let isLoginWindow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    return OwlLogoutPromptTiming.SafeInput(snapshotID: snapshotID, idleSeconds: idle, isLoginWindow: isLoginWindow)
  }

  /// 归因变化才记一行；心跳（≈60s）无论变没变都记一行带全量细节——保证「等着不弹」永远可从
  /// `log show` 取证（#131 验收：不允许「条件不满足 → 无日志」）。
  private func logVerdict(_ verdict: OwlLogoutPromptTiming.SafeVerdict,
                          input: OwlLogoutPromptTiming.SafeInput,
                          blockedTicks: Int) {
    let heartbeat = tickCount % OwlLogoutPromptTiming.heartbeatTicks == 0
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
enum OwlLogoutAction {
  /// hardening（#111 顺带发现）：`NSAppleScript.executeAndReturnError` 同步跑，`-1712` 超时可能把 IME
  /// 主线程（按键热路径）卡约 2 分钟。故 **off-main 执行**——NSAppleScript 在本 bg 线程构造+执行、不跨
  /// 线程共享（既定可接受用法），只把 `delivered`/`code` 两个原始值跨回主线程呈现 UI。
  /// 不加硬超时：硬超时会与用户在【系统注销确认框】的决定竞态，而 off-main 已解「卡主线程」这个被点名的
  /// 问题；`-1712` 的通用文案本就写成「以系统界面为准」，与「事件已送达、系统仍在等用户」自洽。
  ///
  /// nonisolated（不强制 @MainActor）：入口只是启动异步工作，不需主线程隔离；这样非 @MainActor 的
  /// IMK 菜单 handler（`OwlInputController` 非 @MainActor）与 @MainActor 调度器都能直接调。UI 呈现在
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
      OwlLogoutDiagnostics.clear()
      return
    }
    OwlLogoutDiagnostics.record(errorNumber: code,
                                 category: OwlLogoutDiagnostics.classify(errorNumber: code))
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
    你曾拒绝或关闭了「猫头鹰」控制「系统事件」的授权，系统因此静默拦下了自动注销，也不会再弹授权框。

    恢复方法：打开 系统设置 → 隐私与安全性 → 自动化，找到「猫头鹰」，把「系统事件」重新打开；然后再点一次「注销并重新登录」即可。你也可以直接点屏幕左上角的苹果菜单 → 注销。

    诊断码：\(code.map(String.init) ?? "?")
    """
    alert.addButton(withTitle: "打开「自动化」设置") // 第一个 = 默认
    alert.addButton(withTitle: "好")
    if alert.runModal() == .alertFirstButtonReturn {
      openAutomationPrivacyPane()
    }
  }

  /// 深链直达 隐私与安全性 → 自动化（legacy ID，同 `OwlSkillsPage` 的 Accessibility 深链形式）。
  /// anchor 非稳定 Developer API，故上面文案同时给了完整手动路径兜底。
  private static func openAutomationPrivacyPane() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
      NSWorkspace.shared.open(url)
    }
  }

  /// 其余错误码（-1712 超时 / -128 / -1711 / 其它）：通用手动注销指引。
  /// **不**断言「注销一定没启动」（-1712 时事件可能已在途）；**不**把 -128/-1711 写成「你取消了注销」
  /// （AppleScript 无错误=事件已送达，用户随后在系统注销确认框点取消时 Owltype 收不到码）。
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
/// UserDefaults（只留最新一条）；成功送达后清除；由 `OwlSettingsPages.supportBundleText` 的固定章节带出。
/// 不存 raw `NSDictionary` / route / 脚本源，不新建常驻文件日志。
enum OwlLogoutDiagnostics {
  static let lastFailureKey = "OwlLogoutLastFailure"
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
    let owlVersion: String
    let owlBuild: String
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
  static func record(errorNumber: Int?, category: Category, defaults: UserDefaults = OwlDefaults.standard) {
    let failure = Failure(
      schemaVersion: schemaVersion,
      timestampUTC: iso8601Now(),
      errorNumber: errorNumber,
      category: category.rawValue,
      owlVersion: bundleString("CFBundleShortVersionString"),
      owlBuild: bundleString("CFBundleVersion"),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      phase: "appleScriptSend"
    )
    guard let data = try? JSONEncoder().encode(failure) else { return }
    defaults.set(data, forKey: lastFailureKey)
  }

  /// 成功送达后清除（避免诊断包持续报告已恢复的问题）。
  static func clear(defaults: UserDefaults = OwlDefaults.standard) {
    defaults.removeObject(forKey: lastFailureKey)
  }

  static func lastFailure(defaults: UserDefaults = OwlDefaults.standard) -> Failure? {
    guard let data = defaults.data(forKey: lastFailureKey) else { return nil }
    return try? JSONDecoder().decode(Failure.self, from: data)
  }

  /// 诊断包固定章节（自带 `## 注销诊断` 段头，随 `supportBundleText` 的 `redact` 一并脱敏）。
  static func supportBundleSection(defaults: UserDefaults = OwlDefaults.standard) -> String {
    guard let f = lastFailure(defaults: defaults) else {
      return "## 注销诊断\n（无最近失败记录）"
    }
    return """
    ## 注销诊断（最近一次失败）
    时间(UTC): \(f.timestampUTC)
    错误码: \(f.errorNumber.map(String.init) ?? "?")
    分类: \(f.category)
    阶段: \(f.phase)
    版本: \(f.owlVersion) (\(f.owlBuild))
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
