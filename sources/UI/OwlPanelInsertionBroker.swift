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
  private var core = try! OwlAppSession("focus")

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

  func capture() { let _: Bool = core.call("capture"); target = captureFrontmost() }

  func transferCapture() -> OwlPanelInsertionBroker {
    let next = OwlPanelInsertionBroker(captureFrontmost: captureFrontmost,
      pasteboardWrite: pasteboardWrite, schedule: schedule)
    next.target = target
    next.core = core
    core = try! OwlAppSession("focus")
    target = nil
    return next
  }

  func restoreFocus() {
    let captured = target
    target = nil
    let restore: Bool = core.call("restore", ["target": captured != nil])
    if restore { captured?.restore() }
  }

  func drop() { target = nil; let _: Bool = core.call("drop") }

  /// Only the explicit Copy Result action calls this method, after context has been frozen.
  func copyResult(_ result: OwlTemplateInvocation.Result) -> Bool { pasteboardWrite(result.text) }

  func restoreAndDeliver(_ result: OwlTemplateInvocation.Result,
                         host: OwlTemplateInvocation.HostDelivery?,
                         isHostReady: @escaping () -> Bool = { true },
                         isPending: @escaping () -> Bool,
                         completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    let captured = target
    target = nil
    let session = core
    let effect: Effect = session.call("begin", ["host": host != nil, "target": captured != nil, "pending": isPending()])
    execute(effect, session: session, target: captured, result: result, host: host,
      isHostReady: isHostReady, isPending: isPending, completion: completion)
  }

  private struct Effect: Decodable { let action: String; let token: UInt64 }

  private func execute(_ effect: Effect, session: OwlAppSession, target: FocusTarget?, result: OwlTemplateInvocation.Result,
                       host: OwlTemplateInvocation.HostDelivery?, isHostReady: @escaping () -> Bool,
                       isPending: @escaping () -> Bool, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    let poll = { [self] in
      let pendingBeforeRead = isPending()
      let restored = pendingBeforeRead && target?.isRestored() == true
      let ready = restored && isHostReady()
      // Native readiness may reenter/cancel. Send the final pending fact after those reads.
      let next: Effect = session.call("poll", ["token": effect.token, "pending": isPending(),
        "restored": restored, "ready": ready])
      execute(next, session: session, target: target, result: result, host: host,
        isHostReady: isHostReady, isPending: isPending, completion: completion)
    }
    switch effect.action {
    case "restore": target?.restore(); poll()
    case "wait": schedule(0.025, poll)
    case "dispatch": host?(result, completion)
    case "missing": completion(.notAttempted(.missingHost))
    case "focusNotRestored": completion(.notAttempted(.focusNotRestored))
    default: break
    }
  }
}
