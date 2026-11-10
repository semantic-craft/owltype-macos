//
//  OwlClipboardPage.swift
//  猫头鹰输入法 (Owltype) — 剪贴板 (Clipboard) settings page + store
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

struct OwlClipboardEntry: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let text: String
  let createdAt: Date

  init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
  }
}

enum OwlClipboardError: LocalizedError, Equatable {
  case emptyText

  var errorDescription: String? {
    switch self {
    case .emptyText: return "当前剪贴板没有可捕获的纯文本。"
    }
  }
}

enum OwlClipboardStore {
  static let enabledKey = "OwlClipboardPanelEnabled"
  static let fileName = "clipboard-history.json"
  static let maxEntries = 20
  static let maxCharacters = 2_000

  static func isEnabled(defaults: UserDefaults = OwlDefaults.standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }

  static func setEnabled(_ value: Bool, defaults: UserDefaults = OwlDefaults.standard) {
    defaults.set(value, forKey: enabledKey)
  }

  static func fileURL(root: URL = OwlApp.userDir) -> URL {
    // Sits directly in the Owltype user dir, like its siblings (learn-log.json, projects/…).
    root.appendingPathComponent(fileName)
  }

  static func load(root: URL = OwlApp.userDir) -> [OwlClipboardEntry] {
    let url = fileURL(root: root)
    let data = try? Data(contentsOf: url)
    guard let data, let decoded = try? JSONDecoder().decode([OwlClipboardEntry].self, from: data) else {
      return []
    }
    return normalized(decoded)
  }

  static func save(_ entries: [OwlClipboardEntry], root: URL = OwlApp.userDir) throws {
    let url = fileURL(root: root)
    try OwlPrivateStorage.prepareDirectory(url.deletingLastPathComponent())
    let data = try JSONEncoder().encode(normalized(entries))
    try data.write(to: url, options: .atomic)
    try OwlPrivateStorage.hardenFile(url)
  }

  static func capture(_ rawText: String?, root: URL = OwlApp.userDir, now: Date = Date()) throws -> [OwlClipboardEntry] {
    let text = clean(rawText)
    guard !text.isEmpty else { throw OwlClipboardError.emptyText }
    let entry = OwlClipboardEntry(text: text, createdAt: now)
    let next = [entry] + load(root: root).filter { $0.text != text }
    try save(next, root: root)
    return load(root: root)
  }

  static func clear(root: URL = OwlApp.userDir) throws {
    let url = fileURL(root: root)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  static func normalized(_ entries: [OwlClipboardEntry]) -> [OwlClipboardEntry] {
    var seen = Set<String>()
    var out: [OwlClipboardEntry] = []
    for entry in entries {
      let text = clean(entry.text)
      guard !text.isEmpty, !seen.contains(text) else { continue }
      seen.insert(text)
      out.append(OwlClipboardEntry(id: entry.id, text: text, createdAt: entry.createdAt))
      if out.count == maxEntries { break }
    }
    return out
  }

  private static func clean(_ rawText: String?) -> String {
    String((rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
  }
}

// MARK: - 剪贴板

struct OwlClipboardPage: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  @State private var enabled = OwlClipboardStore.isEnabled()
  @State private var entries: [OwlClipboardEntry] = []
  @State private var historyEdited = false
  @State private var status = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        privacyCard
        actionsCard
        historyCard
      }
      .padding(20)
    }
    .task {
      let history = await Task.detached(priority: .utility) { OwlClipboardStore.load() }.value
      guard !Task.isCancelled, !historyEdited else { return }
      entries = history
    }
  }

  private var privacyCard: some View {
    SettingsCard(title: "本地剪贴板", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 12) {
        SettingsToggleRow(
          title: "启用剪贴板面板",
          isOn: enabled,
          palette: palette,
          onToggle: {
            status = OwlSettingsActions.setClipboardEnabled(!enabled) {
              enabled = $0
              OwlClipboardStore.setEnabled($0)
            }
          }
        )
        SettingsCardDivider(palette: palette)
        Text("历史只保存在本机 Owltype 目录；不同步，也不会进入云端 AI 或本地模型请求。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var actionsCard: some View {
    SettingsCard(title: "操作", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Button(action: captureCurrentPasteboard) {
            Label("捕获当前剪贴板", systemImage: "plus")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(OwlFilledButtonStyle(palette: palette))
          .disabled(!enabled)

          Button(action: clearAll) {
            Label("清空记录", systemImage: "trash")
          }
          .buttonStyle(.bordered)
          .disabled(entries.isEmpty)
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

  private var historyCard: some View {
    SettingsCard(title: "本地历史", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      if entries.isEmpty {
        Text("还没有剪贴板记录。")
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 5) {
              Text(entry.text)
                .font(.system(size: 13.5))
                .foregroundStyle(palette.ink)
                .lineLimit(3)
                .textSelection(.enabled)
              Text(Self.dateFormatter.string(from: entry.createdAt))
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            if entry.id != entries.last?.id {
              SettingsCardDivider(palette: palette)
            }
          }
        }
      }
    }
  }

  private func captureCurrentPasteboard() {
    guard enabled else {
      status = "先启用剪贴板面板。"
      return
    }
    do {
      let result = try OwlSettingsActions.captureClipboard(
        enabled: enabled,
        text: NSPasteboard.general.string(forType: .string)
      ) {
        try OwlClipboardStore.capture($0)
      }
      if let next = result.entries {
        historyEdited = true
        entries = next
      }
      status = result.status
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func clearAll() {
    do {
      let result = try OwlSettingsActions.clearClipboard {
        try OwlClipboardStore.clear()
      }
      historyEdited = true
      entries = result.entries
      status = result.status
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()
}
