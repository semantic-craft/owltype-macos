//
//  OwlFloatingPanelPositioner.swift
//  法墨输入法 (Owltype) — floating-panel screen geometry
//
//  Pure CoreGraphics placement math shared by the floating panels (candidate / quick-send /
//  status HUD / emoji). Extracted from four near-identical `clampedFrame` + centre-under-mouse
//  copies so the multi-display caret math lives — and is unit-tested — in one place.
//
//  Boundary (ADR-0001 / 0002): geometry only. No AppKit windows, no NSScreen, no side effects —
//  screens are injected as plain rects, so this is testable with fabricated displays. The panels
//  stay the sole owners of `NSPanel.setFrame`; they call in here only for the *where*.
//
//  Mirrors `OwlCandidateAnchor` (the anchor-validation half of the same job): both are pure
//  value namespaces the panels delegate their screen math to.
//

import CoreGraphics

enum OwlFloatingPanelPositioner {

  /// A display's two rects. `frame` is the whole display; `visibleFrame` excludes the menu bar / Dock.
  /// Callers build these from `NSScreen` (`.init(frame: $0.frame, visibleFrame: $0.visibleFrame)`);
  /// tests fabricate them.
  struct Screen {
    let frame: CGRect
    let visibleFrame: CGRect
  }

  /// Place a panel of `size` below the caret `anchor`, clamped onto the screen holding the anchor.
  ///
  /// Squirrel-faithful cascade, ported verbatim from the candidate panel: below the caret by
  /// default → flipped above when it would fall off the screen bottom → left/right clamp → a final
  /// top re-clamp so a flipped-then-bottom-clamped tall panel can't end up above the screen top
  /// again. `useVisibleFrame` selects whether the screen is picked and clamped by the full `frame`
  /// (candidate / quick-send: a caret reported in the menu-bar/Dock band still resolves) or the
  /// `visibleFrame` (status HUD: a toast dodges the menu bar). The final re-clamp is a no-op for
  /// panels shorter than the screen, so it is behaviour-neutral for the HUD toast that omitted it.
  ///
  /// When `anchor.origin` is on no supplied screen the first screen is the last resort (upstream
  /// `OwlCandidateAnchor` filters off-screen anchors, so this is unreachable in practice).
  static func belowCaret(anchor: CGRect, size: CGSize,
                         screens: [Screen], useVisibleFrame: Bool) -> CGRect {
    let rectFor: (Screen) -> CGRect = { useVisibleFrame ? $0.visibleFrame : $0.frame }
    let bounds = (screens.first { rectFor($0).contains(anchor.origin) } ?? screens.first)
      .map(rectFor) ?? .zero

    var x = anchor.minX
    var y = anchor.minY - size.height - 6

    if x + size.width > bounds.maxX { x = bounds.maxX - size.width - 6 }
    if x < bounds.minX { x = bounds.minX + 6 }
    if y < bounds.minY { y = anchor.maxY + 6 }                     // off the bottom → flip above
    if y + size.height > bounds.maxY { y = bounds.maxY - size.height - 6 }
    if y < bounds.minY { y = bounds.minY + 6 }                     // final safety re-clamp

    return CGRect(x: x, y: y, width: size.width, height: size.height)
  }

  /// Centre a panel of `size` on the visible area of the screen under `point` (the mouse location).
  /// Ported from the emoji panel / quick-send no-caret fallback: the screen is picked by full
  /// `frame` (so the mouse always lands on a display) but the panel is centred within its
  /// `visibleFrame`. Returns `nil` when no screen is supplied (callers then leave the panel put).
  static func centeredUnder(point: CGPoint, size: CGSize, screens: [Screen]) -> CGRect? {
    guard let screen = screens.first(where: { $0.frame.contains(point) }) ?? screens.first else {
      return nil
    }
    let visible = screen.visibleFrame
    return CGRect(x: visible.midX - size.width / 2,
                  y: visible.midY - size.height / 2,
                  width: size.width, height: size.height)
  }
}
