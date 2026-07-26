//
//  FamoStatusHUD.swift
//  法墨输入法 (Famo) — SwiftUI status HUD (mode/schema toast)
//
//  The transient toast that briefly announces a mode/schema change (e.g. 中/英、
//  简/繁、方案切换). Reimplemented in SwiftUI to replace the legacy AppKit
//  FamoPanel.show(status:) path, so SwiftUI is the SOLE renderer (candidates +
//  status). It is NOT on the IMK hot path: it fires only on a Rime option/schema
//  notification (mode change), never per keystroke — so SwiftUI is fine here.
//
//  Styling: the `FamoThemes` design system (FamoSkin → FamoCandidateTheme palette,
//  Font.famoSerif), matching the SwiftUI candidate panel's look.
//
//  Positioning: caret-relative, mirroring FamoSwiftUICandidatePanel's clamping
//  (multi-display safe). The anchor is the last caret rect seen by the candidate
//  panel (the controller records it on every showPanel); when no composition has
//  happened yet, it falls back to the top-trailing corner of the active screen,
//  matching the old toast's "appears near where you're typing" behavior.
//
//  Duration: auto-dismiss after `FamoStatusHUD.showDuration` (≈1.2s — inlined here;
//  FamoTheme used to own this constant and is being deleted).
//
//  Boundary (ADR-0001 / 0002): UI layer only; no Rime / hot-path involvement.
//

import AppKit
import SwiftUI

/// How a mode/schema toast renders its long vs. short label. Mirrors the Rime
/// `style/status_message_type` config (long / short / mix). Pure value type so the
/// selection logic is unit-testable without any window.
enum FamoStatusMessageType: String, Sendable {
  case long, short, mix

  /// The display string for a status change, given its long + short labels.
  /// Reproduces the legacy `FamoPanel.updateStatus(long:short:)` selection exactly:
  ///   .mix   → short if present, else long
  ///   .long  → long
  ///   .short → short if present, else the first character of long, else ""
  func message(long longMessage: String, short shortMessage: String) -> String {
    switch self {
    case .mix:
      return shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      return longMessage
    case .short:
      if !shortMessage.isEmpty {
        return shortMessage
      } else if let initial = longMessage.first {
        return String(initial)
      } else {
        return ""
      }
    }
  }
}

/// Observable state for the status toast. Not `@MainActor`-isolated (matches the
/// candidate panel state); all access is on the main thread via the delegate.
@Observable
final class FamoStatusHUDState {
  var message: String = ""
  var theme: FamoCandidateTheme = .shenda
}

/// The SwiftUI toast view. A single pill with the mode/schema label, styled with the
/// chosen 皮肤 palette (glass card + accent text), honoring Reduce Transparency.
struct FamoStatusHUDView: View {
  @Bindable var state: FamoStatusHUDState

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  private var palette: FamoCandidatePalette { state.theme.palette(for: colorScheme) }
  private var panelBorder: Color { palette.accentDeep.opacity(0.16) }

  var body: some View {
    Text(state.message)
      .font(.famoSerif(size: 17, weight: .semibold))
      .foregroundStyle(palette.ink)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 18)
      .padding(.vertical, 11)
      .background { glass }
      .overlay {
        RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
          .strokeBorder(panelBorder, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous))
      // 投影不在这里画：SwiftUI 的 .shadow 不撑布局，而窗口尺寸 = contentView.fittingSize，
      // 模糊没有落点。改由 NSPanel 的 `hasShadow` 按内容 alpha 画（见下方 FamoStatusHUD.init）。
      .accessibilityLabel("状态 \(state.message)")
  }

  /// Half-transparent glass matching the candidate panel; opaque card under Reduce Transparency.
  @ViewBuilder private var glass: some View {
    let shape = RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.card)
    } else {
      ZStack {
        shape.fill(.regularMaterial)
        shape.fill(palette.card.opacity(0.85))
      }
    }
  }
}

/// Non-activating floating panel that hosts the SwiftUI status toast. Created lazily by
/// the delegate; never steals focus (matches FamoSwiftUICandidatePanel / FamoEmojiPanel).
final class FamoStatusHUD: NSPanel {
  /// Auto-dismiss interval (was `FamoTheme.showStatusDuration`; inlined here because
  /// FamoTheme is deleted — SwiftUI is the sole renderer).
  static let showDuration: Double = 1.2

  private let hudState = FamoStatusHUDState()
  private var dismissTimer: Timer?

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 44),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )

    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isFloatingPanel = true
    level = .floating
    // 同 FamoSwiftUICandidatePanel：窗口投影交给 AppKit。此前是 `false` + 视图层
    // `.shadow(radius:16, y:7)`，但窗口尺寸严格等于 `contentView.fittingSize`，那层模糊
    // 没有落点——toast 一直是没有投影的。
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    contentView = NSHostingView(rootView: FamoStatusHUDView(state: hudState))
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Show a mode/schema toast resolved from its long/short labels, anchored near the
  /// caret. `anchor` is the last caret rect from the candidate panel; `.zero` falls
  /// back to the active screen's top-trailing corner. Reproduces the legacy toast:
  /// pick the message per `messageType`, render, auto-dismiss after `showDuration`.
  func show(long longMessage: String, short shortMessage: String, messageType: FamoStatusMessageType, anchor: NSRect) {
    let message = messageType.message(long: longMessage, short: shortMessage)
    guard !message.isEmpty else { return }

    hudState.message = message
    // Honor the chosen 皮肤 (read live, same cadence as the candidate panel).
    hudState.theme = FamoSkinPreferences.skin.theme
    switch FamoPanelPreferences.appearance {
    case .system: self.appearance = nil
    case .light:  self.appearance = NSAppearance(named: .aqua)
    case .dark:   self.appearance = NSAppearance(named: .darkAqua)
    }

    contentView?.layoutSubtreeIfNeeded()
    let fittingSize = contentView?.fittingSize ?? NSSize(width: 120, height: 44)
    let newFrame = clampedFrame(anchor: anchor, size: fittingSize)
    let sizeChanged = newFrame.size != frame.size
    setFrame(newFrame, display: true)
    // 尺寸变了才重算窗口投影（toast 一秒一次、不在按键热路径上，但判据与候选窗保持一致）。
    if sizeChanged { invalidateShadow() }

    if !isVisible {
      orderFrontRegardless()
    }

    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.showDuration, repeats: false) { [weak self] _ in
      self?.hidePanel()
    }
  }

  func hidePanel() {
    dismissTimer?.invalidate()
    dismissTimer = nil
    orderOut(nil)
  }

  /// Keep the toast on-screen relative to the caret anchor, clamped to the screen that
  /// contains the anchor (multi-display safe). Mirrors FamoSwiftUICandidatePanel.clampedFrame.
  /// When `anchor` is `.zero` (no composition has positioned a caret yet), fall back to the
  /// active screen's top-trailing corner so the toast still appears in a sensible place.
  private func clampedFrame(anchor: NSRect, size: NSSize) -> NSRect {
    // No composition has positioned a caret yet → top-trailing corner of the anchor's screen
    // (HUD-specific; kept here, not in the shared positioner).
    if anchor == .zero {
      let screen = NSScreen.screens.first { $0.visibleFrame.contains(anchor.origin) } ?? NSScreen.main
      let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      return NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                    width: size.width, height: size.height)
    }
    // A toast dodges the menu bar → clamp against `visibleFrame` (`useVisibleFrame: true`).
    return FamoFloatingPanelPositioner.belowCaret(
      anchor: anchor, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      useVisibleFrame: true)
  }
}
