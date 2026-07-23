//
//  FamoSettingsState.swift
//  法墨输入法 (Famo) — SwiftUI settings window
//
//  v0.2: observable state for the settings window. Purely additive UI — it only
//  triggers already-safe delegate actions (deploy / open folders / schema switch)
//  and renders a read-only skin preview. It never touches the IMK key-event hot
//  path (FamoInputController).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only.
//
//  Concurrency: not `@MainActor`-isolated (matches the non-isolated `FamoPanel`
//  / `IMKInputController`); all access happens on the main thread via the delegate.
//  Value types crossing into the view (`SchemaItem`) stay `Sendable` structs.
//

import Foundation
import SwiftUI
import Observation

/// One installed Rime schema. `Sendable` so the snapshot built from the Rime C API
/// (`get_schema_list`) on the delegate can be handed to the view safely.
struct SchemaItem: Identifiable, Sendable, Equatable {
  /// Rime `schema_id` (e.g. "rime_law", "luna_pinyin"). Stable identity for the row.
  let id: String
  /// Human-facing schema name (e.g. "法律拼音").
  let name: String
}

/// Sidebar pages of the v0.3 NavigationSplitView settings window. Plain `Sendable`
/// enum: the sidebar `List(selection:)` and the detail switch share this identity.
/// `keyboard` is the v0.3.1 meat (stub this cycle); the rest migrate v0.2.x features.
enum FamoSettingsPage: String, CaseIterable, Identifiable, Sendable {
  case keyboard
  case shortcuts
  case appearance
  case schemes
  case quickSend
  case prompts
  case skin
  case diagnostics
  case about

  var id: String { rawValue }

  static var visibleCases: [FamoSettingsPage] {
    allCases.filter { $0 != .schemes }
  }

  /// 中文 sidebar label.
  var title: String {
    switch self {
    case .keyboard: return "键盘输入"
    case .shortcuts: return "快捷键设置"
    case .appearance: return "候选窗设置"
    case .schemes: return "输入方案"
    case .quickSend: return "快捷短语"
    case .prompts: return "提示词助手"
    case .skin: return "皮肤外观"
    case .diagnostics: return "诊断"
    case .about: return "关于"
    }
  }

  /// SF Symbol rendered as the sidebar row icon (also the accessibility glyph).
  var symbol: String {
    switch self {
    case .keyboard: return "keyboard"
    case .shortcuts: return "command"
    case .appearance: return "macwindow"
    case .schemes: return "character.book.closed"
    case .quickSend: return "text.badge.plus"
    case .prompts: return "doc.text"
    case .skin: return "paintbrush"
    case .diagnostics: return "stethoscope"
    case .about: return "info.circle"
    }
  }

}

/// Observable backing state for `FamoSettingsView`.
///
/// Not `@MainActor`-isolated: the non-isolated `FamoApplicationDelegate` builds
/// and mutates it (matches the rest of the candidate / settings UI). All access is
/// on the main thread.
@Observable
final class FamoSettingsState {
  /// Currently selected sidebar page (drives the NavigationSplitView detail).
  /// Defaults to 键盘输入 (the IME's primary surface,豆包-style).
  var selectedPage: FamoSettingsPage = .keyboard
  /// librime version string for the 关于 page, seeded by the delegate from the Rime
  /// C API (`get_version`). Empty when unavailable — the About page omits the row.
  var librimeVersion: String = ""
  /// Installed schemas, populated by the delegate via the Rime C API.
  var schemas: [SchemaItem] = []
  /// `schema_id` of the currently active schema (best-effort; may be empty).
  var currentSchemaId: String = ""
  /// Current macOS TIS input source, shown on the About page to disambiguate Famo
  /// from the user's separate Squirrel install.
  var currentInputSourceDisplayName: String = ""
  /// Transient status line shown under the action buttons (deploy result, etc.).
  var statusMessage: String = ""
  /// Current librime user-data sync directory. Empty only before delegate seeding.
  var syncDirectoryDisplayPath: String = ""
  /// Mirror of `FamoPanelPreferences.appearance` (跟随系统/浅色/深色 for the SwiftUI
  /// candidate panel). The delegate seeds it from the prefs home; the view writes
  /// back through both this mirror and `FamoPanelPreferences.appearance` so the
  /// UserDefaults key string lives in exactly one place.
  var panelAppearance: FamoPanelAppearance = .system
  /// Mirror of `FamoPanelPreferences.fontSize` (小/中/大 candidate font size).
  /// Seeded and written through the same way as `panelAppearance`; the skin
  /// preview also reads `panelFontSize.base` so it reflects the chosen size live.
  var panelFontSize: FamoPanelFontSize = .medium
  /// G8 候选显示 mirrors of `FamoPanelPreferences` — orientation (横排/竖排/折行), candidate
  /// typeface (候选字体), animation toggle (候选条动画). Seeded + written like `panelAppearance`.
  var panelOrientation: FamoPanelOrientation = .auto
  var panelFontDesign: FamoPanelFontDesign = .default
  var panelAnimationsEnabled: Bool = true
  /// Whether the panel renders its own 输入串 header. Seeded + written like the others.
  var panelShowPreedit: Bool = true
  /// 内嵌候选预览 (mirror of `FamoPanelPreferences.inlineCandidate`). Feature 3.
  var panelInlineCandidate: Bool = false
  /// 候选条翻页箭头 (mirror of `FamoPanelPreferences.showPaging`). Feature 4.
  var panelShowPaging: Bool = true
  /// 切换提示通知 (mirror of `FamoPanelPreferences.showNotificationsWhen`). Feature 5.
  var panelShowNotificationsWhen: FamoNotificationWhen = .always
  /// 候选格式预设 (mirror of `FamoPanelPreferences.candidateFormat`). Feature 7.
  var panelCandidateFormat: FamoCandidateFormat = .full
  /// G8 候选个数 mirror of `FamoKeyboardPreferences.pageSize` (Rime menu/page_size).
  /// Unlike the panel mirrors, this flows through the keyboard patch + 应用配置改动.
  var candidatePageSize: Int = 8

  // MARK: - 键盘输入 page mirrors (v0.3.1)

  /// Mirrors of `FamoKeyboardPreferences` for the 键盘输入 option groups. The delegate
  /// seeds each from the prefs home in `showSettings()`; the page writes back through
  /// both these mirrors AND `FamoKeyboardPreferences` (explicit `Binding(get:set:)`)
  /// so the UserDefaults key strings live solely in `FamoKeyboardPreferences`.
  /// Defaults here match the prefs defaults so the initial render is correct even
  /// before seeding.

  /// 输入方式: 拼音 / 双拼 (mirror of `FamoKeyboardPreferences.inputMethod`).
  var keyboardInputMethod: FamoInputMethod = .pinyin
  /// 双拼方案 (mirror of `FamoKeyboardPreferences.doublePinyin`).
  var keyboardDoublePinyin: FamoDoublePinyin = .flypy
  /// 五笔编码提示 (mirror of `FamoKeyboardPreferences.wubiCodeHint`).
  var keyboardWubiCodeHint: Bool = false
  /// 五笔空码自动清码 (mirror of `FamoKeyboardPreferences.wubiAutoClear`).
  var keyboardWubiAutoClear: Bool = false
  /// 五笔单字候选模式 (mirror of `FamoKeyboardPreferences.wubiCandidateMode`).
  var keyboardWubiCandidateMode: FamoWubiCandidateMode = .normal
  /// 五笔方案 (mirror of `FamoKeyboardPreferences.wubiScheme`).
  var keyboardWubiScheme: FamoWubiScheme = .jidian86
  /// z 临时拼音反查 (mirror of `FamoKeyboardPreferences.wubiZReverseLookup`).
  var keyboardWubiZReverseLookup: Bool = true
  /// ` 临时英文（五笔前缀英文通道，mirror of `FamoKeyboardPreferences.wubiEnglishChannel`）。Default false（出厂关）.
  var keyboardWubiEnglishChannel: Bool = false
  /// 记住我常用的词·个性化 (mirror of `FamoKeyboardPreferences.wubiUserDictLearning`).
  var keyboardWubiUserDictLearning: Bool = false
  /// 使用 Shift 切换中英文 (mirror of `FamoKeyboardPreferences.shiftSwitchCJK`).
  var keyboardShiftSwitchCJK: Bool = true
  /// 中文下中英标点切换 (mirror of `FamoKeyboardPreferences.cjkPunctToggle`).
  var keyboardCJKPunctToggle: Bool = false
  /// 输出繁体字形 (mirror of `FamoKeyboardPreferences.traditionalOutput`). Feature 1.
  /// Also drives the 默认状态 简繁体 picker (简体=false / 繁体=true).
  var keyboardTraditionalOutput: Bool = false
  /// 默认状态·中英文 (mirror of `FamoKeyboardPreferences.defaultAsciiMode`). 中文=false / 英文=true.
  var keyboardDefaultAsciiMode: Bool = false
  /// 默认状态·全半角 (mirror of `FamoKeyboardPreferences.defaultFullShape`). 半角=false / 全角=true.
  var keyboardDefaultFullShape: Bool = false
  /// 经典 Caps Lock 切换西文 (mirror of `FamoKeyboardPreferences.goodOldCapsLock`).
  var keyboardGoodOldCapsLock: Bool = true
  /// 减号等号翻页 (mirror of `FamoKeyboardPreferences.pageMinusEquals`).
  var keyboardPageMinusEquals: Bool = true
  /// 左右中括号翻页 (mirror of `FamoKeyboardPreferences.pageBrackets`).
  var keyboardPageBrackets: Bool = true
  /// 逗号句号翻页 (mirror of `FamoKeyboardPreferences.pageCommaPeriod`).
  var keyboardPageCommaPeriod: Bool = false
  /// 分号引号选 2/3 位 (mirror of `FamoKeyboardPreferences.select23Semicolon`).
  var keyboardSelect23Semicolon: Bool = false
  /// 「<」键弹出符号选单 (mirror of `FamoKeyboardPreferences.angleSymbolMenu`)。Default false（出厂关）.
  var keyboardAngleSymbolMenu: Bool = false
  /// 中文与英文间加入空格 (mirror of `FamoKeyboardPreferences.cjkAlnumSpacing`).
  var keyboardCJKAlnumSpacing: Bool = false
  /// 中英文自动空格 legacy mirror.
  var keyboardCJKEnglishSpacing: Bool = false
  /// 中文与数字自动空格 legacy mirror.
  var keyboardCJKNumberSpacing: Bool = false
  /// 这些 App 默认英文 (mirror of `FamoKeyboardPreferences.appEnglishBundleIDs`).
  var keyboardAppEnglishBundleIDsText: String = ""

  // MARK: - 皮肤外观 / 候选 emoji mirrors

  /// Selected skin (mirror of `FamoSkinPreferences.skin`). `FamoSettingsView` reads
  /// `skin.theme`, so writing this re-skins the whole window; the delegate-free seed
  /// happens in the view's `.onAppear`.
  var skin: FamoSkin = .deepred
  /// 在候选中显示 emoji (mirror of `FamoEmojiPreferences.candidateEmojiEnabled`). Default false（出厂关）.
  var candidateEmojiEnabled: Bool = false
}

struct FamoRimeSyncSettings {
  let rimeDir: URL

  init(rimeDir: URL = FamoApp.userDir) {
    self.rimeDir = rimeDir
  }

  var installationURL: URL {
    rimeDir.appendingPathComponent("installation.yaml")
  }

  var defaultSyncDirectory: URL {
    rimeDir.appendingPathComponent("sync", isDirectory: true)
  }

  var syncDirectoryDisplayPath: String {
    Self.displayPath(for: currentSyncDirectory())
  }

  func currentSyncDirectory() -> URL {
    guard let text = try? String(contentsOf: installationURL, encoding: .utf8),
          let raw = Self.topLevelValue("sync_dir", in: text),
          !raw.isEmpty else {
      return defaultSyncDirectory
    }
    return URL(fileURLWithPath: raw, isDirectory: true)
  }

  func setSyncDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: rimeDir, withIntermediateDirectories: true)
    let path = directory.standardizedFileURL.path
    let line = "sync_dir: \(Self.yamlDoubleQuoted(path))"
    let text = (try? String(contentsOf: installationURL, encoding: .utf8)) ?? ""
    let updated = Self.replacingTopLevelValue("sync_dir", with: line, in: text)
    try updated.write(to: installationURL, atomically: true, encoding: .utf8)
  }

  static func displayPath(for url: URL) -> String {
    let path = url.standardizedFileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }

  static func topLevelValue(_ key: String, in text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      guard line.hasPrefix("\(key):") else { continue }
      let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
      return yamlStringValue(String(raw))
    }
    return nil
  }

  private static func replacingTopLevelValue(_ key: String, with line: String, in text: String) -> String {
    var replaced = false
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for index in lines.indices where lines[index].hasPrefix("\(key):") {
      lines[index] = line
      replaced = true
      break
    }
    if !replaced {
      if lines.last == "" {
        lines.insert(line, at: lines.index(before: lines.endIndex))
      } else {
        lines.append(line)
      }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
  }

  private static func yamlStringValue(_ raw: String) -> String {
    if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
      return raw.dropFirst().dropLast()
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
    }
    if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
      return raw.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
    }
    return raw
  }

  private static func yamlDoubleQuoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}

enum FamoSettingsActions {
  static func set<T>(
    _ value: T,
    state: FamoSettingsState,
    keyPath: ReferenceWritableKeyPath<FamoSettingsState, T>,
    write: (T) -> Void
  ) {
    state[keyPath: keyPath] = value
    write(value)
  }

  static func toggle(
    state: FamoSettingsState,
    keyPath: ReferenceWritableKeyPath<FamoSettingsState, Bool>,
    write: (Bool) -> Void
  ) {
    set(!state[keyPath: keyPath], state: state, keyPath: keyPath, write: write)
  }

  static func toggleLocalBool(_ current: Bool, write: (Bool) -> Void) -> Bool {
    let next = !current
    write(next)
    return next
  }

  static func selectInputMethod(
    _ method: FamoInputMethod,
    state: FamoSettingsState,
    applyConfig: () -> Void = {},
    onSelectSchema: (String) -> Void
  ) {
    set(method, state: state, keyPath: \.keyboardInputMethod) {
      FamoKeyboardPreferences.inputMethod = $0
    }
    onSelectSchema(method.schemaId(doublePinyin: state.keyboardDoublePinyin, wubiScheme: state.keyboardWubiScheme))
    applyConfig()
  }

  static func selectDoublePinyin(
    _ scheme: FamoDoublePinyin,
    state: FamoSettingsState,
    applyConfig: () -> Void = {},
    onSelectSchema: (String) -> Void
  ) {
    set(scheme, state: state, keyPath: \.keyboardDoublePinyin) {
      FamoKeyboardPreferences.doublePinyin = $0
    }
    if state.keyboardInputMethod == .doublePinyin {
      onSelectSchema(scheme.schemaId)
      applyConfig()
    }
  }

  static func selectWubiScheme(
    _ scheme: FamoWubiScheme,
    state: FamoSettingsState,
    applyConfig: () -> Void = {},
    onSelectSchema: (String) -> Void
  ) {
    set(scheme, state: state, keyPath: \.keyboardWubiScheme) {
      FamoKeyboardPreferences.wubiScheme = $0
    }
    if state.keyboardInputMethod == .wubi {
      onSelectSchema(scheme.schemaId)
      applyConfig()
    }
  }

  static func setAppEnglishBundleIDsText(_ text: String, state: FamoSettingsState) {
    state.keyboardAppEnglishBundleIDsText = text
    FamoKeyboardPreferences.appEnglishBundleIDs =
      FamoKeyboardPreferences.normalizedAppEnglishBundleIDs(from: text)
  }

  static func saveQuickSendEntry(
    phrase: String,
    code: String,
    editingCode: String?,
    entries: [FamoQuickSendEntry],
    persist: ([FamoQuickSendEntry]) throws -> ([FamoQuickSendEntry], Bool)
  ) throws -> (entries: [FamoQuickSendEntry], phrase: String, code: String, editingCode: String?, status: String) {
    let entry = try FamoQuickSendStore.entry(text: phrase, code: code)
    var next = entries.filter { $0.code != entry.code && $0.code != editingCode }
    next.append(entry)
    let persisted = try persist(next)
    return (
      persisted.0,
      "",
      "",
      nil,
      persisted.1 ? "已保存并应用配置改动。" : "已保存；应用配置失败，请查看诊断日志。"
    )
  }

  static func deleteQuickSendEntry(
    _ entry: FamoQuickSendEntry,
    editingCode: String?,
    entries: [FamoQuickSendEntry],
    persist: ([FamoQuickSendEntry]) throws -> ([FamoQuickSendEntry], Bool)
  ) throws -> (entries: [FamoQuickSendEntry], phrase: String?, code: String?, editingCode: String?, status: String) {
    let persisted = try persist(entries.filter { $0.code != entry.code })
    return (
      persisted.0,
      editingCode == entry.code ? "" : nil,
      editingCode == entry.code ? "" : nil,
      editingCode == entry.code ? nil : editingCode,
      persisted.1 ? "已删除并应用配置改动。" : "已删除；应用配置失败，请查看诊断日志。"
    )
  }

}
