//
//  OwlQuickSendPage.swift
//  法墨输入法 (Owltype) — 快捷短语 (Quick Send) settings page + store
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

struct OwlQuickSendEntry: Identifiable, Equatable, Sendable, Codable {
  let text: String
  let code: String
  var id: String { code }
}

enum OwlQuickSendError: LocalizedError, Equatable {
  case invalidText
  case invalidCode

  var errorDescription: String? {
    switch self {
    case .invalidText: return "短语不能为空，且不能包含换行或 Tab。"
    case .invalidCode: return "编码只能是小写字母开头的字母或数字。"
    }
  }
}

/// 存储边界（镜像 `OwlPromptStore`，单源单向）：`famo_quick_send.json` 是 source of truth，
/// `load` 只读它；`famo_quick_send.txt` 是从 entries **派生**的 Rime 表（每条
/// `text \t code \t score`），只写不回读。历史教训：旧版把派生表当存储回读，防撞用的
/// `v{code}` 行被当成真条目，每次保存再派生一层 `v`，条目滚雪球直到触发码撞上 32 字符上限
/// （2026-07 修复）。旧安装无 JSON 时 `load` 走一次性迁移：解析派生表并折叠 v 链，下次
/// `save` 落 JSON。
enum OwlQuickSendStore {
  /// source of truth（text·code）。`load` 只读它。
  static let fileName = "famo_quick_send.json"
  /// 派生的 Rime 表文件名。`load` 不读它（仅旧格式迁移时读一次）——它只是 JSON 的投影。
  static let dictFileName = "famo_quick_send.txt"

  static func load(rimeDir: URL = OwlApp.userDir) -> [OwlQuickSendEntry] {
    let url = rimeDir.appendingPathComponent(fileName)
    if let data = try? Data(contentsOf: url),
       let decoded = try? JSONDecoder().decode([OwlQuickSendEntry].self, from: data) {
      let valid = decoded.compactMap { try? entry(text: $0.text, code: $0.code) }
      return (try? normalized(valid)) ?? valid
    }
    return legacyEntries(rimeDir: rimeDir)
  }

  /// 旧格式（JSON 之前，派生表兼作存储）的一次性迁移读取：解析 `dictFileName` 各行，再折叠
  /// 滚雪球出来的 v 链。只在 JSON 缺失时走到；随后的 `save` 落 JSON，此路径不再命中。
  private static func legacyEntries(rimeDir: URL) -> [OwlQuickSendEntry] {
    let url = rimeDir.appendingPathComponent(dictFileName)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let parsed = text.split(separator: "\n").compactMap { line -> OwlQuickSendEntry? in
      let raw = String(line)
      guard !raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
      let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count >= 2 else { return nil }
      return try? entry(text: String(parts[0]), code: String(parts[1]))
    }
    return collapsingLegacyVariants(parsed)
  }

  /// 折叠旧格式回读出的防撞变体：同文本且 code == "v" + 另一条的 code ⇒ 该条是派生行，丢弃。
  /// 链（`vv…`）逐级命中上一级同样被丢；基础码已被删掉的孤儿链保最短码。真实以 v 开头但文本
  /// 不同的用户码不受影响。
  static func collapsingLegacyVariants(_ entries: [OwlQuickSendEntry]) -> [OwlQuickSendEntry] {
    let deduped = (try? normalized(entries)) ?? entries
    var textByCode: [String: String] = [:]
    for item in deduped { textByCode[item.code] = item.text }
    return deduped.filter { item in
      guard item.code.hasPrefix("v") else { return true }
      return textByCode[String(item.code.dropFirst())] != item.text
    }
  }

  static func entry(text rawText: String, code rawCode: String) throws -> OwlQuickSendEntry {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty, !text.contains("\n"), !text.contains("\t") else { throw OwlQuickSendError.invalidText }
    guard code.range(of: #"^[a-z][a-z0-9]{0,31}$"#, options: .regularExpression) != nil else {
      throw OwlQuickSendError.invalidCode
    }
    return OwlQuickSendEntry(text: text, code: code)
  }

  /// 原子写三件（经 `OwlConfigWriter`：备份 + manifest + 回滚），镜像 `OwlPromptStore.save`：
  ///   1. `famo_quick_send.json` —— source of truth（先严格归一，非法即抛，再编码 JSON）。
  ///   2. `famo_quick_send.txt`  —— 从同一批 entries 派生的 Rime 表（每次保存全量重生成）。
  ///   3. `rime_ice.custom.yaml` patch —— 注册 `table_translator@famo_quick_send`。
  /// 三者同一 `timestamp`（同一回滚批次，rollback 会一起还原）。
  static func save(
    _ entries: [OwlQuickSendEntry],
    writer: OwlConfigWriter = OwlConfigWriter(),
    timestamp: String? = nil
  ) throws {
    let ts = timestamp ?? timestampNow()
    let clean = try normalized(entries)
    try writer.applyTextFile(
      fileName: fileName,
      contents: try render(clean),
      marker: OwlManagedMarker.quickSendJSONFile,
      timestamp: ts
    )
    try writer.applyTextFile(
      fileName: dictFileName,
      contents: renderDict(clean),
      marker: OwlManagedMarker.quickSendFile,
      timestamp: ts
    )
    try writer.apply(fileName: "rime_ice.custom.yaml", block: rimeIcePatchBlock, timestamp: ts)
  }

  /// 启动期幂等迁移（对齐 `setupRime` 里键盘托管块的「每次启动重写」先例）：派生表与
  /// rime_ice patch 只在 `save()` 里重写，而 `save()` 只有用户在设置页动过短语才会跑——
  /// 1.5.2 把短语码改成 ` 前缀 + 关前缀补全后，升级用户如果从不重新保存，旧派生表
  /// （裸码 + enable_completion: true + initial_quality: 100）会永远生效，打一个 y 照旧
  /// 弹 CLI 短语（2026-07-26 真机复现）。这里把 source of truth 重放一遍 `save()`：
  /// `OwlConfigWriter.writeManagedFile` 在内容一致时零写入，所以已同步时本函数只读不写；
  /// 不同步时走一次完整原子写（备份 + manifest 照常）。JSON 与派生表都不存在（从未用过
  /// 快捷短语）则不落任何文件——不给没用过该功能的用户注册 translator。
  static func migrateDerivedArtifactsIfNeeded(rimeDir: URL = OwlApp.userDir) {
    let fm = FileManager.default
    let hasJSON = fm.fileExists(atPath: rimeDir.appendingPathComponent(fileName).path)
    let hasDict = fm.fileExists(atPath: rimeDir.appendingPathComponent(dictFileName).path)
    guard hasJSON || hasDict else { return }
    do {
      // 独立后缀防备份撞车：启动期键盘托管块 apply 与本迁移可能同一秒内先后写
      // rime_ice.custom.yaml，裸 yyyyMMdd-HHmmss 会让两个批次共用同一个
      // .famo-backup/<ts>/ 目录——第二次备份覆盖第一次，rollback 只能还原到
      // 键盘写完后的中间态而非启动前原状（PR #42 评审逮住）。
      try save(
        load(rimeDir: rimeDir),
        writer: OwlConfigWriter(rimeDir: rimeDir),
        timestamp: timestampNow() + "-quicksend-migration"
      )
    } catch {
      print("Owltype: quick-send derived-artifact migration failed: \(error)")
    }
  }

  private static var rimeIcePatchBlock: ManagedPatchBlock {
    ManagedPatchBlock(
      marker: OwlManagedMarker.quickSendRimeIce,
      yamlLinesIndentedUnderPatch: [
        "  # 快捷短语：Owltype-owned table_translator，不读取用户 custom_phrase.txt",
        "  # 参数对齐 rime-ice 自带 custom_phrase（completion=false / quality=99）：",
        "  # enable_completion 必须为 false：开着的话短语码会被前缀补全命中——码 yocc 的短语，",
        "  # 只打一个 y 就挤进候选（2026-07-25 实测：y → 三条 CLI 短语压在 有/用/言 前面）。",
        "  # initial_quality: 99：码打全时短语要置顶可上屏（这就是快捷短语的用途）；码不全时",
        "  # 因 completion=false 根本不出候选，不存在盖过常用字的问题。",
        "  # 历史教训（2026-07-26 探针实证）：1.5.2 曾给短语码加 ` 前缀求彻底隔离，但 ` 是",
        "  # rime-ice 拆字辅助码的引导键（key_binder/search + search.lua），前导 ` 会把输入切段，",
        "  # 带前缀的码永远到不了本 translator——短语从此无法触发。别再用 ` 当前缀。",
        "  \"engine/translators/+\":",
        "    - table_translator@famo_quick_send",
        "  famo_quick_send:",
        "    dictionary: \"\"",
        "    user_dict: famo_quick_send",
        "    db_class: stabledb",
        "    enable_completion: false",
        "    enable_sentence: false",
        "    initial_quality: 99",
      ]
    )
  }

  private static func normalized(_ entries: [OwlQuickSendEntry]) throws -> [OwlQuickSendEntry] {
    var out: [OwlQuickSendEntry] = []
    for item in entries {
      let clean = try entry(text: item.text, code: item.code)
      if let existing = out.firstIndex(where: { $0.code == clean.code }) {
        out[existing] = clean
      } else {
        out.append(clean)
      }
    }
    return out.sorted { $0.code < $1.code }
  }

  /// 编码为稳定（排序键 + 美化）JSON 文本，末尾补换行。
  private static func render(_ entries: [OwlQuickSendEntry]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(entries)
    return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
  }

  /// 从（已归一的）entries 派生 Rime 表文本。每条一行：`text \t code \t 100000`。
  /// 此文件只写不回读（见类型文档）。
  ///
  /// 码就是裸码，不带任何前缀。两代防撞方案双双证伪：2026-07 的 `v{code}` 变体行会滚雪球
  /// （见类型文档），1.5.2 的 ` 前缀撞上 rime-ice 拆字辅助码引导键、短语彻底无法触发
  /// （见 rimeIcePatchBlock 注释）。防「打一半就冒出来」靠 enable_completion: false；
  /// 码撞常用简拼的风险由用户选码时自行规避（与 rime-ice custom_phrase 同一约定）。
  /// 元数据行键值以 TAB 分隔（librime tsv.cc 的 #@ 语法），空格会报 invalid metadata 告警。
  private static func renderDict(_ entries: [OwlQuickSendEntry]) -> String {
    var lines = [
      "# Rime table",
      "# coding: utf-8",
      "#@/db_name\tfamo_quick_send",
      "#@/db_type\ttabledb",
      "# Owltype quick-send phrases. Managed by 法墨输入法 settings.",
      "# 触发：打全短语码，短语置顶。",
      "",
    ]
    for entry in entries {
      lines.append("\(entry.text)\t\(entry.code)\t100000")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func timestampNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }
}

/// A built-in quick-send *example*: an AI coding agent's "skip all permission prompts" (YOLO)
/// launch command, fronted by a short trigger code. Pure static data — never persisted and never
/// deployed by default. The user must tick one in 快捷短语 to merge its `entry` into the live
/// `OwlQuickSendStore` list (same add/remove path as a hand-typed phrase).
struct OwlQuickSendExample: Identifiable, Sendable {
  let tool: String          // e.g. "Claude Code"
  let entry: OwlQuickSendEntry  // text = command, code = trigger
  let note: String          // short caution / description
  var id: String { entry.code }
}

enum OwlQuickSendExamples {
  /// Only commands with official documentation are listed; no fabricated bypass flags (e.g. MiMo /
  /// 小米 has no documented YOLO flag, so it is intentionally omitted).
  static let all: [OwlQuickSendExample] = [
    OwlQuickSendExample(
      tool: "Claude Code",
      entry: OwlQuickSendEntry(text: "claude --dangerously-skip-permissions", code: "yocc"),
      note: "跳过所有权限确认"
    ),
    OwlQuickSendExample(
      tool: "Codex",
      entry: OwlQuickSendEntry(text: "codex --dangerously-bypass-approvals-and-sandbox", code: "yocx"),
      note: "绕过审批与沙箱"
    ),
    OwlQuickSendExample(
      tool: "Qoder",
      entry: OwlQuickSendEntry(text: "qodercli --yolo", code: "yoqd"),
      note: "YOLO 自动批准"
    ),
    OwlQuickSendExample(
      tool: "Kimi",
      entry: OwlQuickSendEntry(text: "kimi --yolo", code: "yokm"),
      note: "YOLO 自动批准"
    ),
    OwlQuickSendExample(
      tool: "Grok",
      entry: OwlQuickSendEntry(text: "grok --always-approve", code: "yogk"),
      note: "自动批准"
    ),
  ]
}

// MARK: - 快捷短语

struct OwlQuickSendPage: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool
  let onRedeploy: () -> Bool

  @State private var entries = OwlQuickSendStore.load()
  @State private var phrase = ""
  @State private var code = ""
  @State private var editingCode: String?
  @State private var status = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        editorCard
        examplesCard
        listCard
        noteCard
      }
      .padding(20)
    }
    .onAppear { entries = OwlQuickSendStore.load() }
  }

  private var editorCard: some View {
    SettingsCard(title: "添加 / 编辑", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 12) {
        TextField("短语", text: $phrase)
          .textFieldStyle(.roundedBorder)
        TextField("编码，如 fm 或 fmcs", text: $code)
          .textFieldStyle(.roundedBorder)
        HStack(spacing: 10) {
          Button(action: saveEntry) {
            Label(editingCode == nil ? "添加短语" : "保存修改", systemImage: "checkmark")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(OwlFilledButtonStyle(palette: palette))
          Button(action: clearEditor) {
            Label("清空", systemImage: "xmark")
          }
          .buttonStyle(.bordered)
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

  /// Built-in examples — each AI agent's "skip all permission prompts" launch command. All off by
  /// default; a checked row merges the example's entry into the live list (and unchecking removes
  /// it), reusing the same save + redeploy path as a hand-typed phrase. No persisted enable flag.
  private var examplesCard: some View {
    SettingsCard(title: "示例（默认未启用）", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 0) {
        Text("以下为示例，默认未启用；勾选后才写入生效。这些命令会跳过对应 AI agent 的全部权限确认，请自行评估风险。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, 4)
        ForEach(OwlQuickSendExamples.all) { example in
          SettingsCardDivider(palette: palette)
          exampleRow(example)
        }
      }
    }
  }

  private func exampleRow(_ example: OwlQuickSendExample) -> some View {
    let isOn = entries.contains { $0.code == example.entry.code }
    return Button(action: { toggleExample(example, on: !isOn) }) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(example.tool)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(palette.ink)
          Text(example.entry.text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 6) {
            // The trigger IS the bare code, typed in full (enable_completion is off, so a
            // partial code shows nothing). No prefix — see renderDict for why both prefix
            // schemes (`v` variant rows, ` lead) were retired.
            Text(example.entry.code)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(palette.ink3)
            Text(example.note)
              .font(.system(size: 11.5))
              .foregroundStyle(palette.ink3)
          }
        }
        Spacer(minLength: 8)
        OwlPillToggle(isOn: isOn, palette: palette)
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(example.tool)
  }

  private var listCard: some View {
    SettingsCard(title: "本地短语", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      if entries.isEmpty {
        Text("还没有快捷短语。")
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          ForEach(entries) { entry in
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                  .font(.system(size: 13.5, weight: .medium))
                  .foregroundStyle(palette.ink)
                Text(entry.code)
                  .font(.system(size: 11.5, design: .monospaced))
                  .foregroundStyle(palette.ink3)
              }
              Spacer(minLength: 8)
              Button(action: { edit(entry) }) {
                Image(systemName: "pencil")
              }
              .buttonStyle(.borderless)
              Button(action: { delete(entry) }) {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 8)
            if entry.id != entries.last?.id {
              SettingsCardDivider(palette: palette)
            }
          }
        }
      }
    }
  }

  private var noteCard: some View {
    SettingsCard(title: "", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      Text("这里添加的是 Owltype 本地快捷短语，只影响本页列表，不会改动其他词库。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func saveEntry() {
    do {
      let result = try OwlSettingsActions.saveQuickSendEntry(
        phrase: phrase,
        code: code,
        editingCode: editingCode,
        entries: entries,
        persist: persist
      )
      entries = result.entries
      phrase = result.phrase
      code = result.code
      editingCode = result.editingCode
      status = result.status
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func edit(_ entry: OwlQuickSendEntry) {
    phrase = entry.text
    code = entry.code
    editingCode = entry.code
    status = ""
  }

  private func delete(_ entry: OwlQuickSendEntry) {
    do {
      let result = try OwlSettingsActions.deleteQuickSendEntry(
        entry,
        editingCode: editingCode,
        entries: entries,
        persist: persist
      )
      entries = result.entries
      if let phrase = result.phrase { self.phrase = phrase }
      if let code = result.code { self.code = code }
      editingCode = result.editingCode
      status = result.status
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func clearEditor() {
    phrase = ""
    code = ""
    editingCode = nil
  }

  /// Tick / untick a built-in example. ON merges its entry (replacing any same code); OFF removes
  /// the code. Both go through the same `persist` (save + reload + redeploy) as a hand-typed phrase.
  private func toggleExample(_ example: OwlQuickSendExample, on: Bool) {
    do {
      var next = entries.filter { $0.code != example.entry.code }
      if on { next.append(example.entry) }
      let persisted = try persist(next)
      entries = persisted.0
      status = on
        ? (persisted.1 ? "已启用示例并应用配置改动。" : "已启用示例；应用配置失败，请查看诊断日志。")
        : (persisted.1 ? "已停用示例并应用配置改动。" : "已停用示例；应用配置失败，请查看诊断日志。")
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func persist(_ next: [OwlQuickSendEntry]) throws -> ([OwlQuickSendEntry], Bool) {
    try OwlQuickSendStore.save(next)
    return (OwlQuickSendStore.load(), onRedeploy())
  }
}
