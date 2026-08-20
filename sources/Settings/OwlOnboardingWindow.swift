//
//  OwlOnboardingWindow.swift
//  猫头鹰输入法 (Owltype) — SwiftUI onboarding / welcome window
//
//  v0.3.3: a 豆包-style first-run welcome window — a standard titled NSWindow
//  hosting `OwlOnboardingView` via NSHostingView. Shown on first launch and
//  openable from the IME status menu. Purely additive UI — it only forwards the
//  already-safe delegate actions (open System Settings / deploy / open settings).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the onboarding UI layer only; the
//  IMK key-event hot path (OwlInputController) is untouched.
//
//  Concurrency: not `@MainActor`-isolated (matches the non-isolated
//  `OwlPanel` / `IMKInputController`). The non-isolated delegate calls
//  `show(...)` on the main thread; marking this `@MainActor` would cause
//  isolation errors at the call site (mirrors `OwlSettingsWindow`).
//

import AppKit
import SwiftUI

/// First-run flag for the onboarding window. Get/set so the `"OwlOnboardingDone"`
/// UserDefaults key string has exactly one home (matching the single-key-home convention of
/// `OwlCandidatePanelSettings`).
/// Defaults to `false`, so the window auto-shows once on first launch.
enum OwlOnboarding {
  static var isDone: Bool {
    get { OwlDefaults.standard.bool(forKey: "OwlOnboardingDone") }
    set { OwlDefaults.standard.set(newValue, forKey: "OwlOnboardingDone") }
  }
}

final class OwlOnboardingWindow: NSWindowController {
  init() {
    let window = NSWindow(
      contentRect: NSRect(
        x: 0, y: 0,
        width: OwlOnboardingMetrics.width, height: OwlOnboardingMetrics.height),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("欢迎使用猫头鹰输入法", comment: "Owltype onboarding window title")
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Wire the view to the supplied callbacks and bring the window front. Reuses
  /// the existing window on subsequent calls; only the hosted root view is rebuilt
  /// so it picks up the latest closures.
  func show(
    onOpenSystemSettings: @escaping () -> Void,
    onSelectSchema: @escaping (String) -> Void,
    onOpenInputSettings: @escaping () -> Void,
    onFinish: @escaping () -> Void,
    isOwltypeEnabled: @escaping () -> Bool
  ) {
    let rootView = OwlOnboardingView(
      onOpenSystemSettings: onOpenSystemSettings,
      onSelectSchema: onSelectSchema,
      onOpenInputSettings: onOpenInputSettings,
      onFinish: onFinish,
      isOwltypeEnabled: isOwltypeEnabled
    )
    window?.contentView = NSHostingView(rootView: rootView)

    // Bring the app forward so the onboarding window is interactive even when the
    // IME runs as an accessory (the menu action originates from another app, and
    // the first-launch call happens before any app is frontmost).
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
