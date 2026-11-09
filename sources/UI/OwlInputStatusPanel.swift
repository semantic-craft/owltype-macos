import AppKit
import SwiftUI

/// A single nonactivating surface follows the active IMK session, never a background controller.
@MainActor
final class OwlInputStatusPanel: OwlFloatingPanel {
  static let shared = OwlInputStatusPanel()
  static let enabledKey = "OwlInputStatusPanelEnabled"
  private weak var owner: OwlInputController?
  private var lastPresentation: Presentation?
  private var settings = OwlCandidatePanelSettings.live.snapshot()
  private var screenObserver: NSObjectProtocol?

  struct Presentation: Equatable {
    let schema: String
    let ascii: Bool
    let punctuation: Bool
    let fullShape: Bool
    let traditional: Bool
    let settings: OwlCandidatePanelSettings.Snapshot
  }

  var isEnabled: Bool { OwlDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

  private init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 48))
    isMovableByWindowBackground = true
    setFrameAutosaveName("OwlInputStatusPanel")
    if !setFrameUsingName("OwlInputStatusPanel"), let screen = NSScreen.main {
      setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 24,
                             y: screen.visibleFrame.minY + 24))
    }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.keepOnScreen() } }
  }

  func activate(_ controller: OwlInputController) {
    owner = controller
    settings = OwlCandidatePanelSettings.live.snapshot()
    lastPresentation = nil
    refresh(controller)
  }

  func deactivate(_ controller: OwlInputController) {
    guard owner === controller else { return }
    owner = nil
    lastPresentation = nil
    orderOut(nil)
  }

  func toggleVisibility(_ controller: OwlInputController) {
    OwlDefaults.standard.set(!isEnabled, forKey: Self.enabledKey)
    if isEnabled { activate(controller) } else { orderOut(nil) }
  }

  func refreshPreferences() {
    settings = OwlCandidatePanelSettings.live.snapshot()
    if let owner { refresh(owner) }
  }

  func refresh(_ controller: OwlInputController) {
    guard owner === controller, isEnabled else { return }
    let flags = controller.currentEngineStatusFlags()
    let schema = controller.schemaId.isEmpty ? OwlKeyboardPreferences.preferredSchemaID : controller.schemaId
    let value = Presentation(schema: schema, ascii: flags.asciiMode, punctuation: flags.asciiPunct,
                             fullShape: flags.fullShape, traditional: flags.traditional,
                             settings: settings)
    if value != lastPresentation {
      lastPresentation = value
      switch value.settings.appearance {
      case .system: appearance = nil
      case .light: appearance = NSAppearance(named: .aqua)
      case .dark: appearance = NSAppearance(named: .darkAqua)
      }
      let view = OwlInputStatusView(presentation: value, action: { [weak self, weak controller] action in
        guard let self, let controller, self.owner === controller else { return }
        switch action {
        case .language: controller.toggleASCIIModeFromMenu()
        case .punctuation: controller.toggleASCIIPunctuationFromMenu()
        case .width: controller.toggleFullShapeFromMenu()
        case .traditional: controller.toggleTraditionalInputFromMenu()
        case .settings: controller.showOwltypeSettings()
        case .schema: NSApp.owlAppDelegate.showSettings(selectedPage: .keyboard)
        case .hide: self.toggleVisibility(controller)
        }
      })
      let hosting = NSHostingView(rootView: view)
      contentView = hosting
      setContentSize(hosting.fittingSize)
    }
    keepOnScreen()
    if !isVisible { orderFrontRegardless() }
  }

  private func keepOnScreen() {
    let reachable = Self.reachableFrame(frame, screens: NSScreen.screens.map(\.visibleFrame))
    if reachable != frame { setFrame(reachable, display: true) }
  }
}

struct OwlInputStatusView: View {
  enum Action { case language, punctuation, width, traditional, settings, schema, hide }
  let presentation: OwlInputStatusPanel.Presentation
  let action: (Action) -> Void
  @Environment(\.colorScheme) private var colorScheme
  private var palette: OwlCandidatePalette { presentation.settings.skin.theme.palette(for: colorScheme) }

  var body: some View {
    HStack(spacing: 3) {
      StatusDragHandle().frame(width: 16, height: 32).help("拖动状态栏")
      button(schemaLabel, label: "输入方案：\(OwlRustSchemaMap.displayName(for: presentation.schema))；打开键盘设置", action: .schema)
      Rectangle().fill(palette.ink.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4)
      button(presentation.ascii ? "英" : "中", label: presentation.ascii ? "英文输入；切换中文" : "中文输入；切换英文", action: .language, accent: true)
      button(presentation.punctuation ? "." : "。", label: presentation.punctuation ? "英文标点；切换中文标点" : "中文标点；切换英文标点", action: .punctuation)
      button(presentation.fullShape ? "全" : "半", label: presentation.fullShape ? "全角；切换半角" : "半角；切换全角", action: .width)
      button(presentation.traditional ? "繁" : "简", label: presentation.traditional ? "繁体输出；切换简体" : "简体输出；切换繁体", action: .traditional)
      Button { action(.settings) } label: {
        Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 32, height: 32)
      }.buttonStyle(StatusButtonStyle(palette: palette)).help("Owltype 设置").accessibilityLabel("Owltype 设置")
    }
    .padding(7)
    .background(RoundedRectangle(cornerRadius: presentation.settings.skin.theme.cornerRadius).fill(palette.card))
    .overlay(RoundedRectangle(cornerRadius: presentation.settings.skin.theme.cornerRadius)
      .strokeBorder(palette.accentDeep.opacity(0.18), lineWidth: 1))
    .contextMenu { Button("隐藏状态栏（可从输入法菜单恢复）") { action(.hide) } }
    .fixedSize()
  }

  private var schemaLabel: String {
    if presentation.schema.hasPrefix("wubi") { return presentation.schema.contains("pinyin") ? "五拼" : "五笔" }
    if presentation.schema.hasPrefix("double_pinyin") { return "双拼" }
    if presentation.schema == "melt_eng" { return "英文" }
    if ["rime_ice", "pinyin_simp"].contains(presentation.schema) { return "拼音" }
    return String(OwlRustSchemaMap.displayName(for: presentation.schema).prefix(4))
  }

  private func button(_ text: String, label: String, action selected: Action, accent: Bool = false) -> some View {
    Button { action(selected) } label: {
      Text(text).font(.system(size: 15, weight: .medium))
        .foregroundStyle(accent ? palette.accent : palette.ink)
        .frame(minWidth: 32, minHeight: 32)
        .padding(.horizontal, text.count > 1 ? 4 : 0)
    }.buttonStyle(StatusButtonStyle(palette: palette)).help(label).accessibilityLabel(label)
  }
}

private struct StatusButtonStyle: ButtonStyle {
  let palette: OwlCandidatePalette
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(palette.ink)
      .background(RoundedRectangle(cornerRadius: 7)
        .fill(configuration.isPressed ? palette.accent.opacity(0.16) : Color.clear))
      .contentShape(RoundedRectangle(cornerRadius: 7))
  }
}

private struct StatusDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> Handle { Handle() }
  func updateNSView(_ nsView: Handle, context: Context) {}

  final class Handle: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.tertiaryLabelColor.setFill()
      for x in [5.0, 10.0] {
        for y in [11.0, 16.0, 21.0] {
          NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
        }
      }
    }
  }
}
