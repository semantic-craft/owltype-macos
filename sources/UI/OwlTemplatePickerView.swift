import SwiftUI

extension OwlPickerRow {
  static func template(_ entry: OwlTemplateEntry) -> OwlPickerRow {
    OwlPickerRow(id: entry.id.uuidString, display: entry.title,
                 searchText: OwlTemplateStore.searchText(entry))
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
          Text("全部").tag(false)
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
              }.buttonStyle(.plain)
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
            Text(entries.isEmpty ? "在快捷短语设置中创建条目" : "无匹配条目")
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
