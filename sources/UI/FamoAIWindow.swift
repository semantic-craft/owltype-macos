//
//  FamoAIWindow.swift
//  法墨输入法 (Famo) — AI conversation window (roadmap B10, v1)
//
//  A small Famo-owned chat window that already knows the user's current composition context.
//  azooKey-style lifecycle: a SINGLE reused instance (`isReleasedWhenClosed = false`), takes key
//  focus for its question field (`canBecomeKey = true`) but captures the frontmost app BEFORE
//  showing and restores it on EVERY close path (submit-done / cancel / Esc / close). All stored
//  callbacks are `[weak self]` and nilled in `close()` so the window↔model retain cycle is broken.
//
//  The window is COPY-ONLY: the streamed answer is never auto-inserted into the target app and there
//  is no replace-selection. Opening / using it never mutates the librime session or the composition
//  — it only reads the captured snapshot (already a plain value) and talks to the cloud provider.
//
//  Boundary: SwiftUI is the sole renderer (the view is hosted via `NSHostingView`); the IMK
//  key-event hot path is untouched. AppKit window lifecycle is not headless-unit-testable, so the
//  view model + assembler (both fully tested) are the safety net; this file is intentionally thin.
//
//  Concurrency: not `@MainActor`-isolated at the class level (mirrors `FamoSettingsWindow` /
//  `FamoSwiftUICandidatePanel`); the non-isolated controller calls `show(...)` on the main thread.
//

import AppKit
import SwiftUI

final class FamoAIWindow: NSWindowController {
  /// The single reused window instance (azooKey lifecycle). Held here rather than on
  /// `FamoApplicationDelegate` so the B10 trigger touches NO shared controller/delegate file — only
  /// this new file + one `+Menu.swift` line. Created lazily on first AI-window trigger; reused
  /// across triggers (each `show` captures a fresh snapshot). Main-thread only (the menu action
  /// originates on the main thread), so a non-atomic static is safe.
  @MainActor static let shared = FamoAIWindow()

  /// Strong reference to the view model so it lives as long as the window. Recreated per `show`
  /// (each trigger captures a fresh snapshot).
  private var model: FamoAIConversationModel?
  /// The app that was frontmost BEFORE we showed (so we can restore focus to it on close).
  private weak var previousApp: NSRunningApplication?

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // Keep the title for a11y / the Window menu, but hide it and let the SwiftUI paper flow under a
    // transparent titlebar (方案 C) — no duplicate "法墨 AI 对话" over the content header.
    window.title = NSLocalizedString("法墨 AI 对话", comment: "Famo AI conversation window title")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 420, height: 360)
    window.level = .floating
    window.center()
    // 可 resize 后记住用户调过的尺寸/位置（首开仍居中；有存档则存档优先）。
    window.setFrameAutosaveName("FamoAIConversationWindow")
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Build (or reuse) the window with an optional, user-explicit selected-text payload, then bring
  /// it front. With no selection, the window opens for a general question.
  @discardableResult
  func show(
    selectedText: String? = nil,
    initialQuestion: String = "",
    initialDisplayQuestion: String? = nil,
    autoSubmit: Bool = false,
    composerTask: FamoAIComposerTask? = nil,
    initialState: FamoAIConversationState = .idle
  ) -> FamoAIConversationModel {
    previousApp = NSWorkspace.shared.frontmostApplication

    let model = FamoAIConversationModel(
      selectedText: selectedText,
      initialState: initialState
    )
    self.model = model

    let rootView = FamoAIConversationView(
      model: model,
      initialQuestion: initialQuestion,
      initialDisplayQuestion: initialDisplayQuestion,
      autoSubmit: autoSubmit,
      initialTask: composerTask,
      onCopy: { [weak self] text in self?.copy(text) },
      onClose: { [weak self] in self?.window?.close() }
    )
    window?.contentView = NSHostingView(rootView: rootView)

    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    return model
  }

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

extension FamoAIWindow: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // Cancel any in-flight stream and drop the model's callback retain BEFORE restoring focus, so
    // the window↔model cycle is broken on every close path (button / Esc / red traffic light).
    model?.teardown()
    model = nil
    restorePreviousApp()
  }
}
