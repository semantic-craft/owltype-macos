import SwiftUI
import UniformTypeIdentifiers

/// The draft is independent of the saved list. A failed write never clears it or publishes it.
final class OwlTemplateEditorModel: ObservableObject {
  @Published var library = OwlTemplateLibrary()
  @Published var draft = OwlTemplateEntry()
  @Published var status = ""
  @Published var canEdit = true
  @Published var lastBackupURL: URL?
  @Published private(set) var automaticEnabled: Bool
  @Published private(set) var disabledBundleIDs: [String]
  private let defaults: UserDefaults
  private let automaticRuntime: OwlAutomaticExpansionRuntime
  let writer: OwlConfigWriter
  private let write: (OwlTemplateLibrary, OwlTemplateLibrary) throws -> Void

  init(writer: OwlConfigWriter = OwlConfigWriter(), defaults: UserDefaults = OwlDefaults.standard,
       automaticRuntime: OwlAutomaticExpansionRuntime = .shared,
       write: ((OwlTemplateLibrary, OwlTemplateLibrary) throws -> Void)? = nil) {
    self.writer = writer
    self.defaults = defaults
    self.automaticRuntime = automaticRuntime
    automaticEnabled = defaults.bool(forKey: OwlAutomaticExpansionRuntime.enabledKey)
    disabledBundleIDs = defaults.stringArray(forKey: OwlAutomaticExpansionRuntime.disabledBundleIDsKey) ?? []
    self.write = write ?? { try OwlTemplateStore.save($0, writer: writer, expectedLibrary: $1) }
  }

  func reload() {
    do {
      switch OwlTemplateStore.mode(rimeDir: writer.rimeDir) {
      case .empty: library = OwlTemplateLibrary()
      case .unified: library = try OwlTemplateStore.load(rimeDir: writer.rimeDir)
      case .legacy: throw OwlTemplateError.legacyRequiresMigration
      case .unavailable(let message): throw OwlTemplateError.invalid(message)
      }
      canEdit = true
      status = ""
    } catch {
      canEdit = false
      status = error.localizedDescription
    }
  }

  func newDraft(category: OwlTemplateEntry.Category = .general) {
    draft = OwlTemplateEntry()
    draft.category = category
    status = ""
  }

  func setInvocationMode(_ mode: OwlTemplateEntry.InvocationMode) {
    if mode == .automatic {
      if draft.invocationMode != .automatic { draft.expansionMode = .immediate }
    }
    draft.invocationMode = mode
    if mode != .candidate { draft.candidateAliases = [] }
  }

  func reloadAutomaticConfiguration() {
    do { try automaticRuntime.reload(rimeDir: writer.rimeDir, defaults: defaults) }
    catch { status = "自动展开暂不可用：" + error.localizedDescription }
  }

  func setAutomaticEnabled(_ enabled: Bool) {
    automaticEnabled = enabled
    defaults.set(enabled, forKey: OwlAutomaticExpansionRuntime.enabledKey)
    reloadAutomaticConfiguration()
  }

  @discardableResult
  func addDisabledBundleID(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard value.contains("."), value.range(of: "^[a-z0-9][a-z0-9.-]*$", options: .regularExpression) != nil else {
      status = "请输入应用的完整 bundle ID，例如 com.apple.TextEdit。"; return false
    }
    guard !disabledBundleIDs.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return true }
    disabledBundleIDs.append(value)
    defaults.set(disabledBundleIDs, forKey: OwlAutomaticExpansionRuntime.disabledBundleIDsKey)
    reloadAutomaticConfiguration()
    return true
  }

  func removeDisabledBundleID(_ value: String) {
    disabledBundleIDs.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
    defaults.set(disabledBundleIDs, forKey: OwlAutomaticExpansionRuntime.disabledBundleIDsKey)
    reloadAutomaticConfiguration()
  }

  var hasUnsavedChanges: Bool {
    if let saved = library.entries.first(where: { $0.id == draft.id }) {
      return (try? OwlTemplateStore.encoded(.init(entries: [saved]))) != (try? OwlTemplateStore.encoded(.init(entries: [draft])))
    }
    return !draft.title.isEmpty || !draft.body.isEmpty || draft.trigger != nil || !draft.tags.isEmpty || draft.isPinned
  }

  func addTag(_ input: String) {
    let tag = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tag.isEmpty, !draft.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
    draft.tags.append(tag)
  }

  @discardableResult
  func insertClipboardField() -> Bool { appendDynamicField("{clipboard}") }

  @discardableResult
  func insertCursorField() -> Bool { appendDynamicField("{cursor}") }

  @discardableResult
  func insertTemporalField(kind: OwlTemplateEngine.TemporalKind, format: String, offset: String) -> Bool {
    var field = "{" + kind.rawValue
    if !format.isEmpty { field += " format=" + OwlTemplateEngine.quoted(format) }
    if !offset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      field += " offset=" + OwlTemplateEngine.quoted(offset)
    }
    return appendDynamicField(field + "}")
  }

  private func appendDynamicField(_ field: String) -> Bool {
    guard draft.bodyType == .template, draft.syntax == .standard else {
      status = "请先明确切换到模板及动态字段语法。"; return false
    }
    var candidate = draft
    candidate.body += field
    if let error = OwlTemplateEngine.parse(body: candidate.body, bodyType: candidate.bodyType, syntax: candidate.syntax, definitions: candidate.parameters).diagnostics.first(where: { $0.severity == .error }) {
      status = error.message; return false
    }
    draft = candidate
    status = "已插入到正文末尾，保存后生效。"
    return true
  }

  func delete(_ entry: OwlTemplateEntry) -> Bool {
    do {
      let outcome = try OwlTemplateBackup(rimeDir: writer.rimeDir).delete(id: entry.id, expected: library)
      library = outcome.library; lastBackupURL = outcome.backupURL
      if draft.id == entry.id { newDraft(category: entry.category) }
      status = "已删除，完整库备份已保留，可从备份恢复。"
      return true
    } catch { status = error.localizedDescription; return false }
  }

  func restore(_ preview: OwlTemplateBackup.Preview) throws {
    let outcome = try OwlTemplateBackup(rimeDir: writer.rimeDir).restore(preview)
    library = outcome.library; lastBackupURL = outcome.backupURL
    if let updated = library.entries.first(where: { $0.id == draft.id }) { draft = updated }
    status = "恢复完成，当前库其他条目已保留。候选调用在重新部署后生效。"
  }

  func importRaycast(_ preview: OwlRaycastImport.Preview) throws {
    let outcome = try OwlRaycastImport(rimeDir: writer.rimeDir).commit(preview)
    library = outcome.library; lastBackupURL = outcome.backupURL
    if let first = preview.selectedIndices.first, let entry = preview.rows[first].entry { draft = entry }
    status = "已导入 \(preview.selectedCount) 项（待处理 \(preview.pendingCount) 项）。默认仅搜索，未启用自动展开。"
  }

  @discardableResult
  func enableReviewedDraft() -> Bool {
    guard OwlRaycastImport.enableAfterReview(&draft) else {
      status = "仍有未支持或有歧义的语法，请继续修正；按字面使用请明确转为普通文本。"; return false
    }
    status = "已通过语法核对，保存后启用；已移除正文中不再使用的参数设置。"
    return true
  }

  func convertReviewedDraftToPlainText() {
    OwlRaycastImport.convertToPlainText(&draft)
    status = "已明确转为普通文本，所有标记按字面保留；保存后生效。"
  }

  // Editing must expose the original diagnostics even while runtime execution is gated.
  var parsed: OwlTemplateEngine.Parsed {
    OwlTemplateEngine.parse(body: draft.body, bodyType: draft.bodyType, syntax: draft.syntax, definitions: draft.parameters)
  }

  func diagnosticMessage(_ diagnostic: OwlTemplateEngine.Diagnostic) -> String {
    if draft.isPendingReview, draft.importSource != nil,
       diagnostic.message == "未支持的字段将原样插入。" {
      return "含尚未支持的字段，保留待处理，不能执行。"
    }
    return diagnostic.message
  }

  func setBody(_ body: String) {
    guard !draft.body.utf8.elementsEqual(body.utf8) else { return }
    let hadAnonymousSettings = draft.parameters.contains { $0.key.hasPrefix("a:") }
    draft.body = body
    if hadAnonymousSettings {
      draft.parameters.removeAll { $0.key.hasPrefix("a:") }
      status = "正文已修改：匿名参数设置已重置，请重新核对必填、默认值和选项。命名参数设置保留。"
    }
  }

  @discardableResult
  func insertParameter(name: String, required: Bool, defaultValue: String?, options: String) -> Bool {
    guard draft.bodyType == .template, draft.syntax == .standard else {
      status = "请先明确选择模板及动态字段语法。"
      return false
    }
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let count = parsed.parameters.filter { $0.key.hasPrefix("a:") }.count + 1
    let key = cleanName.isEmpty ? "a:\(count)" : "n:" + cleanName
    let definition = OwlTemplateParameter(key: key, name: cleanName.isEmpty ? "参数 \(count)" : cleanName,
      isRequired: required, defaultValue: defaultValue, options: parseOptions(options))
    var candidate = draft
    candidate.body += parameterText(definition, anonymous: cleanName.isEmpty)
    candidate.parameters.removeAll { $0.key == key }
    candidate.parameters.append(definition)
    let diagnostics = OwlTemplateEngine.parse(body: candidate.body, bodyType: candidate.bodyType, syntax: candidate.syntax, definitions: candidate.parameters).diagnostics
    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      status = diagnostics.first(where: { $0.severity == .error })?.message ?? "参数无效。"
      return false
    }
    draft = candidate
    status = "已插入到正文末尾，保存后生效。"
    return true
  }

  func updateParameter(_ parameter: OwlTemplateEngine.Parameter, required: Bool, defaultValue: String?, options: String) -> Bool {
    let definition = OwlTemplateParameter(key: parameter.key, name: parameter.name, isRequired: required,
      defaultValue: defaultValue, options: parseOptions(options))
    var candidate = draft
    if !parameter.legacy {
      let text = NSMutableString(string: candidate.body)
      for range in parameter.ranges.reversed() {
        text.replaceCharacters(in: range, with: parameterText(definition, anonymous: parameter.key.hasPrefix("a:")))
      }
      candidate.body = text as String
    }
    candidate.parameters.removeAll { $0.key == parameter.key }
    candidate.parameters.append(definition)
    let diagnostics = OwlTemplateEngine.parse(body: candidate.body, bodyType: candidate.bodyType, syntax: candidate.syntax, definitions: candidate.parameters).diagnostics
    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      status = diagnostics.first(where: { $0.severity == .error })?.message ?? "参数无效。"
      return false
    }
    draft = candidate
    status = "参数设置已更新，保存后生效。"
    return true
  }

  private func parseOptions(_ text: String) -> [String] {
    text.isEmpty ? [] : text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  private func parameterText(_ parameter: OwlTemplateParameter, anonymous: Bool) -> String {
    var text = "{argument"
    if !anonymous { text += " name=" + OwlTemplateEngine.quoted(parameter.name) }
    if let value = parameter.defaultValue { text += " default=" + OwlTemplateEngine.quoted(value) }
    if !parameter.options.isEmpty { text += " options=" + OwlTemplateEngine.quoted(parameter.options.joined(separator: ", ")) }
    return text + "}"
  }

  func save() -> Bool {
    guard canEdit else { return false }
    if !draft.isPendingReview, let error = parsed.diagnostics.first(where: { $0.severity == .error }) {
      status = error.message
      return false
    }
    var candidate = draft
    if candidate.importSource != nil && !OwlRaycastImport.compatibilityIssues(candidate).isEmpty {
      candidate.reviewState = .pending
    }
    if candidate.trigger?.isEmpty == true { candidate.trigger = nil }
    var next = library
    if let index = next.entries.firstIndex(where: { $0.id == candidate.id }) {
      next.entries[index] = candidate
    } else { next.entries.append(candidate) }
    do {
      try OwlTemplateStore.validate(next)
      try write(next, library)
      library = next
      draft = candidate
      status = candidate.isPendingReview ? "已保存为待处理；修正并启用前不能执行。" : "已保存。候选调用在重新部署后生效。"
      return true
    } catch {
      status = error.localizedDescription
      return false
    }
  }
}

/// Scroll the whole detail surface so native toolbar safe areas and short windows never clip controls.
struct OwlTemplatePage: View {
  let palette: OwlCandidatePalette
  @State private var promptOnly = false
  var onRedeploy: (() -> Void)?
  @StateObject private var model: OwlTemplateEditorModel
  @State private var search = ""
  @State private var selectedTag: String?
  @State private var newTag = ""
  @State private var temporalFormat = ""
  @State private var temporalOffset = ""
  @State private var disabledBundleIDInput = ""
  @State private var filePanelHost = OwlTemplateFilePanelHost()
  @State private var importPreview: OwlRaycastImport.Preview?
  @State private var restorePreview: OwlTemplateBackup.Preview?
  @State private var deletion: OwlTemplateEntry?
  @State private var showingDelete = false
  @State private var pendingAction: (() -> Void)?
  @State private var showingUnsaved = false
  @State private var insertingClipboardAfterConversion = false
  @State private var showTemplateConversion = false
  @State private var addingParameter = false
  @State private var editingParameter: OwlTemplateEngine.Parameter?
  @State private var showSyntaxChange = false
  @State private var previewValues: [String: String] = [:]
  @State private var diagnosticSelection: NSRange?

  init(palette: OwlCandidatePalette, promptOnly: Bool = false,
       writer: OwlConfigWriter = OwlConfigWriter(), onRedeploy: (() -> Void)? = nil) {
    self.palette = palette
    _promptOnly = State(initialValue: promptOnly)
    self.onRedeploy = onRedeploy
    _model = StateObject(wrappedValue: OwlTemplateEditorModel(writer: writer))
  }

  private var entries: [OwlTemplateEntry] {
    OwlTemplateStore.filtered(model.library.entries, query: search, tag: selectedTag, promptOnly: promptOnly)
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        if geometry.size.width >= 620 {
          HStack(alignment: .top, spacing: 16) {
            libraryList.frame(width: 190)
            Divider()
            editor.frame(maxWidth: .infinity)
          }
        } else {
          VStack(alignment: .leading, spacing: 16) {
            libraryList
            Divider()
            editor
          }
        }
      }.safeAreaPadding(.top, 16).padding(.horizontal, 16)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            SettingsCardDivider(palette: palette)
            saveBar.padding(.vertical, 12)
          }
          .padding(.horizontal, 16)
          .background(palette.card2)
        }
    }
    .background(OwlTemplateFilePanelWindow(host: filePanelHost).frame(width: 0, height: 0))
    .onDisappear { filePanelHost.activePanel?.cancel(nil) }
    .onAppear { model.newDraft(category: promptOnly ? .prompt : .general); model.reload(); model.reloadAutomaticConfiguration(); resetPreview() }
    .onChange(of: model.draft) { _, _ in resetPreview() }
    .onChange(of: model.library) { _, library in
      if let tag = selectedTag, !OwlTemplateStore.tags(in: library.entries).contains(tag) { selectedTag = nil }
    }
    .sheet(isPresented: $addingParameter) {
      OwlTemplateParameterForm(parameter: nil) { name, required, value, options in
        model.insertParameter(name: name, required: required, defaultValue: value, options: options)
      }
    }
    .sheet(item: $editingParameter) { parameter in
      OwlTemplateParameterForm(parameter: parameter) { _, required, value, options in
        model.updateParameter(parameter, required: required, defaultValue: value, options: options)
      }
    }
    .alert("启用动态字段语法？", isPresented: $showSyntaxChange) {
      Button("取消", role: .cancel) { insertingClipboardAfterConversion = false }
      Button("启用并检查预览") {
        model.draft.syntax = .standard
        if insertingClipboardAfterConversion { model.insertClipboardField(); insertingClipboardAfterConversion = false }
      }
    } message: {
      Text("正文保持不变。原来的单花括号可能开始解释为参数、剪贴板或日期；请检查下方诊断与预览后再保存。")
    }
    .alert("切换为模板并插入剪贴板字段？", isPresented: $showTemplateConversion) {
      Button("取消", role: .cancel) {}
      Button("切换并插入") { model.draft.bodyType = .template; model.draft.syntax = .standard; model.insertClipboardField() }
    } message: { Text("正文中的动态字段将开始解析。剪贴板只在本次调用时主动读取一次，不启用剪贴板历史。") }
    .confirmationDialog("当前草稿尚未保存", isPresented: $showingUnsaved, titleVisibility: .visible) {
      Button("保存并继续") { if model.save() { onRedeploy?(); performPending() } }
      Button("放弃草稿并继续", role: .destructive) { performPending() }
      Button("取消", role: .cancel) { pendingAction = nil }
    }
    .alert("删除这个模板？", isPresented: $showingDelete, presenting: deletion) { entry in
      Button("取消", role: .cancel) { deletion = nil }
      Button("备份并删除", role: .destructive) { if model.delete(entry) { onRedeploy?() }; deletion = nil }
    } message: { entry in
      Text(entry.title + " · " + String(entry.id.uuidString.prefix(8)) + "\n" + (entry.trigger ?? "仅搜索") +
        " · " + entry.tags.joined(separator: "、") + "\n" + String(entry.body.prefix(160)) + "\n删除前会备份整个已保存库。")
    }
    .sheet(item: $importPreview) { preview in
      OwlRaycastImportView(preview: preview) { selection in try model.importRaycast(selection); onRedeploy?() }
    }
    .sheet(item: $restorePreview) { preview in
      OwlTemplateRestoreView(preview: preview) { selection in try model.restore(selection); onRedeploy?() }
    }
  }

  private var libraryList: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("快捷片段").font(.headline)
      categoryFilter
      TextField("搜索标题、正文、标签或触发词", text: $search)
      Picker("标签筛选", selection: $selectedTag) {
        Text("全部标签").tag(nil as String?)
        ForEach(OwlTemplateStore.tags(in: model.library.entries), id: \.self) { Text($0).tag(Optional($0)) }
      }
      Button("新建") { withSavedDraft { model.newDraft(category: promptOnly ? .prompt : .general) } }
      automaticSettings
      Button("导入 Raycast JSON…") { withSavedDraft { chooseRaycastImport() } }
        .disabled(!model.canEdit).accessibilityIdentifier("template-import-raycast")
      Menu("导出与恢复") {
        Button("导出完整原生备份…", action: exportBackup)
        Button("从原生备份恢复…") { withSavedDraft { chooseRestore() } }
        Button("打开本地备份文件夹") {
          NSWorkspace.shared.open(model.writer.rimeDir.appendingPathComponent(".owl-backup"))
        }
      }.disabled(!model.canEdit)
      if entries.isEmpty { Text(model.library.entries.isEmpty ? "尚无模板" : "无匹配条目").font(.caption).foregroundStyle(.secondary) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(entries) { entry in
            Button { withSavedDraft { model.draft = entry; model.status = "" } } label: {
              VStack(alignment: .leading) {
                Text((entry.isPinned ? "📌 " : "") + entry.title).lineLimit(1)
                if entry.isPendingReview { Text("待处理 · 不可执行").font(.caption).foregroundStyle(.orange) }
                if let trigger = entry.trigger { Text(trigger).font(.caption).foregroundStyle(.secondary) }
                if !entry.tags.isEmpty { Text(entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(model.draft.id == entry.id ? palette.accent.opacity(0.12) : .clear)
            }.buttonStyle(.plain)
          }
        }
      }.frame(minHeight: 80, maxHeight: 240)
    }
  }

  private var categoryFilter: some View {
    HStack(spacing: 2) {
      categoryButton("全部", prompt: false)
      categoryButton("提示词", prompt: true)
    }
    .padding(3)
    .background(palette.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("内容筛选")
    .accessibilityIdentifier("snippet-category-filter")
  }

  private func categoryButton(_ title: String, prompt: Bool) -> some View {
    let selected = promptOnly == prompt
    return Button { promptOnly = prompt } label: {
      Text(title)
        .font(.system(size: 13, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? palette.ink : palette.ink2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background {
          if selected {
            RoundedRectangle(cornerRadius: 6)
              .fill(palette.card)
              .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("编辑条目").font(.headline)
      if model.draft.isPendingReview {
        Text("导入待处理：可保存修改，但不能调用。修正后验证启用，或明确转为普通文本。").font(.caption).foregroundStyle(.orange)
        HStack {
          Button("验证并启用") { model.enableReviewedDraft() }.accessibilityIdentifier("template-review-enable")
          Button("按字面保留：转为普通文本") { model.convertReviewedDraftToPlainText() }
            .accessibilityIdentifier("template-review-plain")
        }
        ForEach(Array(OwlRaycastImport.compatibilityIssues(model.draft).enumerated()), id: \.offset) { _, issue in
          Text(issue.location(in: model.draft.body) + "：" + issue.message).font(.caption).foregroundStyle(.orange)
        }
      }
      if let source = model.draft.importSource {
        DisclosureGroup("Raycast 导入来源（原文保留）") {
          Text("来源标题：" + source.originalName).font(.caption)
          Text("来源 keyword：" + (source.originalKeyword ?? "（未设置）")).font(.caption)
          Text(verbatim: source.originalBody).font(.caption.monospaced()).textSelection(.enabled)
        }
      }
      if model.library.entries.contains(where: { $0.id == model.draft.id }) && !entries.contains(where: { $0.id == model.draft.id }) {
        Text("正在编辑筛选外条目；草稿已保留。").font(.caption).foregroundStyle(.secondary)
      }
      TextField("标题（必填）", text: $model.draft.title).accessibilityIdentifier("template-title")
      TextField("触发词（可留空）", text: Binding(
        get: { model.draft.trigger ?? "" }, set: { model.draft.trigger = $0.isEmpty ? nil : $0; model.draft.candidateAliases = [] }
      )).accessibilityIdentifier("template-trigger")
      Picker("调用方式", selection: Binding(get: { model.draft.invocationMode }, set: { model.setInvocationMode($0) })) {
        Text("仅搜索").tag(OwlTemplateEntry.InvocationMode.searchOnly)
        Text("候选确认").tag(OwlTemplateEntry.InvocationMode.candidate)
        Text("自动展开").tag(OwlTemplateEntry.InvocationMode.automatic)
      }
      if model.draft.invocationMode == .automatic {
        Picker("展开时机", selection: $model.draft.expansionMode) {
          Text("立即展开").tag(OwlTemplateEntry.ExpansionMode.immediate)
          Text("分隔符后保留").tag(OwlTemplateEntry.ExpansionMode.delimiterKeep)
          Text("分隔符后丢弃").tag(OwlTemplateEntry.ExpansionMode.delimiterDrop)
        }.accessibilityIdentifier("template-expansion-mode")
        Text("自动触发词须为 ;; 后接字母、数字、下划线或连字符，区分大小写。分隔符：空格、Tab、Return，以及中英文逗号、句号、问号、叹号、冒号。保留 Tab 或 Return 是插入文本，不发送消息或表单。")
          .font(.caption).foregroundStyle(.secondary)
      } else if model.draft.bodyType == .template {
        Text("动态模板可自动展开；宿主无法安全替换时保留原输入并提供结果复制。").font(.caption).foregroundStyle(.secondary)
      }
      Toggle("置顶", isOn: $model.draft.isPinned)
      VStack(alignment: .leading, spacing: 6) {
        Text("标签").font(.caption)
        ForEach(Array(model.draft.tags.enumerated()), id: \.offset) { index, tag in
          HStack { Text(tag); Button("移除") { model.draft.tags.remove(at: index) }.font(.caption) }
        }
        HStack {
          TextField("添加一个标签", text: $newTag).onSubmit { model.addTag(newTag); newTag = "" }
          Button("添加") { model.addTag(newTag); newTag = "" }.disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      Picker("正文类型", selection: $model.draft.bodyType) {
        Text("普通文本").tag(OwlTemplateEntry.BodyType.plainText)
        Text("模板").tag(OwlTemplateEntry.BodyType.template)
      }.accessibilityIdentifier("template-body-type")
      if model.draft.bodyType == .template {
        if model.draft.syntax == .legacyDoubleBraces {
          Text("旧式变量：只解释双花括号，单花括号原样保留。").font(.caption)
          Button("启用动态字段语法…") { showSyntaxChange = true }
        } else {
          Text("模板：解释参数与已支持的动态字段。").font(.caption)
          Button("插入参数到正文末尾…") { addingParameter = true }
        }
      } else {
        Text("花括号原样插入。使用参数时请明确切换为模板。").font(.caption).foregroundStyle(.secondary)
      }
      Button("插入剪贴板字段到正文末尾") {
        if model.draft.bodyType == .plainText { showTemplateConversion = true }
        else if model.draft.syntax == .legacyDoubleBraces { insertingClipboardAfterConversion = true; showSyntaxChange = true }
        else { model.insertClipboardField() }
      }.accessibilityIdentifier("template-insert-clipboard")
      Text("明确预览或使用时读取一次纯文本；不启用剪贴板历史。").font(.caption).foregroundStyle(.secondary)
      temporalFields
      Button("插入光标字段到正文末尾") { model.insertCursorField() }
        .disabled(model.draft.bodyType != .template || model.draft.syntax != .standard)
        .accessibilityIdentifier("template-insert-cursor")
      Text("模板最多一个光标字段，可在正文中移动 {cursor}；宿主无法定位时会提示。")
        .font(.caption).foregroundStyle(.secondary)
      OwlTemplateBodyEditor(documentID: model.draft.id, text: Binding(get: { model.draft.body }, set: { model.setBody($0) }), selection: $diagnosticSelection)
        .frame(height: 180).border(palette.ink.opacity(0.15)).accessibilityIdentifier("template-body")
      diagnostics
      if !model.parsed.parameters.isEmpty {
        Text("参数与试填").font(.headline)
        ForEach(model.parsed.parameters) { parameter in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(parameter.name + (parameter.isRequired ? " · 必填" : " · 可选"))
              Spacer()
              Button("设置") { editingParameter = parameter }
            }
            if parameter.options.isEmpty {
              TextField("试填以查看结果", text: Binding(get: { previewValues[parameter.key] ?? "" }, set: { previewValues[parameter.key] = $0 }), axis: .vertical)
                .lineLimit(1...4)
            } else {
              Picker("试填", selection: Binding<String?>(get: { previewValues[parameter.key] }, set: { previewValues[parameter.key] = $0 })) {
                Text("请选择").tag(nil as String?)
                ForEach(parameter.options, id: \.self) { Text($0).tag(Optional($0)) }
              }
            }
            if !parameter.isRequired { Button("本次留空") { previewValues[parameter.key] = "" }.font(.caption) }
          }
        }
      }
      Text(model.draft.bodyType == .plainText ? "完整正文预览" : "展开结果预览（试填值不保存）").font(.caption)
      let preview = OwlTemplateEngine.render(model.parsed, values: previewValues)
      if let offset = preview.cursorOffset {
        Text(OwlTemplateCursorPlacement.positionDescription(text: preview.previewText, offset: offset))
          .font(.caption).accessibilityIdentifier("template-editor-cursor-preview")
      }
      ScrollView([.horizontal, .vertical]) {
        Text(verbatim: OwlTemplateEngine.render(model.parsed, values: previewValues).previewText)
          .font(.system(.body, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }.frame(height: 150).accessibilityIdentifier("template-preview")
      Text("仅搜索不会自动展开。候选编码只接受小写字母开头的字母或数字。")
        .font(.caption).foregroundStyle(.secondary)
    }.disabled(!model.canEdit).padding(.bottom, 16)
  }

  private var automaticSettings: some View {
    DisclosureGroup("自动展开设置") {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("启用自动展开", isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomaticEnabled($0) }))
          .accessibilityIdentifier("template-automatic-enabled")
        Text("仅在 Owltype 激活时工作；支持普通文本和动态模板的立即或分隔符展开。多个工具使用同一触发词时，请自行选择由哪个工具处理。")
          .font(.caption).foregroundStyle(.secondary)
        Text("在以下应用中禁用").font(.caption)
        ForEach(model.disabledBundleIDs, id: \.self) { bundleID in
          VStack(alignment: .leading) {
            Text(bundleID).font(.caption).textSelection(.enabled)
            Button("移除") { model.removeDisabledBundleID(bundleID) }.font(.caption)
          }
        }
        TextField("com.apple.TextEdit", text: $disabledBundleIDInput)
          .accessibilityIdentifier("template-automatic-disabled-app")
        Button("添加禁用应用") {
          if model.addDisabledBundleID(disabledBundleIDInput) { disabledBundleIDInput = "" }
        }
      }.padding(.top, 6)
    }
  }

  private var temporalFields: some View {
    DisclosureGroup("插入日期与时间字段") {
      VStack(alignment: .leading, spacing: 8) {
        TextField("格式（留空使用系统默认）", text: $temporalFormat)
          .accessibilityIdentifier("template-temporal-format")
        Text("例如 yyyy-MM-dd、HH:mm:ss；yyyy 是日历年，YYYY 是周所属年；英文原文放在单引号内。")
          .font(.caption).foregroundStyle(.secondary)
        Link("Unicode 日期格式说明", destination: URL(string: "https://unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table")!)
          .font(.caption)
        TextField("偏移（例如 +1M -2d 或 +30m）", text: $temporalOffset)
          .accessibilityIdentifier("template-temporal-offset")
        Text("m 是分钟，M 是月；多个偏移从左到右依次计算。")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("插入日期") { model.insertTemporalField(kind: .date, format: temporalFormat, offset: temporalOffset) }
            .accessibilityIdentifier("template-insert-date")
          Button("插入时间") { model.insertTemporalField(kind: .time, format: temporalFormat, offset: temporalOffset) }
            .accessibilityIdentifier("template-insert-time")
          Button("插入日期时间") { model.insertTemporalField(kind: .datetime, format: temporalFormat, offset: temporalOffset) }
            .accessibilityIdentifier("template-insert-datetime")
        }.disabled(model.draft.bodyType != .template || model.draft.syntax != .standard )
        if model.draft.bodyType != .template || model.draft.syntax != .standard {
          Text("请先在上方明确切换为模板，并启用动态字段语法。").font(.caption)
        }
        Text("使用或明确预览时取一次时间；填空和插入沿用本次时间、时区、区域与日历。")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(.top, 6)
    }
  }

  private var diagnostics: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(OwlTemplateEngine.render(model.parsed, values: previewValues).diagnostics.enumerated()), id: \.offset) { _, diagnostic in
        Button {
          diagnosticSelection = diagnostic.range
        } label: {
          Text(diagnostic.location(in: model.draft.body) + "：" + model.diagnosticMessage(diagnostic) + " 查看位置")
            .font(.caption).foregroundStyle(diagnostic.severity == .error ? .red : .orange)
        }.buttonStyle(.plain)
      }
    }
  }

  private var saveBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button("保存") { if model.save() { onRedeploy?() } }.accessibilityIdentifier("template-save").disabled(!model.canEdit)
          .buttonStyle(OwlFilledButtonStyle(palette: palette))
          .fixedSize()
        Button("复制为新条目") { withSavedDraft { model.draft = model.draft.duplicated(); model.status = "副本尚未保存。" } }.disabled(!model.canEdit)
          .buttonStyle(OwlTemplateSecondaryButtonStyle(palette: palette))
        Button("删除…", role: .destructive) {
          deletion = model.library.entries.first { $0.id == model.draft.id }; showingDelete = deletion != nil
        }.disabled(!model.canEdit || !model.library.entries.contains { $0.id == model.draft.id })
          .buttonStyle(OwlTemplateSecondaryButtonStyle(palette: palette))
        Spacer()
      }
      if let backupURL = model.lastBackupURL {
        Button("查看本次操作前的备份") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }.font(.caption)
      }
      if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true) }
    }
  }

  private func withSavedDraft(_ action: @escaping () -> Void) {
    if model.hasUnsavedChanges { pendingAction = action; showingUnsaved = true }
    else { action() }
  }

  private func performPending() {
    let action = pendingAction; pendingAction = nil
    // Discard restores the saved value before an operation such as copying or restoring.
    if let saved = model.library.entries.first(where: { $0.id == model.draft.id }) { model.draft = saved }
    else { model.newDraft(category: promptOnly ? .prompt : .general) }
    action?()
  }

  private func exportBackup() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "owltype-templates.json"
    panel.message = "导出整个已保存库（包含所有标签和参数）；未保存草稿不包含在内。"
    presentFilePanel(panel) { [weak model] url in
      guard let model else { return }
      do { try OwlTemplateBackup(rimeDir: model.writer.rimeDir).export(to: url); model.status = "完整原生备份已导出。" }
      catch { model.status = error.localizedDescription }
    }
  }

  private func chooseRaycastImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
    panel.message = "选择 Raycast 基础 JSON；下一步预览并选择要导入的条目。"
    presentFilePanel(panel) { [weak model] url in
      guard let model else { return }
      do { importPreview = try OwlRaycastImport(rimeDir: model.writer.rimeDir).preview(data: Data(contentsOf: url)) }
      catch { model.status = error.localizedDescription }
    }
  }

  private func chooseRestore() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
    presentFilePanel(panel) { [weak model] url in
      guard let model else { return }
      do { restorePreview = try OwlTemplateBackup(rimeDir: model.writer.rimeDir).preview(data: Data(contentsOf: url)) }
      catch { model.status = error.localizedDescription }
    }
  }

  // Capture the actual containing settings window before scheduling; never guess via keyWindow.
  private func presentFilePanel(_ panel: NSSavePanel, selection: @escaping (URL) -> Void) {
    guard let window = filePanelHost.window, window.isVisible, !filePanelHost.isPresenting else {
      model.status = "请先返回设置窗口，再打开文件选择。"; return
    }
    filePanelHost.isPresenting = true
    let host = filePanelHost
    DispatchQueue.main.async { [weak window, weak host] in
      guard let host else { return }
      guard let window, window.isVisible, host.window === window, window.attachedSheet == nil else {
        host.isPresenting = false; return
      }
      host.activePanel = panel
      panel.beginSheetModal(for: window) { [weak panel, weak window, weak host] response in
        host?.isPresenting = false; host?.activePanel = nil
        guard response == .OK, let url = panel?.url else { return }
        // End the AppKit sheet before a SwiftUI import/restore preview becomes another sheet.
        DispatchQueue.main.async { [weak window, weak host] in
          guard let window, window.isVisible, host?.window === window else { return }
          selection(url)
        }
      }
    }
  }

  private func resetPreview() { previewValues = model.parsed.initialValues }
}

private struct OwlTemplateSecondaryButtonStyle: ButtonStyle {
  let palette: OwlCandidatePalette
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(palette.ink2)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.ink.opacity(configuration.isPressed ? 0.10 : 0.04))
      }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Rectangle())
  }
}

private struct OwlTemplateParameterForm: View {
  let parameter: OwlTemplateEngine.Parameter?
  let onSave: (String, Bool, String?, String) -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var required = true
  @State private var hasDefault = false
  @State private var defaultValue = ""
  @State private var options = ""
  @State private var error = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(parameter == nil ? "插入参数" : "参数设置").font(.headline)
      TextField("名称（留空为独立匿名参数）", text: $name).disabled(parameter != nil)
      Toggle("必填", isOn: $required)
      Toggle("使用默认值", isOn: $hasDefault)
      if hasDefault { TextField("默认值（可以为空）", text: $defaultValue) }
      TextField("预设选项（用英文逗号分隔，可留空）", text: $options)
      Text("未设置默认值时不自动选中第一项；可选参数允许本次明确留空。").font(.caption)
      if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
      HStack {
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("确定") {
          if onSave(name, required, hasDefault ? defaultValue : nil, options) { dismiss() }
          else { error = "参数设置无效或与正文声明冲突，请检查默认值和选项。" }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(22).frame(width: 420).onAppear {
      if let parameter {
        name = parameter.name; required = parameter.isRequired
        hasDefault = parameter.defaultValue != nil; defaultValue = parameter.defaultValue ?? ""
        options = parameter.options.joined(separator: ", ")
      }
    }
  }
}

/// AppKit selection lets a diagnostic reveal the exact source span without changing the body.
private struct OwlTemplateBodyEditor: NSViewRepresentable {
  let documentID: UUID
  @Binding var text: String
  @Binding var selection: NSRange?

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    guard let editor = scroll.documentView as? NSTextView else { return scroll }
    editor.delegate = context.coordinator
    editor.isRichText = false
    editor.isEditable = context.environment.isEnabled
    editor.allowsUndo = true
    editor.smartInsertDeleteEnabled = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    editor.setAccessibilityIdentifier("template-body")
    editor.string = text
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? NSTextView else { return }
    editor.isEditable = context.environment.isEnabled
    if context.coordinator.documentID != documentID || !editor.string.utf8.elementsEqual(text.utf8) {
      editor.undoManager?.removeAllActions()
      editor.string = text
      context.coordinator.documentID = documentID
    }
    if let selection, NSMaxRange(selection) <= (text as NSString).length {
      editor.setSelectedRange(selection)
      editor.scrollRangeToVisible(selection)
      editor.window?.makeFirstResponder(editor)
      DispatchQueue.main.async { self.selection = nil }
    }
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: OwlTemplateBodyEditor
    var documentID: UUID
    init(_ parent: OwlTemplateBodyEditor) { self.parent = parent; self.documentID = parent.documentID }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? NSTextView else { return }
      parent.text = editor.string
    }
  }
}

private final class OwlTemplateFilePanelHost {
  weak var window: NSWindow?
  weak var activePanel: NSSavePanel?
  var isPresenting = false
}

private struct OwlTemplateFilePanelWindow: NSViewRepresentable {
  let host: OwlTemplateFilePanelHost
  func makeNSView(context: Context) -> WindowView { WindowView(host: host) }
  func updateNSView(_ view: WindowView, context: Context) { host.window = view.window }
  final class WindowView: NSView {
    let host: OwlTemplateFilePanelHost
    init(host: OwlTemplateFilePanelHost) { self.host = host; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); host.window = window }
  }
}
