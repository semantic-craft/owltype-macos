//
//  FamoOnboardingWindow.swift
//  法墨输入法 (Famo) — SwiftUI onboarding / welcome window
//
//  v0.3.3: a 豆包-style first-run welcome window — a standard titled NSWindow
//  hosting `FamoOnboardingView` via NSHostingView. Shown on first launch and
//  openable from the IME status menu. Purely additive UI — it only forwards the
//  already-safe delegate actions (open System Settings / deploy / open settings).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the onboarding UI layer only; the
//  IMK key-event hot path (FamoInputController) is untouched.
//
//  Concurrency: not `@MainActor`-isolated (matches the non-isolated
//  `FamoPanel` / `IMKInputController`). The non-isolated delegate calls
//  `show(...)` on the main thread; marking this `@MainActor` would cause
//  isolation errors at the call site (mirrors `FamoSettingsWindow`).
//

import AppKit
import SwiftUI

/// First-run flag for the onboarding window. Get/set so the `"FamoOnboardingDone"`
/// UserDefaults key string has exactly one home (matching the single-key-home
/// convention of `FamoSwiftUICandidatePanel.isEnabled` / `FamoPanelPreferences`).
/// Defaults to `false`, so the window auto-shows once on first launch.
enum FamoOnboarding {
  static var isDone: Bool {
    get { FamoDefaults.standard.bool(forKey: "FamoOnboardingDone") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoOnboardingDone") }
  }
}

final class FamoOnboardingWindow: NSWindowController {
  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("欢迎使用法墨输入法", comment: "Famo onboarding window title")
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
    isFamoEnabled: @escaping () -> Bool
  ) {
    let rootView = FamoOnboardingView(
      onOpenSystemSettings: onOpenSystemSettings,
      onSelectSchema: onSelectSchema,
      onOpenInputSettings: onOpenInputSettings,
      onFinish: onFinish,
      isFamoEnabled: isFamoEnabled
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
