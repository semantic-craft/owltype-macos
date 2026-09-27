import SwiftUI

struct OwlRaycastImportView: View {
  @State var preview: OwlRaycastImport.Preview
  let onImport: (OwlRaycastImport.Preview) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var error = ""

  var body: some View {
    let review = preview.assessment
    let validation = preview.validationMessage(for: review)
    return VStack(alignment: .leading, spacing: 12) {
      Text("导入 Raycast 模板").font(.title2)
      Text("共 \(preview.rows.count) 项 · 重复/已导入 \(review.duplicates.count) · 字段错误 \(invalidCount) · 待处理 \(pendingCount) · 冲突 \(review.conflicts.count)")
        .font(.caption)
      Text("仅支持基础 JSON 的 name、text 和 keyword。新条目默认仅搜索，不启用自动展开；标签、图标、富文本等扩展元数据不导入，Markdown 原文保留。诊断计数可能重叠。")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(preview.rows.indices, id: \.self) { index in
            row(at: index, review: review)
            Divider()
          }
        }
      }
      if let message = validation { Text(message).font(.caption).foregroundStyle(.red) }
      if !error.isEmpty { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      Text("所选 \(review.selectedIndices.count) 项：可执行 \(review.selectedIndices.count - review.pendingCount)，待处理 \(review.pendingCount)；其余跳过。待处理项保存原文，在修正启用前不能执行。")
        .font(.caption)
      HStack {
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("导入所选 \(review.selectedIndices.count) 项") {
          do { try onImport(preview); dismiss() }
          catch { self.error = error.localizedDescription }
        }.disabled(review.selectedIndices.count == 0 || validation != nil)
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("raycast-import-confirm")
      }
    }.padding(20).frame(minWidth: 560, idealWidth: 700, minHeight: 440, idealHeight: 620)
  }

  private var invalidCount: Int { preview.rows.filter { !$0.fieldErrors.isEmpty }.count }
  private var pendingCount: Int { preview.rows.filter { $0.entry?.isPendingReview == true }.count }

  private func row(at index: Int, review: OwlRaycastImport.Preview.Assessment) -> some View {
    let row = preview.rows[index]
    let duplicate = review.duplicates[index]
    return VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: $preview.rows[index].selected) {
        Text("\(row.number). " + (row.originalTitle.isEmpty ? "（空标题）" : row.originalTitle))
      }.disabled(row.entry == nil || duplicate != nil)
      if let duplicate {
        Text(duplicate == .identical ? "完全重复，跳过" : "来源已导入；保留本地修改，跳过")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(row.fieldErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
      if !row.unsupportedKeys.isEmpty {
        Text("这些扩展字段不导入：" + row.unsupportedKeys.joined(separator: "、"))
          .font(.caption).foregroundStyle(.orange)
      }
      if let entry = row.entry {
        Text("来源 keyword：" + (entry.importSource?.originalKeyword ?? "（未设置）"))
          .font(.caption).textSelection(.enabled)
        if entry.isPendingReview {
          Text("待处理：可勾选保存原文，稍后在编辑器修正；或明确转为普通文本。").font(.caption).foregroundStyle(.orange)
          ForEach(Array(row.syntaxIssues.enumerated()), id: \.offset) { _, issue in
            Text(issue.location(in: entry.body) + "：" + issue.message).font(.caption).foregroundStyle(.orange)
          }
          Button("按字面保留：转为普通文本") { preview.convertToPlainText(at: index) }.disabled(duplicate != nil)
        }
        if duplicate == nil {
          HStack {
            TextField("触发词（可改词）", text: Binding(get: { preview.rows[index].entry?.trigger ?? "" }, set: { preview.changeTrigger(at: index, to: $0) }))
            Button("仅搜索并清空触发词") { preview.makeSearchOnly(at: index) }
          }
          if review.conflicts[index] != nil {
            Text("触发词冲突：改词、仅搜索或取消勾选；不会覆盖已有条目。").font(.caption).foregroundStyle(.red)
          }
          Toggle("主动启用候选确认（仅合法小写字母数字编码）", isOn: Binding(
            get: { preview.rows[index].entry?.invocationMode == .candidate },
            set: { preview.rows[index].entry?.invocationMode = $0 ? .candidate : .searchOnly }
          )).font(.caption).disabled(entry.isPendingReview)
        }
      }
      if let body = row.originalBody {
        DisclosureGroup("完整原文") {
          Text(verbatim: body).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}
