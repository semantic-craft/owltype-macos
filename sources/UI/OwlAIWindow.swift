//
//  OwlAIWindow.swift
//  猫头鹰输入法 (Owltype) — AI conversation window (roadmap B10, v1)
//
//  A small Owltype-owned chat window that already knows the user's current composition context.
//  azooKey-style lifecycle: a SINGLE reused instance (`isReleasedWhenClosed = false`), takes key
//  focus for its question field (`canBecomeKey = true`) but captures the frontmost app BEFORE
//  showing and restores it on EVERY close path (submit-done / cancel / Esc / close). All stored
//  callbacks are `[weak self]` and nilled in `close()` so the window↔model retain cycle is broken.
//
//  The window is COPY-ONLY: the streamed answer is never auto-inserted into the target app and there
//  is no replace-selection. Opening / using it never mutates the engine session or the composition
//  — it only reads the captured snapshot (already a plain value) and talks to the cloud provider.
//
//  Boundary: SwiftUI is the sole renderer (the view is hosted via `NSHostingView`); the IMK
//  key-event hot path is untouched. AppKit window lifecycle is not headless-unit-testable, so the
//  view model + assembler (both fully tested) are the safety net; this file is intentionally thin.
//
//  Concurrency: not `@MainActor`-isolated at the class level (mirrors `OwlSettingsWindow` /
//  `OwlSwiftUICandidatePanel`); the non-isolated controller calls `show(...)` on the main thread.
//

import AppKit
import SwiftUI

/// 工具箱模式的上下文（2026-07-26 重设计）：召唤（双击 ⌥ / 热键）打开本窗时带上已启用技能，
/// 窗口在选区引文下方渲染技能按钮行，点击经 `onSkill` 派回协调器分发（选区快照捕获在闭包里）。
/// 普通 show()（toolbox = nil）= 纯任意提问窗，无按钮行。`askEnabled` = false 时隐藏输入框
/// （任意提问技能被关，窗口只当技能面板用）。
struct OwlAIToolboxContext {
  let actions: [OwlSelectionMenuAction]
  let askEnabled: Bool
  let onSkill: (OwlSelectionMenuAction) -> Void
}

final class OwlAIWindow: NSWindowController {
  /// The single reused window instance (azooKey lifecycle). Held here rather than on
  /// `OwlApplicationDelegate` so the B10 trigger touches NO shared controller/delegate file — only
  /// this new file + one `+Menu.swift` line. Created lazily on first AI-window trigger; reused
  /// across triggers (each `show` captures a fresh snapshot). Main-thread only (the menu action
  /// originates on the main thread), so a non-atomic static is safe.
  @MainActor static let shared = OwlAIWindow()

  /// Strong reference to the view model so it lives as long as the window. Recreated per `show`
  /// (each trigger captures a fresh snapshot).
  private var model: OwlAIConversationModel?
  /// The app that was frontmost BEFORE we showed (so we can restore focus to it on close).
  private weak var previousApp: NSRunningApplication?

  init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Keep the title for a11y / the Window menu, but hide it and let the SwiftUI paper flow under a
    // transparent titlebar (方案 C) — no duplicate "猫头鹰 AI 对话" over the content header.
    panel.title = NSLocalizedString("猫头鹰 AI 对话", comment: "Owltype AI conversation window title")
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 420, height: 360)
    panel.level = .floating
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.center()
    // 可 resize 后记住用户调过的尺寸/位置（首开仍居中；有存档则存档优先）。
    panel.setFrameAutosaveName("OwlAIConversationWindow")
    super.init(window: panel)
    panel.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Build (or reuse) the window with an optional invocation context, then bring it front without
  /// activating the Owltype process at the OS level (nonactivating panel).
  @discardableResult
  func show(
    context: OwlAIInvocationContext = .standalone,
    selectedText: String? = nil,
    initialQuestion: String = "",
    initialDisplayQuestion: String? = nil,
    autoSubmit: Bool = false,
    composerTask: OwlAIComposerTask? = nil,
    initialState: OwlAIConversationState = .idle,
    toolbox: OwlAIToolboxContext? = nil,
    initialMode: OwlAIWritingMode = .chat
  ) -> OwlAIConversationModel {
    // 已开着时不重复抓前台 App：工具箱按钮（翻译/辅助检索）原地刷新窗口，此刻前台是本窗自己，
    // 覆盖掉会把「关窗还焦点」的目标丢掉。
    if window?.isVisible != true {
      previousApp = NSWorkspace.shared.frontmostApplication
    }

    self.model?.teardown()
    let effectiveSelectedText: String? = {
      if let selectedText { return selectedText }
      if case let .selection(snapshot) = context { return snapshot.text }
      if case let .typing(_, preedit, _, _) = context, !preedit.isEmpty { return preedit }
      return nil
    }()
    let model = OwlAIConversationModel(
      selectedText: effectiveSelectedText,
      initialState: initialState
    )
    self.model = model

    let rootView = OwlAIConversationView(
      model: model,
      context: context,
      initialMode: initialMode,
      initialQuestion: initialQuestion,
      initialDisplayQuestion: initialDisplayQuestion,
      autoSubmit: autoSubmit,
      initialTask: composerTask,
      toolbox: toolbox,
      onWriteback: { [weak self] answer in
        guard let self else { return }
        OwlAIWritebackCoordinator.shared.writeback(
          text: answer,
          context: context,
          onDismissWindow: { [weak self] in
            self?.window?.close()
          }
        )
      },
      onCopy: { [weak self] text in self?.copy(text) },
      onClose: { [weak self] in self?.window?.close() }
    )
    window?.contentView = NSHostingView(rootView: rootView)

    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    return model
  }

  @discardableResult
  func showPolish(
    context: OwlAIInvocationContext,
    selectedText: String? = nil,
    style: OwlPolishStyle = .faithful
  ) -> OwlAIConversationModel {
    show(context: context, selectedText: selectedText, initialMode: .polish)
  }

  @discardableResult
  func showReply(
    context: OwlAIInvocationContext,
    contextText: String? = nil,
    template: OwlReplyTemplate = .agree
  ) -> OwlAIConversationModel {
    show(context: context, selectedText: contextText, initialMode: .quickReply)
  }
  // 出窗技能（核验回执卡 / 替换原文的技能）执行前用继承的 NSWindowController.close() 关窗，
  // 经 windowWillClose 把焦点还给宿主。

  /// Copy-only: the answer goes to the pasteboard. It is NEVER auto-inserted into the target app.
  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// Restore key focus to the app that was frontmost before we showed.
  private func restorePreviousApp() {
    previousApp?.activate(options: [])
    previousApp = nil
  }
}

// MARK: - Window lifecycle (close → tear down model + restore focus)

extension OwlAIWindow: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // Cancel any in-flight stream and drop the model's callback retain BEFORE restoring focus, so
    // the window↔model cycle is broken on every close path (button / Esc / red traffic light).
    model?.teardown()
    model = nil
    restorePreviousApp()
  }
}
