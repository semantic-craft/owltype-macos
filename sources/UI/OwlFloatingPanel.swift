import AppKit

class OwlFloatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(
    contentRect: NSRect,
    styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel],
    transparentChrome: Bool = true,
    collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  ) {
    super.init(
      contentRect: contentRect,
      styleMask: styleMask.union([.nonactivatingPanel]),
      backing: .buffered,
      defer: false
    )
    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    self.collectionBehavior = collectionBehavior
    if transparentChrome {
      isOpaque = false
      backgroundColor = .clear
      hasShadow = true
    }
  }

  static func reachableFrame(_ frame: NSRect, screens: [NSRect]) -> NSRect {
    guard let screen = screens.first(where: { $0.intersects(frame) }) ?? screens.first else { return frame }
    var result = frame
    result.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
    result.origin.y = min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - frame.height))
    return result
  }

  static func belowCaretFrame(
    anchor: NSRect,
    size: NSSize,
    fallbackOrigin: (_ visibleFrame: NSRect) -> NSPoint
  ) -> NSRect {
    if anchor == .zero {
      let mouseLoc = NSEvent.mouseLocation
      let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
      let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      return NSRect(origin: fallbackOrigin(visible), size: size)
    }
    return OwlFloatingPanelPositioner.belowCaret(
      anchor: anchor,
      size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      useVisibleFrame: true
    )
  }
}
