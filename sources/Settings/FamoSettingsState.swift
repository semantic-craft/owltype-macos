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
  case clipboard
  case project
  case ai
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
    case .schemes: return "输入方案"    case .quickSend: return "快捷短语"
    case .prompts: return "提示词助手"
    case .clipboard: return "剪贴板"
    case .project: return "划词工具箱"
    case .ai: return "AI 配置"
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
    case .schemes: return "character.book.closed"    case .quickSend: return "text.badge.plus"
    case .prompts: return "doc.text"
    case .clipboard: return "doc.on.clipboard"
    case .project: return "wand.and.sparkles"
    case .ai: return "sparkles"
    case .skin: return "paintbrush"
    case .diagnostics: return "stethoscope"
    case .about: return "info.circle"
    }
  }

  /// Alternative single-character badge (the earlier Claude Design look). No longer
  /// rendered — kept for a one-line revert of `sidebarRow`. ponytail: delete if the
  /// SF Symbol look sticks.
  var mono: String {
    switch self {
    case .keyboard: return "键"
    case .shortcuts: return "捷"
    case .appearance: return "候"
    case .schemes: return "案"    case .quickSend: return "短"
    case .prompts: return "提"
    case .clipboard: return "贴"
    case .project: return "技"
    case .ai: return "智"
    case .skin: return "皮"
    case .diagnostics: return "诊"
    case .about: return "关"
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
  /// Candidate-panel appearance editing value (跟随系统/浅色/深色). Seeded and persisted through
  /// `FamoCandidatePanelSettings` together with skin, font, and animation preference.
  var panelAppearance: FamoPanelAppearance = .system
  /// Mirror of the #118-scoped `FamoPanelPreferences.fontSize` — 设置里的「候选窗尺寸」
  /// 小/中/大/特大，拨的是候选字与面板留白一起缩放后的整块面板大小。
  var panelFontSize: FamoPanelFontSize = .medium
  /// G8 candidate layout editing value. Orientation remains a #118 layout/content field.
  var panelOrientation: FamoPanelOrientation = .auto
  /// Candidate animation editing value, owned by `FamoCandidatePanelSettings`.
  var panelAnimationsEnabled: Bool = true
  /// Candidate font editing value. `FamoCandidatePanelSettings` owns seed, persistence, installed
  /// family resolution, runtime snapshot, and panel apply as one lifecycle.
  var candidateFont: FamoCandidateFont = .systemDefault
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
  /// 卷轴后页行数 (mirror of `FamoPanelPreferences.scrollRows`, 1–4).
  var panelScrollRows: Int = 4
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
  /// 「/」键弹出符号选单 (mirror of `FamoKeyboardPreferences.slashSymbolMenu`)。Default false；
  /// 关闭时裸 `/` 维持切英文并输出 ASCII slash 的既有行为。
  var keyboardSlashSymbolMenu: Bool = false
  /// 「<」键弹出符号选单 (mirror of `FamoKeyboardPreferences.angleSymbolMenu`)。Default false（出厂关）.
  var keyboardAngleSymbolMenu: Bool = false
  /// 中文与英文间加入空格 (mirror of `FamoKeyboardPreferences.cjkAlnumSpacing`).
  var keyboardCJKAlnumSpacing: Bool = false
  /// 中英文自动空格 legacy mirror.
  var keyboardCJKEnglishSpacing: Bool = false
  /// 中文与数字自动空格 legacy mirror.
  var keyboardCJKNumberSpacing: Bool = false
  /// 自动配对括号 (mirror of `FamoKeyboardPreferences.autoPairBrackets`). Default false（出厂关）.
  var keyboardAutoPairBrackets: Bool = false
  /// 这些 App 默认英文 (mirror of `FamoKeyboardPreferences.appEnglishBundleIDs`).
  var keyboardAppEnglishBundleIDsText: String = ""

  // MARK: - 皮肤外观 / 候选 emoji

  /// Selected candidate-panel skin. `FamoSettingsView` reads `skin.theme`, so editing it through
  /// `FamoCandidatePanelSettings` re-skins both the settings window and live candidate panel.
  var skin: FamoSkin = .deepred
  /// 在候选中显示 emoji (mirror of `FamoEmojiPreferences.candidateEmojiEnabled`). Default false（出厂关）.
  var candidateEmojiEnabled: Bool = false
  /// Cloud AI enable — 全部划词技能的总闸 (mirror of `FamoCloudPreferences.isEnabled`).
  var cloudEnabled: Bool = false
  /// DeepSeek model id (mirror of `FamoCloudPreferences.deepSeekModel`).
  var cloudModel: String = FamoCloudPreferences.defaultDeepSeekModel
  /// 任意提问「联网搜索」(mirror of `FamoAskWebSearchSettings.isEnabled`). Default false（出厂关，opt-in）.
  var askWebSearchEnabled: Bool = FamoAskWebSearchSettings.isEnabled
  /// 任意提问「联网模型」偏好 (mirror of `FamoAskSearchProviderSettings.rawValue`). `""` = 自动.
  var askWebSearchProvider: String = FamoAskSearchProviderSettings.rawValue
  /// 划词菜单总开关 + 划词工具箱页内置技能 mirrors.
  var selectionMenuEnabled: Bool = FamoSelectionMenuPreferences.isEnabled
  var askAnythingSkillEnabled: Bool = FamoSelectionMenuPreferences.askEnabled
  var polishSkillEnabled: Bool = FamoSelectionMenuPreferences.polishEnabled
  var sourceVerificationSkillEnabled: Bool = FamoSelectionMenuPreferences.sourceVerificationEnabled
  var researchAssistSkillEnabled: Bool = FamoSelectionMenuPreferences.researchAssistEnabled
  var publishFormattingSkillEnabled: Bool = FamoSelectionMenuPreferences.publishFormattingEnabled
  var translationSkillEnabled: Bool = FamoSelectionMenuPreferences.translationEnabled
  var promptOptimizeSkillEnabled: Bool = FamoSelectionMenuPreferences.promptOptimizeEnabled
  var goalBriefSkillEnabled: Bool = FamoSelectionMenuPreferences.goalBriefEnabled
}

/// Single home for 划词菜单 + 划词工具箱页 built-in skill preferences.
///
/// Defaults are product-facing: the global menu is opt-in/off, while the two built-in
/// skills are active once the menu is enabled. Keep the UserDefaults keys here so the
/// settings page, menu bar item, and global selection watcher share one source.
// 2026-07-26 技能精简：公文排版（FamoSkillDocumentFormattingEnabled）、润色·多版本挑选
// （FamoSkillPolishVariantsEnabled）、润色·仿我的范例（FamoSkillPolishStyleMatchEnabled）、
// 结构化·加标签（FamoSkillPromptStructureEnabled）四个技能已删；旧偏好键成死数据，不迁移不解码。
enum FamoSelectionMenuPreferences {
  static let enabledKey = "FamoSelectionMenuEnabled"
  static let askEnabledKey = "FamoSkillAskAnythingEnabled"
  static let polishEnabledKey = "FamoSkillPolishEnabled"
  static let sourceVerificationEnabledKey = "FamoSkillSourceVerificationEnabled"
  static let researchAssistEnabledKey = "FamoSkillResearchAssistEnabled"
  static let publishFormattingEnabledKey = "FamoSkillPublishFormattingEnabled"
  static let translationEnabledKey = "FamoSkillTranslationEnabled"
  static let promptOptimizeEnabledKey = "FamoSkillPromptOptimizeEnabled"
  static let goalBriefEnabledKey = "FamoSkillGoalBriefEnabled"

  static var isEnabled: Bool {
    get { bool(enabledKey, default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  /// 任意提问（全部技能的兜底）自 2026-07-26 起有自己的技能开关，默认开。
  static var askEnabled: Bool {
    get { bool(askEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: askEnabledKey) }
  }

  static var polishEnabled: Bool {
    get { bool(polishEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: polishEnabledKey) }
  }

  static var sourceVerificationEnabled: Bool {
    get { bool(sourceVerificationEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: sourceVerificationEnabledKey) }
  }

  static var researchAssistEnabled: Bool {
    get { bool(researchAssistEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: researchAssistEnabledKey) }
  }

  static var publishFormattingEnabled: Bool {
    get { bool(publishFormattingEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: publishFormattingEnabledKey) }
  }

  static var translationEnabled: Bool {
    get { bool(translationEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: translationEnabledKey) }
  }

  static var promptOptimizeEnabled: Bool {
    get { bool(promptOptimizeEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: promptOptimizeEnabledKey) }
  }

  /// 任务书（目标七问）：与其他内置技能同策，默认开、随云端总闸生效。
  static var goalBriefEnabled: Bool {
    get { bool(goalBriefEnabledKey, default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: goalBriefEnabledKey) }
  }

  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: enabledKey)
    FamoDefaults.standard.removeObject(forKey: askEnabledKey)
    FamoDefaults.standard.removeObject(forKey: polishEnabledKey)
    FamoDefaults.standard.removeObject(forKey: sourceVerificationEnabledKey)
    FamoDefaults.standard.removeObject(forKey: researchAssistEnabledKey)
    FamoDefaults.standard.removeObject(forKey: publishFormattingEnabledKey)
    FamoDefaults.standard.removeObject(forKey: translationEnabledKey)
    FamoDefaults.standard.removeObject(forKey: promptOptimizeEnabledKey)
    FamoDefaults.standard.removeObject(forKey: goalBriefEnabledKey)
  }

  private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
    guard FamoDefaults.standard.object(forKey: key) != nil else { return defaultValue }
    return FamoDefaults.standard.bool(forKey: key)
  }
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

  static func setClipboardEnabled(_ value: Bool, write: (Bool) -> Void) -> String {
    write(value)
    return value ? "已启用；只在你点击捕获时读取纯文本剪贴板。" : "已关闭；Famo 不读取系统剪贴板。"
  }

  static func captureClipboard(
    enabled: Bool,
    text: String?,
    capture: (String?) throws -> [FamoClipboardEntry]
  ) throws -> (entries: [FamoClipboardEntry]?, status: String) {
    guard enabled else { return (nil, "先启用剪贴板面板。") }
    return (try capture(text), "已捕获当前剪贴板；最多保留 \(FamoClipboardStore.maxEntries) 条。")
  }

  static func clearClipboard(
    clear: () throws -> Void
  ) throws -> (entries: [FamoClipboardEntry], status: String) {
    try clear()
    return ([], "已清空本地剪贴板记录。")
  }
}
