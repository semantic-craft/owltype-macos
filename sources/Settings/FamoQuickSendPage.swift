//
//  FamoQuickSendPage.swift
//  法墨输入法 (Famo) — 快捷短语 (Quick Send) settings page + store
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

struct FamoQuickSendEntry: Identifiable, Equatable, Sendable {
  let text: String
  let code: String
  var id: String { code }
}

enum FamoQuickSendError: LocalizedError, Equatable {
  case invalidText
  case invalidCode

  var errorDescription: String? {
    switch self {
    case .invalidText: return "短语不能为空，且不能包含换行或 Tab。"
    case .invalidCode: return "编码只能是小写字母开头的字母或数字。"
    }
  }
}

enum FamoQuickSendStore {
  static let fileName = "famo_quick_send.txt"

  static func load(rimeDir: URL = FamoApp.userDir) -> [FamoQuickSendEntry] {
    let url = rimeDir.appendingPathComponent(fileName)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
      let raw = String(line)
      guard !raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
      let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count >= 2 else { return nil }
      return try? entry(text: String(parts[0]), code: String(parts[1]))
    }
  }

  static func entry(text rawText: String, code rawCode: String) throws -> FamoQuickSendEntry {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty, !text.contains("\n"), !text.contains("\t") else { throw FamoQuickSendError.invalidText }
    guard code.range(of: #"^[a-z][a-z0-9]{0,31}$"#, options: .regularExpression) != nil else {
      throw FamoQuickSendError.invalidCode
    }
    return FamoQuickSendEntry(text: text, code: code)
  }

  static func save(
    _ entries: [FamoQuickSendEntry],
    writer: FamoConfigWriter = FamoConfigWriter(),
    timestamp: String? = nil
  ) throws {
    let ts = timestamp ?? timestampNow()
    let clean = try normalized(entries)
    try writer.applyTextFile(
      fileName: fileName,
      contents: render(clean),
      marker: FamoManagedMarker.quickSendFile,
      timestamp: ts
    )
    try writer.apply(fileName: "rime_ice.custom.yaml", block: rimeIcePatchBlock, timestamp: ts)
  }

  private static var rimeIcePatchBlock: ManagedPatchBlock {
    ManagedPatchBlock(
      marker: FamoManagedMarker.quickSendRimeIce,
      yamlLinesIndentedUnderPatch: [
        "  # 快捷短语：Famo-owned table_translator，不读取用户 custom_phrase.txt",
        "  \"engine/translators/+\":",
        "    - table_translator@famo_quick_send",
        "  famo_quick_send:",
        "    dictionary: \"\"",
        "    user_dict: famo_quick_send",
        "    db_class: stabledb",
        "    enable_completion: true",
        "    enable_sentence: false",
        "    initial_quality: 100",
      ]
    )
  }

  private static func normalized(_ entries: [FamoQuickSendEntry]) throws -> [FamoQuickSendEntry] {
    var out: [FamoQuickSendEntry] = []
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

  private static func render(_ entries: [FamoQuickSendEntry]) -> String {
    var lines = [
      "# Rime table",
      "# coding: utf-8",
      "#@/db_name famo_quick_send",
      "#@/db_type tabledb",
      "# Famo quick-send phrases. Managed by 法墨输入法 settings.",
      "",
    ]
    for entry in entries {
      lines.append("\(entry.text)\t\(entry.code)\t100000")
      lines.append("\(entry.text)\tv\(entry.code)\t100000")
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
/// `FamoQuickSendStore` list (same add/remove path as a hand-typed phrase).
struct FamoQuickSendExample: Identifiable, Sendable {
  let tool: String          // e.g. "Claude Code"
  let entry: FamoQuickSendEntry  // text = command, code = trigger
  let note: String          // short caution / description
  var id: String { entry.code }
}

enum FamoQuickSendExamples {
  /// Only commands with official documentation are listed; no fabricated bypass flags (e.g. MiMo /
  /// 小米 has no documented YOLO flag, so it is intentionally omitted).
  static let all: [FamoQuickSendExample] = [
    FamoQuickSendExample(
      tool: "Claude Code",
      entry: FamoQuickSendEntry(text: "claude --dangerously-skip-permissions", code: "yocc"),
      note: "跳过所有权限确认"
    ),
    FamoQuickSendExample(
      tool: "Codex",
      entry: FamoQuickSendEntry(text: "codex --dangerously-bypass-approvals-and-sandbox", code: "yocx"),
      note: "绕过审批与沙箱"
    ),
    FamoQuickSendExample(
      tool: "Qwen Code",
      entry: FamoQuickSendEntry(text: "qwen --yolo", code: "yoqw"),
      note: "YOLO 自动批准"
    ),
    FamoQuickSendExample(
      tool: "Kimi",
      entry: FamoQuickSendEntry(text: "kimi --yolo", code: "yokm"),
      note: "YOLO 自动批准"
    ),
    FamoQuickSendExample(
      tool: "Grok",
      entry: FamoQuickSendEntry(text: "grok --always-approve", code: "yogk"),
      note: "自动批准"
    ),
    FamoQuickSendExample(
      tool: "Antigravity",
      entry: FamoQuickSendEntry(text: "agy --dangerously-skip-permissions", code: "yoag"),
      note: "新工具，建议 agy --help 复核"
    ),
  ]
}

// MARK: - 快捷短语

struct FamoQuickSendPage: View {
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool
  let onRedeploy: () -> Bool

  @State private var entries = FamoQuickSendStore.load()
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
    .onAppear { entries = FamoQuickSendStore.load() }
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
          .buttonStyle(FamoFilledButtonStyle(palette: palette))
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
        ForEach(FamoQuickSendExamples.all) { example in
          SettingsCardDivider(palette: palette)
          exampleRow(example)
        }
      }
    }
  }

  private func exampleRow(_ example: FamoQuickSendExample) -> some View {
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
            // Display the `v`-prefixed variant — rime-ice routes the `v` lead to English/non-pinyin,
            // so this is the collision-proof trigger the user actually types. The stored
            // `entry.code` stays the base code (the store auto-generates the `v` variant).
            Text("v\(example.entry.code)")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(palette.ink3)
            Text("\(example.note)（基础码 \(example.entry.code) 亦可）")
              .font(.system(size: 11.5))
              .foregroundStyle(palette.ink3)
          }
        }
        Spacer(minLength: 8)
        FamoPillToggle(isOn: isOn, palette: palette)
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
      Text("这里添加的是 Famo 本地快捷短语，只影响本页列表，不会改动其他词库。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func saveEntry() {
    do {
      let result = try FamoSettingsActions.saveQuickSendEntry(
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

  private func edit(_ entry: FamoQuickSendEntry) {
    phrase = entry.text
    code = entry.code
    editingCode = entry.code
    status = ""
  }

  private func delete(_ entry: FamoQuickSendEntry) {
    do {
      let result = try FamoSettingsActions.deleteQuickSendEntry(
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
  private func toggleExample(_ example: FamoQuickSendExample, on: Bool) {
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

  private func persist(_ next: [FamoQuickSendEntry]) throws -> ([FamoQuickSendEntry], Bool) {
    try FamoQuickSendStore.save(next)
    return (FamoQuickSendStore.load(), onRedeploy())
  }
}
