//
//  OwlQuickSendPage.swift
//  猫头鹰输入法 (Owltype) — 快捷短语 (Quick Send) settings page + store
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

/// 存储边界（镜像 `OwlPromptStore`，单源单向）：`owl_quick_send.json` 是 source of truth，
/// `load` 只读它；`owl_quick_send.txt` 是从 entries **派生**的 Rime 表（每条
/// `text \t code \t score`），只写不回读。历史教训：旧版把派生表当存储回读，防撞用的
/// `v{code}` 行被当成真条目，每次保存再派生一层 `v`，条目滚雪球直到触发码撞上 32 字符上限
/// （2026-07 修复）。旧安装无 JSON 时 `load` 走一次性迁移：解析派生表并折叠 v 链，下次
/// `save` 落 JSON。
enum OwlQuickSendStore {
  static let fileName = "owl_quick_send.json"
  static let dictFileName = "owl_quick_send.txt"
  static func load(dataDir: URL = OwlApp.userDir) -> [OwlQuickSendEntry] {
    (try? OwlStorageHost(dataDir: dataDir).call("quick_load")) ?? []
  }
  static func collapsingLegacyVariants(_ entries: [OwlQuickSendEntry]) -> [OwlQuickSendEntry] {
    OwlTemplateStore.core("quick_collapse", ["entries": OwlAppCore.payload(entries)])
  }
  static func entry(text: String, code: String) throws -> OwlQuickSendEntry {
    try OwlAppCore.call(["operation": "quick_entry", "entry": OwlAppCore.payload(OwlQuickSendEntry(text: text, code: code))])
  }
  static func save(_ entries: [OwlQuickSendEntry], writer: OwlConfigWriter = OwlConfigWriter(), timestamp: String? = nil) throws {
    let _: Bool = try OwlStorageHost(dataDir: writer.dataDir, writerCheckpoint: writer.writeCheckpoint).call("quick_save", ["entries": OwlAppCore.payload(entries), "timestamp": timestamp ?? timestampNow()])
  }
  static func migrateDerivedArtifactsIfNeeded(dataDir: URL = OwlApp.userDir) {
    do { let _: Bool = try OwlStorageHost(dataDir: dataDir).call("quick_migrate", ["timestamp": timestampNow()]) }
    catch { print("Owltype: quick-send derived-artifact migration failed: \(error)") }
  }
  private static func timestampNow() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
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
  /// Only commands with official documentation are listed; no fabricated bypass flags.
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
        TextField("编码，如 mty 或 mtycs", text: $code)
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
            // Stored codes remain unchanged; native K mode is the explicit candidate entry.
            // Legacy Rime projection details are documented in renderDict; both prefix
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
      Text("输入大写 K 后接编码，再选择快捷短语；也可从快捷短语面板选用。这里的内容不会混入普通拼音候选。")
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
