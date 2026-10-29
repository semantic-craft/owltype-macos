import AppKit

/// Application restoration is necessary but not sufficient: the delivery adapter separately
/// validates the original field. No automatic clipboard fallback, key events or repeat delivery.
final class OwlPanelInsertionBroker {
  struct FocusTarget {
    let restore: () -> Void
    let isRestored: () -> Bool
  }
  typealias Capture = () -> FocusTarget?
  private let captureFrontmost: Capture
  private let pasteboardWrite: (String) -> Bool
  private let schedule: (TimeInterval, @escaping () -> Void) -> Void
  private var target: FocusTarget?
  private var captureAttempted = false

  init(
    captureFrontmost: @escaping Capture = {
      guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
      return FocusTarget(restore: {
        guard !app.isTerminated else { return }
        app.activate(options: [])
      }, isRestored: { !app.isTerminated && app.isActive })
    },
    pasteboardWrite: @escaping (String) -> Bool = { text in
      NSPasteboard.general.clearContents()
      return NSPasteboard.general.setString(text, forType: .string)
    },
    schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
  ) {
    self.captureFrontmost = captureFrontmost
    self.pasteboardWrite = pasteboardWrite
    self.schedule = schedule
  }

  func capture() { captureAttempted = true; target = captureFrontmost() }

  func transferCapture() -> OwlPanelInsertionBroker {
    let next = OwlPanelInsertionBroker(captureFrontmost: captureFrontmost,
      pasteboardWrite: pasteboardWrite, schedule: schedule)
    next.target = target
    next.captureAttempted = captureAttempted
    drop()
    return next
  }

  func restoreFocus() {
    let captured = target
    drop()
    captured?.restore()
  }

  func drop() { target = nil; captureAttempted = false }

  /// Only the explicit Copy Result action calls this method, after context has been frozen.
  func copyResult(_ result: OwlTemplateInvocation.Result) -> Bool { pasteboardWrite(result.text) }

  func restoreAndDeliver(_ result: OwlTemplateInvocation.Result,
                         host: OwlTemplateInvocation.HostDelivery?,
                         isHostReady: @escaping () -> Bool = { true },
                         isPending: @escaping () -> Bool,
                         completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    let captured = target
    let neededCapture = captureAttempted
    drop()
    guard let host else { completion(.notAttempted(.missingHost)); return }
    guard !neededCapture || captured != nil else { completion(.notAttempted(.missingHost)); return }
    // Direct active-session calls never opened a window and require no activation request.
    guard let captured else {
      if isPending() { host(result, completion) }
      return
    }
    guard isPending() else { return }
    captured.restore()
    awaitRestoration(captured, remaining: Self.restorationPolls, isHostReady: isHostReady, isPending: isPending) { restored in
      guard isPending() else { return }
      // The application is back but its field never verified: the host refuses without writing
      // and names its own reason. Only an application that never came back is a focus failure.
      if restored || captured.isRestored() { host(result, completion) } else { completion(.notAttempted(.focusNotRestored)) }
    }
  }

  /// 25 ms polls. The host's input session can return after the application reports active.
  static let restorationPolls = 40

  private func awaitRestoration(_ captured: FocusTarget, remaining: Int,
                                isHostReady: @escaping () -> Bool, isPending: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
    guard isPending() else { return }
    if captured.isRestored() && isHostReady() { completion(true); return }
    guard remaining > 0 else { completion(false); return }
    schedule(0.025) { [self] in
      awaitRestoration(captured, remaining: remaining - 1, isHostReady: isHostReady, isPending: isPending, completion: completion)
    }
  }
}
