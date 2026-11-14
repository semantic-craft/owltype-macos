//
//  OwlVoiceCapsulePanel.swift
//  Owltype — Voice Input Subsystem
//

import AppKit
import SwiftUI

@MainActor
class OwlVoiceCapsulePanel: OwlFloatingPanel {
  static let shared = OwlVoiceCapsulePanel()

  let viewModel = OwlVoiceCapsuleViewModel()
  private var hostingView: NSHostingView<OwlVoiceCapsuleView>?

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 44))

    ignoresMouseEvents = true
    let view = OwlVoiceCapsuleView(viewModel: viewModel)
    let hosting = NSHostingView(rootView: view)
    self.hostingView = hosting
    self.contentView = hosting
  }

  private var lastAnchor: NSRect = .zero

  func present(state: OwlVoiceCapsuleState, anchor: NSRect) {
    if anchor != .zero {
      lastAnchor = anchor
    }
    viewModel.state = state
    updateFrame(anchor: anchor)
    if !isVisible {
      orderFrontRegardless()
    }
  }

  func updateState(_ state: OwlVoiceCapsuleState, anchor: NSRect? = nil) {
    let effective = (anchor != nil && anchor != .zero) ? anchor! : lastAnchor
    present(state: state, anchor: effective)
  }

  func dismiss() {
    orderOut(nil)
    viewModel.state = .idle
    lastAnchor = .zero
  }

  func updateFrame(anchor: NSRect, animated: Bool = true) {
    hostingView?.layoutSubtreeIfNeeded()
    let size = hostingView?.fittingSize ?? NSSize(width: 280, height: 44)
    let effectiveAnchor = (anchor != .zero) ? anchor : lastAnchor
    let targetFrame = Self.belowCaretFrame(anchor: effectiveAnchor, size: size) { visible in
      NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 64)
    }

    if animated && isVisible && !OwlDefaults.isRunningUnitTests {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animator().setFrame(targetFrame, display: true)
      }
    } else {
      setFrame(targetFrame, display: true)
    }
    invalidateShadow()
  }
}
