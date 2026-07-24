//
//  FamoClipboardPage.swift
//  法墨输入法 (Famo) — 剪贴板 (Clipboard) settings page + store
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

struct FamoClipboardEntry: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let text: String
  let createdAt: Date

  init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
  }
}

enum FamoClipboardError: LocalizedError, Equatable {
  case emptyText

  var errorDescription: String? {
    switch self {
    case .emptyText: return "当前剪贴板没有可捕获的纯文本。"
    }
  }
}

enum FamoClipboardStore {
  static let enabledKey = "FamoClipboardPanelEnabled"
  static let fileName = "clipboard-history.json"
  static let maxEntries = 20
  static let maxCharacters = 2_000

  static func isEnabled(defaults: UserDefaults = FamoDefaults.standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }

  static func setEnabled(_ value: Bool, defaults: UserDefaults = FamoDefaults.standard) {
    defaults.set(value, forKey: enabledKey)
  }

  static func fileURL(root: URL = FamoApp.userDir) -> URL {
    // Sits directly in the Famo user dir, like its siblings (learn-log.json, projects/…).
    root.appendingPathComponent(fileName)
  }

  /// Pre-fix location: history used to nest under a redundant `famo/` subdir inside the already-Famo
  /// user dir (`.../Famo/famo/clipboard-history.json`). Read from here when the canonical file is
  /// absent so an in-place upgrade doesn't orphan existing history.
  /// ponytail: legacy-read fallback; drop once installs have rolled past this release.
  static func legacyFileURL(root: URL = FamoApp.userDir) -> URL {
    root.appendingPathComponent("famo", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  static func load(root: URL = FamoApp.userDir) -> [FamoClipboardEntry] {
    let url = fileURL(root: root)
    let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: legacyFileURL(root: root)))
    guard let data, let decoded = try? JSONDecoder().decode([FamoClipboardEntry].self, from: data) else {
      return []
    }
    return normalized(decoded)
  }

  static func save(_ entries: [FamoClipboardEntry], root: URL = FamoApp.userDir) throws {
    let url = fileURL(root: root)
    try FamoPrivateStorage.prepareDirectory(url.deletingLastPathComponent())
    let data = try JSONEncoder().encode(normalized(entries))
    try data.write(to: url, options: .atomic)
    try FamoPrivateStorage.hardenFile(url)
    // Migrated forward: drop the stale legacy copy so it can't shadow a later read.
    try? FileManager.default.removeItem(at: legacyFileURL(root: root))
  }

  static func capture(_ rawText: String?, root: URL = FamoApp.userDir, now: Date = Date()) throws -> [FamoClipboardEntry] {
    let text = clean(rawText)
    guard !text.isEmpty else { throw FamoClipboardError.emptyText }
    let entry = FamoClipboardEntry(text: text, createdAt: now)
    let next = [entry] + load(root: root).filter { $0.text != text }
    try save(next, root: root)
    return load(root: root)
  }

  static func clear(root: URL = FamoApp.userDir) throws {
    let url = fileURL(root: root)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    // Also drop any pre-fix nested copy so clearing leaves nothing behind.
    try? FileManager.default.removeItem(at: legacyFileURL(root: root))
  }

  static func normalized(_ entries: [FamoClipboardEntry]) -> [FamoClipboardEntry] {
    var seen = Set<String>()
    var out: [FamoClipboardEntry] = []
    for entry in entries {
      let text = clean(entry.text)
      guard !text.isEmpty, !seen.contains(text) else { continue }
      seen.insert(text)
      out.append(FamoClipboardEntry(id: entry.id, text: text, createdAt: entry.createdAt))
      if out.count == maxEntries { break }
    }
    return out
  }

  private static func clean(_ rawText: String?) -> String {
    String((rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
  }
}

// MARK: - 剪贴板

struct FamoClipboardPage: View {
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool

  @State private var enabled = FamoClipboardStore.isEnabled()
  @State private var entries = FamoClipboardStore.load()
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
    .onAppear {
      enabled = FamoClipboardStore.isEnabled()
      entries = FamoClipboardStore.load()
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
            status = FamoSettingsActions.setClipboardEnabled(!enabled) {
              enabled = $0
              FamoClipboardStore.setEnabled($0)
            }
          }
        )
        SettingsCardDivider(palette: palette)
        Text("历史只保存在本机 Famo 目录；不同步，也不会进入云端 AI 或本地模型请求。")
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
          .buttonStyle(FamoFilledButtonStyle(palette: palette))
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
      let result = try FamoSettingsActions.captureClipboard(
        enabled: enabled,
        text: NSPasteboard.general.string(forType: .string)
      ) {
        try FamoClipboardStore.capture($0)
      }
      if let next = result.entries { entries = next }
      status = result.status
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  private func clearAll() {
    do {
      let result = try FamoSettingsActions.clearClipboard {
        try FamoClipboardStore.clear()
      }
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
