//
//  OwlPromptPage.swift
//  猫头鹰输入法 (Owltype) — 提示词管理面板（R5：master-detail 设置页）
//
//  「提示词」是「快捷短语」的 sibling 特性：同样用触发码调出，但正文长 / 多行 / 可含
//  `{{变量}}`，放不进单行的 Rime 候选条。本页只负责 R5 的管理 UI——新建 / 编辑 / 分类 /
//  搜索 / 删除——并把 source-of-truth 写进 `owl_prompts.json`（经 `OwlConfigWriter` 原子写）。
//
//  **不在本页**：Rime dict（`owl_prompts.txt`）/ `rime_ice.custom.yaml` patch 的生成、控制器
//  提交拦截、📝 候选标记、填空 sheet——这些 R2 触发链路另起一轮，会接到同一个 save 路径之后。
//  所以这里 `保存并应用` 只落 JSON，不部署、不碰 IMK 热路径（spec 总边界 / ADR-0001..0003）。
//
//  布局与快捷短语不同：那页是单行表格，本页是 master-detail——左列可搜索 + 按 category 分组的
//  列表，右列多行编辑器（触发码带内联校验、标题、分类、正文 TextEditor、只读变量 chip 行）。
//
//  组件全部来自 `OwlSettingsComponents.swift`（palette-driven），随皮肤主题、尊重 Reduce
//  Motion / Transparency。并发：非 `@MainActor`-isolated（与其余设置 / 候选 UI 一致）。
//

import SwiftUI

struct OwlPromptPage: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  /// 注入的配置写入器（默认 = 实时 Owltype user_data_dir）。测试把它的 `rimeDir` 指向临时目录，
  /// 这样本页永远不写真实 `~/Library`。读取（列表 / 跨特性重码源）也走 `writer.rimeDir`。
  var writer = OwlConfigWriter()

  @State private var entries: [OwlPromptEntry] = []
  /// 现有快捷短语码，用于保存期跨特性重码校验（共享触发命名空间）。
  @State private var quickSendCodes: Set<String> = []

  // 编辑器草稿。`editingCode == nil` = 新建一条；否则在编辑该 code 的现有条目。
  @State private var editingCode: String?
  @State private var codeDraft = ""
  @State private var titleDraft = ""
  @State private var categoryDraft = ""
  @State private var bodyDraft = ""

  @State private var search = ""
  @State private var collapsedCategories: Set<String> = []
  @State private var status = ""

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      listColumn
        .frame(width: 252)
      Rectangle()
        .fill(palette.ink.opacity(0.08))
        .frame(width: 1)
      editorColumn
    }
    .onAppear(perform: reload)
  }

  // MARK: - 左列：可搜索 + 分组列表

  private var listColumn: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("提示词")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(palette.ink)
          // 列表标题；显式 a11y 标签便于辅助技术与覆盖清单识别。
          .accessibilityLabel("提示词")
        Spacer(minLength: 0)
        Button(action: importOfficialTemplates) {
          Image(systemName: "square.and.arrow.down")
            .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.accent)
        .help("导入内置模板（不覆盖你已有的条目）")
        Button(action: newDraft) {
          Label("新建", systemImage: "plus")
            .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.accent)
      }

      TextField("搜索", text: $search)
        .textFieldStyle(.roundedBorder)

      ScrollView {
        if filteredEntries.isEmpty {
          Text(entries.isEmpty ? "还没有提示词，点「新建」添加一个。" : "没有匹配的提示词。")
            .font(.system(size: 12.5))
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } else if isGrouped {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(groupedEntries, id: \.category) { group in
              groupSection(group)
            }
          }
        } else {
          VStack(spacing: 4) {
            ForEach(filteredEntries) { entry in
              entryRow(entry)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func groupSection(_ group: PromptGroup) -> some View {
    let collapsed = collapsedCategories.contains(group.category)
    return VStack(alignment: .leading, spacing: 4) {
      Button {
        toggleCollapse(group.category)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.ink3)
          Text(group.displayName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.ink2)
          Spacer(minLength: 4)
          Text("\(group.entries.count)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.ink3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !collapsed {
        ForEach(group.entries) { entry in
          entryRow(entry)
        }
      }
    }
  }

  private func entryRow(_ entry: OwlPromptEntry) -> some View {
    let selected = entry.code == editingCode
    return Button {
      select(entry)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.system(size: 13.5, weight: .medium))
          .foregroundStyle(selected ? palette.onAccent : palette.ink)
          .lineLimit(1)
        Text(entry.code)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(selected ? palette.onAccent.opacity(0.85) : palette.ink3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(palette.accent)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(entry.title)
  }

  // MARK: - 右列：编辑器

  private var editorColumn: some View {
    ScrollView {
      VStack(spacing: 20) {
        editorCard
        noteCard
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var editorCard: some View {
    SettingsCard(
      title: editingCode == nil ? "新建提示词" : "编辑提示词",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          // 方案 A（07-21 机主拍板）：字段常驻标签 + 触发码下动态用法提示。placeholder 一被填上
          // 就没人知道「docs 是要打出来的码」——尤其内置模板导入后全是已填状态，必须有静态标签。
          Text("触发码")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
            .accessibilityLabel("触发码")
          TextField("如 docs", text: $codeDraft)
            .textFieldStyle(.roundedBorder)
          if let codeError {
            Text(codeError)
              .font(.system(size: 11.5))
              .foregroundStyle(palette.accent)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if !codeDraft.trimmingCharacters(in: .whitespaces).isEmpty {
            // 动态用法提示：拿用户自己的码和标题现身说法，同时给五笔用户指面板热键那条路。
            Text("输入大写 K 后接触发码「\(codeDraft.trimmingCharacters(in: .whitespaces))」，候选条出现「📝\(titleDraft.isEmpty ? "标题" : titleDraft)」，选中即插入正文并填空。任意输入方案（含五笔）也可按快捷短语面板热键，切到「提示词」页选用。")
              .font(.system(size: 11.5))
              .foregroundStyle(palette.ink3)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("标题")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
            .accessibilityLabel("标题")
          TextField("显示在候选条上的名字", text: $titleDraft)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("分类")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
            .accessibilityLabel("分类")
          TextField("可空；用于左列分组", text: $categoryDraft)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("正文")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
            .accessibilityLabel("正文")
          TextEditor(text: $bodyDraft)
            .font(.system(size: 13))
            .frame(minHeight: 160)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.card2)
            }
            .overlay {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.12), lineWidth: 1)
            }
          Text("正文可多行；用 {{变量}} 标记占位，触发时再填空替换。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("变量")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
            .accessibilityLabel("变量")
          variableChips
        }

        HStack(spacing: 10) {
          Button(action: save) {
            Label("保存并应用", systemImage: "checkmark")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(OwlFilledButtonStyle(palette: palette))
          .disabled(!canSave)

          Button(action: delete) {
            Label("删除", systemImage: "trash")
          }
          .buttonStyle(.bordered)
          .disabled(editingCode == nil)
        }

        if !status.isEmpty {
          Text(status)
            .font(.system(size: 12))
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  /// 只读变量 chip 行：从草稿正文实时抽取 `{{…}}`（去重、保序）。
  @ViewBuilder
  private var variableChips: some View {
    let variables = OwlPromptVariables.extract(from: bodyDraft)
    if variables.isEmpty {
      Text("正文中暂无 {{变量}}。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(variables, id: \.self) { name in
            Text(name)
              .font(.system(size: 11.5, weight: .medium))
              .foregroundStyle(palette.accent)
              .padding(.horizontal, 9)
              .padding(.vertical, 3)
              .background {
                Capsule().fill(palette.accent.opacity(0.12))
              }
          }
        }
        .padding(.vertical, 1)
      }
    }
  }

  private var noteCard: some View {
    SettingsCard(title: "", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      Text("提示词正文存在本机 owl_prompts.json；触发码与快捷短语共享命名空间，保存时会校验互不重复。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 派生状态

  private var filteredEntries: [OwlPromptEntry] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return entries }
    return entries.filter {
      $0.title.lowercased().contains(needle)
        || $0.code.contains(needle)
        || $0.category.lowercased().contains(needle)
        || $0.body.lowercased().contains(needle)
    }
  }

  /// 有任意条目带非空分类时才分组显示；否则平铺。
  private var isGrouped: Bool {
    entries.contains { !$0.category.isEmpty }
  }

  private struct PromptGroup {
    let category: String
    let entries: [OwlPromptEntry]
    /// 空分类显示为「未分类」。
    var displayName: String { category.isEmpty ? "未分类" : category }
  }

  /// 按分类分组：非空分类按名升序在前，未分类（`""`）置末。
  private var groupedEntries: [PromptGroup] {
    let buckets = Dictionary(grouping: filteredEntries, by: \.category)
    return buckets.keys
      .sorted { lhs, rhs in
        if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
        return lhs < rhs
      }
      .map { PromptGroup(category: $0, entries: buckets[$0] ?? []) }
  }

  /// 触发码内联校验：格式不合法 / 与另一条提示词或某条快捷短语重复时返回错误文案。
  private var codeError: String? {
    let code = codeDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !code.isEmpty else { return nil }
    if code.range(of: #"^[a-z][a-z0-9]{0,31}$"#, options: .regularExpression) == nil {
      return OwlPromptError.invalidCode.errorDescription
    }
    if entries.contains(where: { $0.code == code && $0.code != editingCode })
        || quickSendCodes.contains(code) {
      return OwlPromptError.duplicateCode(code).errorDescription
    }
    return nil
  }

  private var canSave: Bool {
    codeError == nil
      && !codeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !bodyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - 动作

  private func reload() {
    entries = OwlPromptStore.load(rimeDir: writer.rimeDir)
    quickSendCodes = OwlPromptStore.quickSendCodes(rimeDir: writer.rimeDir)
  }

  /// 导入官方 XML 模板包（A1）：只增不改地并入现有条目，撞码的跳过，随后落盘 + 刷新列表。
  /// 从盘上重读而非信任内存 `entries`，避免并发会话改过文件后合并到过期列表。
  private func importOfficialTemplates() {
    let existing = OwlPromptStore.load(rimeDir: writer.rimeDir)
    let codes = OwlPromptStore.quickSendCodes(rimeDir: writer.rimeDir)
    let result = OwlPromptPresets.merge(into: existing, quickSendCodes: codes)
    guard !result.added.isEmpty else {
      status = "官方模板已全部导入过了。"
      return
    }
    do {
      try OwlPromptStore.save(result.merged, writer: writer)
      reload()
      status =
        result.skipped.isEmpty
        ? "已导入 \(result.added.count) 条官方模板。"
        : "已导入 \(result.added.count) 条，跳过 \(result.skipped.count) 条（触发码已被占用）。"
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func newDraft() {
    editingCode = nil
    codeDraft = ""
    titleDraft = ""
    categoryDraft = ""
    bodyDraft = ""
    status = ""
  }

  private func select(_ entry: OwlPromptEntry) {
    editingCode = entry.code
    codeDraft = entry.code
    titleDraft = entry.title
    categoryDraft = entry.category
    bodyDraft = entry.body
    status = ""
  }

  private func toggleCollapse(_ category: String) {
    if collapsedCategories.contains(category) {
      collapsedCategories.remove(category)
    } else {
      collapsedCategories.insert(category)
    }
  }

  /// 保存：跨特性重码校验后，把草稿合并进列表并原子写 `owl_prompts.json`（仅 source-of-truth）。
  private func save() {
    do {
      let entry = try OwlPromptStore.validatedEntry(
        code: codeDraft,
        title: titleDraft,
        body: bodyDraft,
        category: categoryDraft,
        quickSendCodes: quickSendCodes
      )
      if entries.contains(where: { $0.code == entry.code && $0.code != editingCode }) {
        status = OwlPromptError.duplicateCode(entry.code).errorDescription ?? ""
        return
      }
      var next = entries.filter { $0.code != entry.code && $0.code != editingCode }
      next.append(entry)
      try OwlPromptStore.save(next, writer: writer)
      entries = OwlPromptStore.load(rimeDir: writer.rimeDir)
      select(entry)
      status = "已保存提示词。"
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func delete() {
    guard let editingCode else { return }
    do {
      let next = entries.filter { $0.code != editingCode }
      try OwlPromptStore.save(next, writer: writer)
      entries = OwlPromptStore.load(rimeDir: writer.rimeDir)
      newDraft()
      status = "已删除提示词。"
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }
}
