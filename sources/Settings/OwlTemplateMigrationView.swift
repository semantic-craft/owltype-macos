import SwiftUI

final class OwlTemplateMigrationModel: ObservableObject {
  @Published var plan: OwlTemplateMigration.Plan?
  @Published var status = ""
  @Published var completed = false
  private let migration: OwlTemplateMigration
  init(rimeDir: URL) { migration = OwlTemplateMigration(rimeDir: rimeDir) }
  var conflicts: [String] { plan.map { migration.conflicts(in: $0) } ?? [] }
  var canCommit: Bool { plan?.issues.isEmpty == true && conflicts.isEmpty && !completed }
  func reload() {
    do {
      try migration.recoverIfNeeded()
      if OwlTemplateStore.mode(rimeDir: migration.rimeDir) == .unified {
        completed = true; plan = nil; status = "迁移已恢复并启用。"; return
      }
      plan = try migration.prepare()
      status = ""
    } catch { plan = nil; status = error.localizedDescription }
  }
  func resolve(id: UUID, code: String?) {
    guard let plan else { return }
    do { self.plan = try migration.resolve(plan, id: id, code: code); status = "" }
    catch { status = error.localizedDescription }
  }
  func commit() -> Bool {
    guard canCommit, let plan else { return false }
    do { try migration.commit(plan); completed = true; status = "迁移完成，原始文件和恢复备份已保留。"; return true }
    catch { status = error.localizedDescription; return false }
  }
}

struct OwlTemplateMigrationView: View {
  @StateObject private var model: OwlTemplateMigrationModel
  @State private var selectedID: UUID?
  @State private var editedCode = ""
  let onMigrated: () -> Void
  init(rimeDir: URL, onMigrated: @escaping () -> Void) {
    _model = StateObject(wrappedValue: OwlTemplateMigrationModel(rimeDir: rimeDir))
    self.onMigrated = onMigrated
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("迁移快捷短语与提示词").font(.title2)
      Text("原始文件会保留。请先处理记录问题和编码冲突，再启用统一模板库。暂不迁移时可切换到其他设置页，已有原件不会改变。")
        .foregroundStyle(.secondary)
      if let plan = model.plan {
        Text("待迁移 \(plan.entries.count) 条 · 已有新库 \(plan.existingEntries.count) 条 · 历史派生行折叠 \(plan.collapsedRows) 条")
        if !model.conflicts.isEmpty { Text("编码冲突：" + model.conflicts.joined(separator: "、")).foregroundStyle(.red) }
        if !plan.issues.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(plan.issues) { issue in
                Text("\(issue.file)\(issue.record.map { " · 第 \($0) 条/行" } ?? "")：\(issue.message)")
                  .textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 120)
        }
        HStack(alignment: .top) {
          List(plan.entries, selection: $selectedID) { entry in
            VStack(alignment: .leading) {
              Text(entry.title.isEmpty ? "无有效标题" : entry.title)
              Text(entry.trigger ?? "仅搜索").font(.caption).foregroundStyle(.secondary)
            }.tag(entry.id)
          }.frame(minWidth: 220)
          if let entry = plan.entries.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 10) {
              Text("原编码：" + (entry.migrationSource?.originalCode ?? ""))
              TextField("新的候选编码", text: $editedCode)
              HStack {
                Button("应用新编码") { model.resolve(id: entry.id, code: editedCode) }.disabled(editedCode.isEmpty)
                Button("仅搜索，保留原码信息") { model.resolve(id: entry.id, code: nil) }
              }
              Text("完整正文").font(.headline)
              ScrollView { Text(entry.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.frame(minWidth: 300)
          }
        }
      }
      if !model.status.isEmpty { Text(model.status).textSelection(.enabled) }
      HStack {
        Button("重新检查 / 恢复后重试") { model.reload() }
        Spacer()
        Button("迁移并启用") { _ = model.commit() }.disabled(!model.canCommit)
      }
    }.padding(16)
      .onAppear { model.reload() }
      .onChange(of: model.completed) { _, completed in if completed { onMigrated() } }
      .onChange(of: selectedID) { _, id in editedCode = model.plan?.entries.first(where: { $0.id == id })?.trigger ?? "" }
  }
}

/// Keeps both original settings routes, while replacing legacy editing with the lossless audit.
struct OwlTemplateSettingsRoute: View {
  let palette: OwlCandidatePalette
  var promptOnly = false
  var rimeDir: URL = OwlApp.userDir
  let onRedeploy: () -> Void
  @State private var unified = false
  var body: some View {
    Group {
      if unified || OwlTemplateStore.mode(rimeDir: rimeDir) == .empty || OwlTemplateStore.mode(rimeDir: rimeDir) == .unified {
        OwlTemplatePage(palette: palette, promptOnly: promptOnly, writer: OwlConfigWriter(rimeDir: rimeDir), onRedeploy: onRedeploy)
      } else {
        OwlTemplateMigrationView(rimeDir: rimeDir) { unified = true; onRedeploy() }
      }
    }
  }
}
