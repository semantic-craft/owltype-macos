import AppKit
import SwiftUI

struct OwlPickerRow: Identifiable, Equatable, Codable {
  let id: String
  let display: String
  let searchText: String

  init(id: String, display: String, searchText: String? = nil) {
    self.id = id
    self.display = display
    self.searchText = searchText ?? display
  }
}

extension OwlPickerRow {
  static func template(_ entry: OwlTemplateEntry) -> OwlPickerRow {
    OwlPickerRow(id: entry.id.uuidString, display: entry.title,
                 searchText: OwlTemplateStore.searchText(entry))
  }
}

enum OwlPickerSegment: String, CaseIterable {
  case phrase
  case prompt

  var label: String { self == .phrase ? "短语" : "提示词" }
}

struct OwlPickerPanelModel: Equatable, Codable {
  private(set) var rows: [OwlPickerRow]
  private(set) var query: String
  private(set) var selection: Int

  init(rows: [OwlPickerRow], query: String = "") {
    self.rows = rows
    self.query = query
    self.selection = rows.isEmpty ? -1 : 0
  }

  var visible: [OwlPickerRow] {
    OwlTemplateStore.core("picker_visible", ["model": OwlAppCore.payload(self)])
  }
  var isEmpty: Bool { visible.isEmpty }
  private struct Selection: Decodable { let row: OwlPickerRow? }
  var selectedRow: OwlPickerRow? {
    let value: Selection = OwlTemplateStore.core("picker_selected", ["model": OwlAppCore.payload(self)]); return value.row
  }
  func isSelected(_ index: Int) -> Bool { index == selection }
  private mutating func update(_ action: String, _ values: [String: Any]) {
    var args = values; args["action"] = action; args["model"] = OwlAppCore.payload(self)
    self = OwlTemplateStore.core("picker_update", args)
  }
  mutating func moveSelection(by delta: Int) { update("move", ["delta": delta]) }
  mutating func select(_ index: Int) { update("select", ["index": index]) }
  func row(forNumber number: Int) -> OwlPickerRow? {
    let value: Selection = OwlTemplateStore.core("picker_number", ["model": OwlAppCore.payload(self), "number": number]); return value.row
  }
  mutating func setQuery(_ newQuery: String) { update("query", ["query": newQuery]) }
}

final class OwlTemplatePickerPanel: NSPanel {
  var invocationHandler: ((OwlTemplateInvocation.Content, OwlPanelInsertionBroker, OwlTemplateInvocation.Intent) -> Void)?
  private var didPick = false
  private let broker = OwlPanelInsertionBroker()

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
      styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = false
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    standardWindowButton(.closeButton)?.isHidden = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    installContentView()
  }

  func showPanel(initialSegment: OwlPickerSegment = .phrase) {
    didPick = false
    broker.capture()
    installContentView(initialSegment: initialSegment)
    positionPanel()
    makeKeyAndOrderFront(nil)
  }

  func hidePanel() {
    broker.restoreFocus()
    orderOut(nil)
  }

  private func installContentView(initialSegment: OwlPickerSegment = .phrase) {
    let mode = OwlTemplateStore.mode()
    let entries = (try? OwlTemplateStore.load())?.entries ?? []
    let error: String?
    if case .unavailable(let message) = mode { error = message } else { error = nil }
    setContentSize(NSSize(width: 650, height: 450))
    contentView = NSHostingView(rootView: OwlTemplatePickerView(
      entries: error == nil ? entries : [], promptOnly: initialSegment == .prompt, error: error,
      onPick: { [weak self] in self?.invoke(.template($0)) },
      onPreview: { [weak self] in self?.invoke(.template($0), intent: .resultPreview) },
      onClose: { [weak self] in self?.hidePanel() }))
  }

  private func invoke(_ content: OwlTemplateInvocation.Content, intent: OwlTemplateInvocation.Intent = .insert) {
    guard !didPick else { return }
    didPick = true
    let captured = broker.transferCapture()
    orderOut(nil)
    if let invocationHandler {
      invocationHandler(content, captured, intent)
    } else {
      let invocation = OwlTemplateInvocation(content: content, broker: captured, deliver: nil, intent: intent)
      MainActor.assumeIsolated { OwlPromptFillSheet.shared.begin(invocation: invocation) }
    }
  }

  private func positionPanel() {
    let size = frame.size
    let anchor = NSApp.owlAppDelegate.currentHostCaretAnchor
    if anchor != .zero {
      setFrame(clampedFrame(anchor: anchor, size: size), display: false)
    } else {
      positionCenteredUnderMouse(size: size)
    }
  }

  private func clampedFrame(anchor: NSRect, size: NSSize) -> NSRect {
    OwlFloatingPanelPositioner.belowCaret(
      anchor: anchor, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      useVisibleFrame: false)
  }

  private func positionCenteredUnderMouse(size: NSSize) {
    guard let placed = OwlFloatingPanelPositioner.centeredUnder(
      point: NSEvent.mouseLocation, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }) else { return }
    setFrameOrigin(placed.origin)
  }
}

/// A single loaded value snapshot backs search, original-body preview and eventual invocation.
/// Previewing/highlighting performs no expansion, clipboard read or disk access.
struct OwlTemplatePickerView: View {
  let entries: [OwlTemplateEntry]
  let error: String?
  let onPick: (OwlTemplateEntry) -> Void
  let onPreview: (OwlTemplateEntry) -> Void
  let onClose: () -> Void
  @State private var promptOnly: Bool
  @State private var selectedTag: String?
  @State private var model: OwlPickerPanelModel
  @FocusState private var searchFocused: Bool

  init(entries: [OwlTemplateEntry], promptOnly: Bool, error: String? = nil,
       onPick: @escaping (OwlTemplateEntry) -> Void,
       onPreview: @escaping (OwlTemplateEntry) -> Void, onClose: @escaping () -> Void) {
    self.entries = OwlTemplateStore.sorted(entries)
    self.error = error
    self.onPick = onPick
    self.onPreview = onPreview
    self.onClose = onClose
    _promptOnly = State(initialValue: promptOnly)
    _model = State(initialValue: OwlPickerPanelModel(rows: OwlTemplateStore.sorted(entries)
      .filter { !promptOnly || $0.category == .prompt }.map(OwlPickerRow.template)))
  }

  private var selected: OwlTemplateEntry? {
    guard let row = model.selectedRow else { return nil }
    return entries.first { $0.id.uuidString == row.id }
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Picker("范围", selection: $promptOnly) {
          Text("全部片段").tag(false)
          Text("提示词").tag(true)
        }.pickerStyle(.segmented).frame(width: 200)
        Picker("标签", selection: $selectedTag) {
          Text("全部标签").tag(nil as String?)
          ForEach(OwlTemplateStore.tags(in: entries), id: \.self) { Text($0).tag(Optional($0)) }
        }.frame(maxWidth: 210)
        Spacer()
        Button("关闭", action: onClose)
      }
      TextField("搜索标题、正文、标签或触发词", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
        .focused($searchFocused).onSubmit { insertSelected() }.accessibilityIdentifier("template-search")
      if let error { Text(error).foregroundStyle(.red) }
      HStack(alignment: .top, spacing: 12) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, row in
              Button { model.select(index) } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(index < 9 ? String(index + 1) + "  " : "")\(row.display)").lineLimit(1)
                  if let entry = entries.first(where: { $0.id.uuidString == row.id }) {
                    if entry.isPinned { Text("置顶").font(.caption).foregroundStyle(.secondary) }
                    if let trigger = entry.trigger { Text(trigger).font(.caption).foregroundStyle(.secondary) }
                    if !entry.tags.isEmpty { Text(entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    Text(verbatim: entry.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                  .background(model.isSelected(index) ? Color.accentColor.opacity(0.16) : .clear)
              }.buttonStyle(.owlPlain)
            }
          }
        }.frame(width: 240)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("原文预览").font(.caption).foregroundStyle(.secondary)
          if let selected {
            Text(selected.title).font(.headline)
            if let issue = selected.executionIssue { Text(issue).font(.caption).foregroundStyle(.red) }
            ScrollView([.horizontal, .vertical]) {
              Text(verbatim: selected.body).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
            }.accessibilityIdentifier("template-full-preview")
          } else {
            Text(entries.isEmpty ? "在快捷片段设置中创建条目" : "无匹配条目")
            Spacer()
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      HStack {
        Text("↑↓ 选择 · 空搜索时 1–9 · ⏎ 插入 · Esc 取消").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("结果预览") {
          guard let selected, selected.executionIssue == nil else { return }
          onPreview(selected)
          onClose()
        }.disabled(selected == nil || selected?.executionIssue != nil)
          .accessibilityIdentifier("template-open-result-preview")
        Button("插入") { insertSelected() }.disabled(selected == nil || selected?.executionIssue != nil)
      }
    }.padding(14).frame(width: 650, height: 450).background(.regularMaterial)
      .onAppear { searchFocused = true }
      .onChange(of: promptOnly) { _, _ in refilter() }
      .onChange(of: selectedTag) { _, _ in refilter() }
      .onExitCommand(perform: onClose)
      .onKeyPress(phases: .down) { key in
        if key.key == .upArrow { model.moveSelection(by: -1); return .handled }
        if key.key == .downArrow { model.moveSelection(by: 1); return .handled }
        if model.query.isEmpty, let number = Int(key.characters), let row = model.row(forNumber: number),
           let entry = entries.first(where: { $0.id.uuidString == row.id }), entry.executionIssue == nil {
          onPick(entry); onClose(); return .handled
        }
        return .ignored
      }
  }

  private func refilter() {
    let selectedID = model.selectedRow?.id
    let rows = OwlTemplateStore.filtered(entries, tag: selectedTag, promptOnly: promptOnly).map(OwlPickerRow.template)
    model = OwlPickerPanelModel(rows: rows, query: model.query)
    if let index = model.visible.firstIndex(where: { $0.id == selectedID }) { model.select(index) }
    else { model.setQuery(model.query) }
  }

  private func insertSelected() {
    guard let selected, selected.executionIssue == nil else { return }
    onPick(selected)
    onClose()
  }
}
