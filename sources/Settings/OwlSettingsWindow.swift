//
//  OwlSettingsWindow.swift
//  猫头鹰输入法 (Owltype) — SwiftUI settings window
//
//  v0.2: a standard titled NSWindow hosting `OwlSettingsView` via NSHostingView.
//  Opened from the IME status menu. Purely additive UI — it only forwards the
//  already-safe delegate actions (deploy / open folders / schema switch).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only; the
//  IMK key-event hot path (OwlInputController) is untouched.
//
//  Concurrency: not `@MainActor`-isolated (matches the non-isolated
//  `OwlPanel` / `IMKInputController`). The non-isolated delegate calls
//  `show(...)` on the main thread; marking this `@MainActor` would cause
//  isolation errors at the call site.
//

import AppKit
import SwiftUI

final class OwlSettingsWindow: NSWindowController {
  /// Strong reference to the observable state so it lives as long as the window.
  private var state: OwlSettingsState?

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("猫头鹰设置", comment: "Owltype Settings window title")
    window.isReleasedWhenClosed = false
    // Sidebar + detail need room; keep the sidebar usable when the user shrinks it.
    window.minSize = NSSize(width: 640, height: 460)
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Wire the view to the supplied state + callbacks and bring the window front.
  /// Reuses the existing window/content view on subsequent calls; only the
  /// hosted root view is rebuilt so it binds to the latest state snapshot.
  func show(
    state: OwlSettingsState,
    onSelectSchema: @escaping (String) -> Void,
    onRedeploy: @escaping () -> Bool,
    onApplyKeyboardConfigFast: @escaping () throws -> OwlKeyboardSettingsApplication.Outcome,
    onApplyFuzzyConfigFast: @escaping () throws -> OwlKeyboardSettingsApplication.Outcome,
    onSyncUserData: @escaping () -> Void,
    onResetUserDict: @escaping () -> Void,
    onChooseSyncDirectory: @escaping () -> Void,
    onOpenRimeFolder: @escaping () -> Void,
    onOpenLog: @escaping () -> Void,
    onShowOnboarding: @escaping () -> Void,
    onPanelPreferencesChanged: @escaping () -> Void
  ) {
    self.state = state

    let rootView = OwlSettingsView(
      state: state,
      onSelectSchema: onSelectSchema,
      onRedeploy: onRedeploy,
      onApplyKeyboardConfigFast: onApplyKeyboardConfigFast,
      onApplyFuzzyConfigFast: onApplyFuzzyConfigFast,
      onSyncUserData: onSyncUserData,
      onResetUserDict: onResetUserDict,
      onChooseSyncDirectory: onChooseSyncDirectory,
      onOpenRimeFolder: onOpenRimeFolder,
      onOpenLog: onOpenLog,
      onShowOnboarding: onShowOnboarding,
      onPanelPreferencesChanged: onPanelPreferencesChanged
    )
    // NavigationSplitView installs a native toolbar. Constrain the hosting surface to
    // AppKit's actual content layout guide, which updates with toolbar/titlebar size;
    // otherwise detail pages can start underneath the toolbar material.
    if let window {
      let container = NSView()
      let hosting = NSHostingView(rootView: rootView)
      hosting.translatesAutoresizingMaskIntoConstraints = false
      window.contentView = container
      container.addSubview(hosting)
      let guide = (window.contentLayoutGuide as? NSLayoutGuide) ?? container.safeAreaLayoutGuide
      NSLayoutConstraint.activate([
        hosting.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
        hosting.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        hosting.topAnchor.constraint(equalTo: guide.topAnchor),
        hosting.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
      ])
    }

    // LSUIElement apps have no main menu, so AppKit never translates ⌘C/⌘V/⌘X/⌘A
    // (and ⌘Z) into the standard `copy:`/`paste:`/… responder-chain actions — which
    // makes those shortcuts dead in the settings window's text fields (e.g. the
    // DeepSeek API Key SecureField). Install a minimal Edit menu so they work while
    // the settings window is key. Idempotent; harmless to leave set when the app
    // reverts to `.accessory` (no menu bar shows without an active titled window).
    Self.installMainMenuIfNeeded()

    // Bring the app forward so the settings window is interactive even when the
    // IME runs as an accessory (the menu action originates from another app).
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  /// Build a minimal standard main menu (App + Edit) once and assign it to
  /// `NSApp.mainMenu`. The Edit items use the standard first-responder selectors
  /// with `target = nil`, so ⌘C/⌘V/⌘X/⌘A/⌘Z dispatch down the responder chain to
  /// the focused text field / field editor. No-op once a main menu is installed.
  static func installMainMenuIfNeeded() {
    guard NSApp.mainMenu == nil else { return }

    let mainMenu = NSMenu()

    // App menu: 关闭窗口 (⌘W) + 退出猫头鹰 (⌘Q). The Edit menu is the must-have; this
    // is a tiny courtesy so the window has the standard close/quit shortcuts too.
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: NSLocalizedString("关闭窗口", comment: "Close window menu item"),
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    appMenu.addItem(.separator())
    let quitItem = appMenu.addItem(
      withTitle: NSLocalizedString("退出猫头鹰", comment: "Quit Owltype menu item"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quitItem.target = NSApp
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // Edit menu: the standard editing actions, all with `target = nil` so they
    // dispatch down the responder chain to the focused field editor.
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: NSLocalizedString("编辑", comment: "Edit menu title"))
    editMenu.addItem(
      withTitle: NSLocalizedString("撤销", comment: "Undo menu item"),
      action: Selector(("undo:")),
      keyEquivalent: "z"
    )
    let redoItem = editMenu.addItem(
      withTitle: NSLocalizedString("重做", comment: "Redo menu item"),
      action: Selector(("redo:")),
      keyEquivalent: "z"
    )
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(
      withTitle: NSLocalizedString("剪切", comment: "Cut menu item"),
      action: #selector(NSText.cut(_:)),
      keyEquivalent: "x"
    )
    editMenu.addItem(
      withTitle: NSLocalizedString("复制", comment: "Copy menu item"),
      action: #selector(NSText.copy(_:)),
      keyEquivalent: "c"
    )
    editMenu.addItem(
      withTitle: NSLocalizedString("粘贴", comment: "Paste menu item"),
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    editMenu.addItem(
      withTitle: NSLocalizedString("全选", comment: "Select All menu item"),
      action: #selector(NSResponder.selectAll(_:)),
      keyEquivalent: "a"
    )
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    NSApp.mainMenu = mainMenu
  }
}
