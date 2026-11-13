//
//  OwlAgentPage.swift
//  Owltype
//
//  设置 → Agent 接入 (#208): the switch, which templates agents may read, the configuration a
//  user pastes into Antigravity CLI or Grok Build, and the redacted call log. `OwlAgentSettings` holds the logic so
//  tests can drive it without the view.
//

import AppKit
import SwiftUI

enum OwlAgentSettings {
  /// Grok waits this long for one tool call; `deliver_text` may wait up to 600 s for the user.
  static let toolTimeoutSeconds = 610

  static func helperPath(bundle: Bundle = .main) -> String {
    bundle.bundleURL.appendingPathComponent("Contents/Helpers/owltype-mcp").path
  }

  struct CliConfig: Decodable {
    let agyCommand: String
    let grokCommand: String
    let grokConfig: String

    enum CodingKeys: String, CodingKey {
      case agyCommand = "agy_command"
      case grokCommand = "grok_command"
      case grokConfig = "grok_config"
    }
  }

  static func cliConfig(helperPath: String) -> CliConfig {
    OwlAppCore.required([
      "operation": "agent_rule",
      "rule": "cli_config",
      "args": ["helper_path": helperPath]
    ])
  }

  /// The `agy mcp add` command for Antigravity CLI, quoted for zsh.
  static func agyCommand(helperPath: String) -> String {
    cliConfig(helperPath: helperPath).agyCommand
  }

  /// The `grok mcp add` command, quoted for zsh.
  static func grokCommand(helperPath: String) -> String {
    cliConfig(helperPath: helperPath).grokCommand
  }

  /// The same server as a `~/.grok/config.toml` block, with the longer tool timeout.
  static func grokConfig(helperPath: String) -> String {
    cliConfig(helperPath: helperPath).grokConfig
  }

  static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Templates the page lists: everything that can be exposed, pending imports excluded.
  static func listedTemplates(_ library: OwlTemplateLibrary) -> [OwlTemplateEntry] {
    OwlTemplateStore.sorted(library.entries.filter { !$0.isPendingReview })
  }

  /// Turns exposure on or off for one template and saves, refusing if the library changed on disk.
  static func setExposed(_ exposed: Bool, id: UUID, in library: OwlTemplateLibrary,
                         save: (OwlTemplateLibrary, OwlTemplateLibrary) throws -> Void) throws -> OwlTemplateLibrary {
    var next = library
    guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return library }
    next.entries[index].isExposedToAgents = exposed
    try save(next, library)
    return next
  }

  static func outcomeTitle(_ outcome: String) -> String {
    struct OutcomeTitleResult: Decodable {
      let title: String
    }
    let res: OutcomeTitleResult = OwlAppCore.required([
      "operation": "agent_rule",
      "rule": "outcome_title",
      "args": ["outcome": outcome]
    ])
    return res.title
  }
}

struct OwlAgentPage: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  @State private var enabled = OwlAgentAccessPreferences.isEnabled()
  @State private var library: OwlTemplateLibrary?
  @State private var entries: [OwlTemplateEntry] = []
  @State private var libraryNote = ""
  @State private var libraryRevision = UUID()
  @State private var records: [OwlAgentCallRecord] = []
  @State private var logRevision = UUID()
  @State private var status = ""
  @State private var copied = ""

  private static let cliConfig = OwlAgentSettings.cliConfig(helperPath: OwlAgentSettings.helperPath())

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        switchCard
        templatesCard
        configCard
        logCard
      }
      .padding(20)
    }
    .task(id: libraryRevision) { await reloadLibrary() }
    .task(id: logRevision) {
      let revision = logRevision
      let snapshot = await Task.detached(priority: .utility) { OwlAgentCallLog.shared.records }.value
      guard !Task.isCancelled, revision == logRevision else { return }
      records = snapshot
    }
    .onReceive(NotificationCenter.default.publisher(for: OwlAgentCallLog.didChange)) { _ in
      logRevision = UUID()
    }
    .onReceive(NotificationCenter.default.publisher(for: OwlTemplateStore.libraryDidCommit)
      .receive(on: DispatchQueue.main)) { _ in
      libraryRevision = UUID()
    }
  }

  private var switchCard: some View {
    SettingsCard(title: "Agent 接入", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 12) {
        SettingsToggleRow(title: "允许本机 Agent 连接", isOn: enabled, palette: palette) {
          enabled.toggle()
          OwlAgentAccessPreferences.setEnabled(enabled)
        }
        SettingsCardDivider(palette: palette)
        note("只接受本机同一用户、由法墨自带的 owltype-mcp 发起的连接。Agent 看不到你正在输入的内容，"
          + "只能读取下面开放的模板；它请求写入文字时，会先弹出预览，由你确认后写入一次，不会按回车。")
      }
    }
  }

  private var templatesCard: some View {
    SettingsCard(title: "开放给 Agent 的模板", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 10) {
        if library != nil {
          if entries.isEmpty { note("还没有模板。可在「快捷片段」页新建。") }
          ForEach(entries) { entry in
            SettingsToggleRow(
              title: entry.title,
              isOn: entry.isExposedToAgents,
              palette: palette
            ) { setExposed(!entry.isExposedToAgents, entry.id) }
            .accessibilityIdentifier("agent-template-\(entry.id.uuidString)")
          }
        } else if libraryNote.isEmpty {
          ProgressView("正在读取模板…").controlSize(.small)
        } else {
          note(libraryNote)
        }
        if !status.isEmpty { note(status) }
      }
    }
  }

  private var configCard: some View {
    SettingsCard(title: "接入本机 Agent", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 10) {
        note("Antigravity CLI：在终端运行。")
        snippet(Self.cliConfig.agyCommand, id: "agy")
        note("Grok Build：运行这条命令，或把下面的配置加入 ~/.grok/config.toml（可等待写入确认）。")
        snippet(Self.cliConfig.grokCommand, id: "command")
        snippet(Self.cliConfig.grokConfig, id: "config")
      }
    }
  }

  private var logCard: some View {
    SettingsCard(title: "调用记录", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 8) {
        note("只记录时间、客户端、工具和结果，不记录参数、模板正文或写入的文字。")
        if records.isEmpty {
          note("还没有调用。")
        } else {
          ForEach(Array(records.prefix(50).enumerated()), id: \.offset) { _, record in
            HStack(spacing: 10) {
              Text(Self.dateFormatter.string(from: record.at)).foregroundStyle(palette.ink3)
              Text(record.client)
              Text(record.method).font(.system(size: 12, design: .monospaced))
              Spacer()
              Text(OwlAgentSettings.outcomeTitle(record.outcome)).foregroundStyle(palette.ink3)
            }
            .font(.system(size: 12))
          }
          Button("清空记录") { OwlAgentCallLog.shared.clear(); records = [] }
            .buttonStyle(.bordered)
        }
      }
    }
  }

  private func snippet(_ text: String, id: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.ink.opacity(0.05)))
      Button(copied == id ? "已复制" : "复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("agent-copy-\(id)")
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(palette.ink3)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func reloadLibrary() async {
    let revision = libraryRevision
    let result = await Task.detached(priority: .userInitiated) {
      Result {
        let library = try OwlTemplateStore.load()
        return (library, OwlAgentSettings.listedTemplates(library))
      }
    }.value
    guard !Task.isCancelled, revision == libraryRevision else { return }
    switch result {
    case .success(let snapshot):
      (library, entries) = snapshot
      libraryNote = ""
    case .failure(let error):
      library = nil
      libraryNote = "模板库暂时读不出来：\(error.localizedDescription)"
    }
  }

  private func setExposed(_ exposed: Bool, _ id: UUID) {
    guard let library else { return }
    do {
      self.library = try OwlAgentSettings.setExposed(exposed, id: id, in: library) {
        try OwlTemplateStore.save($0, expectedLibrary: $1)
      }
      if let index = entries.firstIndex(where: { $0.id == id }) {
        entries[index].isExposedToAgents = exposed
      }
      status = ""
    } catch {
      status = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      libraryRevision = UUID()
    }
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
}
