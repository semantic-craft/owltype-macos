//
//  FamoInputController+AIWindow.swift
//  法墨输入法 (Famo) — AI conversation window trigger (roadmap B10, v1)
//
//  The ONE controller seam for the B10 AI conversation window. An explicit menu action reads the
//  controller's live composition snapshot (via the injected `snapshots` port — the same indirection
//  the existing AI cloud/local actions use) and opens/shows the single reused `FamoAIWindow` with
//  that snapshot captured. Safe when there is no snapshot — the window opens for a general question.
//
//  Off the IMK key-event hot path: this is a status-menu action, never called from `handle()` /
//  `processKey`. It never mutates the librime session or the composition; the window is copy-only.
//
//  云端 AI 总闸（`FamoCloudPreferences.isEnabled`）也管这里 —— 见 `FamoAskAnythingGate`。
//

import InputMethodKit

/// 任意提问的云端总闸判定。
///
/// 抽成纯函数是为了可测：`requestAIConversation()` 本身要读 `NSApp` 和单例窗口，测不动；把「放不放行 +
/// 说什么」摘出来，两个分支才断言得了。写法对齐划词菜单的 `FamoSelectionMenuAction.enabledActions(cloudEnabled:)`。
enum FamoAskAnythingGate {
  /// 关闸时给用户看的话。状态菜单栏入口没有可写内联提示的地方，静默返回会被当成「按钮坏了」，
  /// 所以必须出声，且点明去哪儿开。
  static let disabledMessage = "云端 AI 已关闭，「任意提问」不可用。可在「设置 → 技能平台 → 云端 AI（全局）」中开启。"

  enum Decision: Equatable {
    case open
    case blocked(message: String)
  }

  /// 默认参数真读总闸；`cloudEnabled` 只为测试注入而存在。
  static func decide(cloudEnabled: Bool = FamoCloudPreferences.isEnabled) -> Decision {
    cloudEnabled ? .open : .blocked(message: disabledMessage)
  }
}

extension FamoInputController {
  /// Open the AI conversation window over the current composition context. Mirrors the existing
  /// explicit AI actions' snapshot read (`NSApp.famoAppDelegate.snapshots.current`); nil-safe.
  ///
  /// Hops onto the main actor to read the `@MainActor`-isolated `snapshots` port and touch the
  /// `@MainActor` window, exactly like the existing AI menu actions wrap their snapshot read in a
  /// `@MainActor` Task. Fire-and-forget (the window owns its own lifecycle), so this does NOT take a
  /// `FamoLaneTasks` lane slot. Not on the IMK key-event hot path.
  ///
  /// 云端 AI 关闭时不开窗，只出一条通知。`FamoCloudPreferences.isEnabled` 的定义处写明它是「划词润色 /
  /// 任意提问」的共用闸，但此前只有划词菜单接了线（`enabledActions` 关闸返空），状态菜单入口直通 ——
  /// 关闸后点状态菜单栏仍能开窗、提问、真发网络请求。任意提问的直达热键已退役（2026-07-26），
  /// 无选区调用点只剩状态菜单项，全部汇到这个方法，挡这一处即全封。
  @objc func requestAIConversation() {
    FamoLatencyTrace.event("button.open.aiConversation")
    if case let .blocked(message) = FamoAskAnythingGate.decide() {
      FamoApplicationDelegate.showMessage(msgText: message)
      return
    }
    Task { @MainActor in
      let trace = FamoLatencyTrace.begin("window.open.aiConversation")
      defer { FamoLatencyTrace.end("window.open.aiConversation", trace) }
      FamoAIWindow.shared.show()
    }
  }
}
