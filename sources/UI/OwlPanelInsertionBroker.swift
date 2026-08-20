//
//  OwlPanelInsertionBroker.swift
//  法墨输入法 (Owltype) — panel focus capture / restore
//
//  The non-activating picker panels (quick-send, prompt fill sheet) must hand focus back to the
//  host document BEFORE inserting, and must NEVER call `NSApp.activate` (that deactivates Owltype and
//  nils the IMK `client`, breaking insertion). This broker concentrates that choreography —
//  capture the frontmost app on show, restore-first on pick, idempotent clear, drop-without-restore,
//  pasteboard fallback — that was copy-pasted across those panels. The actual text insertion stays
//  with the caller (the controller's captured-client path / `+ClientAction`); the broker delegates.
//
//  Boundary: focus + fallback only. The frontmost-app read and the pasteboard write are injected
//  (defaults hit NSWorkspace / NSPasteboard) so capture→restore→deliver is unit-testable with spies.
//

import AppKit

/// Produces the "restore focus" action for the captured frontmost app, or `nil` when there is none.
/// The default reads `NSWorkspace.shared.frontmostApplication` and returns a thunk that reactivates
/// it *weakly* — a quit host neither leaks nor is force-held (matching the panels' old `weak var`).
/// Tests inject a spy that records activation.
typealias OwlFrontmostCapture = () -> (() -> Void)?

final class OwlPanelInsertionBroker {
  private let captureFrontmost: OwlFrontmostCapture
  private let pasteboardWrite: (String) -> Void
  private var restore: (() -> Void)?

  init(captureFrontmost: @escaping OwlFrontmostCapture = {
         guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
         return { [weak app] in app?.activate(options: []) }
       },
       pasteboardWrite: @escaping (String) -> Void = { text in
         NSPasteboard.general.clearContents()
         NSPasteboard.general.setString(text, forType: .string)
       }) {
    self.captureFrontmost = captureFrontmost
    self.pasteboardWrite = pasteboardWrite
  }

  /// Remember the app that is frontmost right now, so a later pick can hand focus back to it.
  func capture() { restore = captureFrontmost() }

  /// Reactivate the captured host and clear the reference. Idempotent (a following call is a no-op),
  /// so a pick-then-hide can't double-activate. NEVER `NSApp.activate` — that nils the IMK client.
  func restoreFocus() {
    restore?()
    restore = nil
  }

  /// Forget the captured host WITHOUT reactivating it (re-present case: another panel is about to
  /// take over, so we neither restore focus nor leave a stale reference).
  func drop() { restore = nil }

  /// Restore host focus, then deliver `text`: through `host` (the caller's captured-client inserter)
  /// when wired, else copy to the pasteboard. Restore always happens first so the insert lands in
  /// the host field. Mirrors the panels' "restore → callback / fallback" order.
  func restoreAndDeliver(_ text: String, host: ((String) -> Void)?) {
    restoreFocus()
    if let host {
      host(text)
    } else {
      pasteboardWrite(text)
    }
  }
}
