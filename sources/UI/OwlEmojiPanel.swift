//
//  OwlEmojiPanel.swift
//  猫头鹰输入法 (Owltype) — 表情/符号面板 host
//
//  A floating NSPanel hosting `OwlEmojiPanelView`. NON-activating and NOT key-capable —
//  so summoning it never steals focus from the host document, which keeps the active IME
//  session (and its `client`) alive. That is what lets a pick INSERT at the cursor: the
//  input controller summons this panel and points `pickHandler` at its `commit(string:)`,
//  which calls `client.insertText`. When summoned from the 表情符号 settings page (no
//  document client), `pickHandler` is nil and a pick falls back to copying to the pasteboard.
//
//  Trade-off (ADR / task 06-16-imk-client-insert, decision Q1=A): a non-key panel cannot
//  focus a text field, so in-panel keyboard search is dropped in favor of category browse.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI UI layer only; the IMK key-event hot path
//  (OwlInputController) is untouched — we only ADD a caller of the existing
//  `commit(string:)`, never modify handle/process_key/setMarkedText/insertText/commit.
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the Owltype panels); the
//  non-isolated delegate creates/shows it on the main thread.
//

import AppKit
import SwiftUI

final class OwlEmojiPanel: NSPanel {
  /// Where a picked glyph goes. Set by the input controller to insert at the cursor
  /// (`commit(string:)`); left nil when shown from settings → falls back to the pasteboard.
  /// Re-assigned on every show so the panel can be a reused singleton across triggers.
  var pickHandler: ((String) -> Void)?

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 372, height: 318),
      styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    // NOT movable-by-background: with it on, AppKit's window-drag machinery swallows
    // mouseDown on non-control SwiftUI views (our glyph cells are Text + .onTapGesture,
    // not Buttons), so picking a glyph silently did nothing ("选字没有"). Off → every
    // tap lands. The panel is centered on show; drag-to-move isn't needed in v1.
    isMovableByWindowBackground = false
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    standardWindowButton(.closeButton)?.isHidden = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    contentView = NSHostingView(
      rootView: OwlEmojiPanelView(
        onPick: { [weak self] char in self?.handlePick(char) },
        onClose: { [weak self] in self?.hidePanel() }
      )
    )
  }

  // NOT key-capable: a key panel would steal focus from the host document and deactivate
  // the IME session (client → nil), breaking insertion. Non-key still receives mouse
  // clicks, which is all picking needs.
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Center on the screen under the mouse and order front WITHOUT activating Owltype or
  /// becoming key, so the host document keeps focus and its IME `client` stays alive.
  func showPanel() {
    if let placed = OwlFloatingPanelPositioner.centeredUnder(
      point: NSEvent.mouseLocation, size: frame.size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }) {
      setFrameOrigin(placed.origin)
    }
    orderFrontRegardless()
  }

  func hidePanel() {
    orderOut(nil)
  }

  /// Route a pick to the controller's inserter when set, else copy to the pasteboard.
  private func handlePick(_ char: String) {
    if let pickHandler {
      pickHandler(char)
    } else {
      copyToPasteboard(char)
    }
  }

  /// Fallback insert mechanism (settings trigger): copy to the general pasteboard.
  private func copyToPasteboard(_ char: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(char, forType: .string)
  }
}
