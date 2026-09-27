import SwiftUI

struct OwlTemplateRestoreView: View {
  @State var preview: OwlTemplateBackup.Preview
  let onRestore: (OwlTemplateBackup.Preview) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var error = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("恢复原生备份").font(.title2)
      Text("新增 \(count(.new)) · 同 ID 更新 \(count(.update)) · 完全相同 \(count(.identical))")
      Text("默认保留当前条目。同 ID 更新需逐项选择；当前库中其他条目不会被删除。提交前会备份整个当前库。")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(preview.rows.indices, id: \.self) { index in
            row(at: index)
            Divider()
          }
        }
      }
      if !preview.conflicts.isEmpty {
        Text("生效触发词或候选别名冲突：" + preview.conflicts.joined(separator: "、"))
          .foregroundStyle(.red).textSelection(.enabled)
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      HStack {
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("恢复所选 \(preview.selectedCount) 项") {
          do { try onRestore(preview); dismiss() }
          catch { self.error = error.localizedDescription }
        }.disabled(preview.selectedCount == 0 || !preview.conflicts.isEmpty).keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(minWidth: 520, idealWidth: 660, minHeight: 400, idealHeight: 560)
  }

  private func count(_ kind: OwlTemplateBackup.Kind) -> Int { preview.rows.filter { $0.kind == kind }.count }

  private func row(at index: Int) -> some View {
    let row = preview.rows[index]
    return VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: $preview.rows[index].selected) {
        Text(row.entry.title + " · " + label(row.kind))
      }.disabled(row.kind == .identical)
      Text(String(row.id.uuidString.prefix(8)) + " · " + row.entry.tags.joined(separator: "、"))
        .font(.caption).foregroundStyle(.secondary)
      if row.selected && row.kind != .identical {
        HStack {
          TextField("触发词（留空为仅搜索）", text: Binding(get: { preview.rows[index].entry.trigger ?? "" }, set: {
            preview.changeTrigger(id: row.id, to: $0)
          }))
          Button("仅搜索") { preview.makeSearchOnly(id: row.id) }
        }
        if !row.entry.candidateAliases.isEmpty { Text("候选别名：" + row.entry.candidateAliases.joined(separator: "、")).font(.caption) }
      }
      DisclosureGroup("核对完整内容与设置") {
        if let current = row.current {
          Text("当前条目").font(.headline)
          details(current)
          Divider()
        }
        Text("备份条目（含本次调整）").font(.headline)
        details(row.entry)
      }
    }
  }

  private func details(_ entry: OwlTemplateEntry) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: entry.body).font(.system(.body, design: .monospaced)).textSelection(.enabled)
      // The same encoder exposes every persisted setting, including future shared model fields.
      if let data = try? OwlTemplateStore.encoded(.init(entries: [entry])) {
        Text(verbatim: String(decoding: data, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func label(_ kind: OwlTemplateBackup.Kind) -> String {
    switch kind { case .new: return "新增"; case .update: return "同 ID 更新（默认跳过）"; case .identical: return "相同，跳过" }
  }
}
