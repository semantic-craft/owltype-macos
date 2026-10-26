//
//  OwlSettingsState.swift
//  猫头鹰输入法 (Owltype) — SwiftUI settings window
//
//  v0.2: observable state for the settings window. Purely additive UI — it only
//  triggers already-safe delegate actions (deploy / open folders / schema switch)
//  and renders a read-only skin preview. It never touches the IMK key-event hot
//  path (OwlInputController).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only.
//
//  Concurrency: not `@MainActor`-isolated (matches the non-isolated `OwlPanel`
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
enum OwlSettingsPage: String, CaseIterable, Identifiable, Sendable {
  case keyboard
  case shortcuts
  case appearance
  case schemes
  case quickSend
  case clipboard
  case project
  case ai
  case skin
  case diagnostics
  case about

  var id: String { rawValue }

  static var visibleCases: [OwlSettingsPage] {
    allCases.filter { $0 != .schemes }
  }

  /// 中文 sidebar label.
  var title: String {
    switch self {
    case .keyboard: return "键盘输入"
    case .shortcuts: return "快捷键设置"
    case .appearance: return "候选窗设置"
    case .schemes: return "输入方案"    case .quickSend: return "快捷片段"
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
    case .clipboard: return "贴"
    case .project: return "技"
    case .ai: return "智"
    case .skin: return "皮"
    case .diagnostics: return "诊"
    case .about: return "关"
    }
  }
}

/// Observable backing state for `OwlSettingsView`.
///
/// Not `@MainActor`-isolated: the non-isolated `OwlApplicationDelegate` builds
/// and mutates it (matches the rest of the candidate / settings UI). All access is
/// on the main thread.
@Observable
final class OwlSettingsState {
  /// Currently selected sidebar page (drives the NavigationSplitView detail).
  /// Defaults to 键盘输入 (the IME's primary surface,豆包-style).
  var selectedPage: OwlSettingsPage = .keyboard
  /// librime version string for the 关于 page, seeded by the delegate from the Rime
  /// C API (`get_version`). Empty when unavailable — the About page omits the row.
  var librimeVersion: String = ""
  /// Installed schemas, populated by the delegate via the Rime C API.
  var schemas: [SchemaItem] = []
  /// `schema_id` of the currently active schema (best-effort; may be empty).
  var currentSchemaId: String = ""
  /// Current macOS TIS input source, shown on the About page to disambiguate Owltype
  /// from the user's separate Squirrel install.
  var currentInputSourceDisplayName: String = ""
  /// Transient status line shown under the action buttons (deploy result, etc.).
  var statusMessage: String = ""
  /// Current librime user-data sync directory. Empty only before delegate seeding.
  /// Candidate-panel appearance editing value (跟随系统/浅色/深色). Seeded and persisted through
  /// `OwlCandidatePanelSettings` together with skin, font, and animation preference.
  var panelAppearance: OwlPanelAppearance = .system
  /// Candidate-panel size editing value, owned by `OwlCandidatePanelSettings`.
  var panelFontSize = OwlCandidatePanelSettings.defaultSize
  /// Candidate-panel orientation editing value, owned by `OwlCandidatePanelSettings`.
  var panelOrientation = OwlCandidatePanelSettings.defaultOrientation
  /// Candidate animation editing value, owned by `OwlCandidatePanelSettings`.
  var panelAnimationsEnabled: Bool = true
  /// Candidate font editing value. `OwlCandidatePanelSettings` owns seed, persistence, installed
  /// family resolution, runtime snapshot, and panel apply as one lifecycle.
  var candidateFont: OwlCandidateFont = .systemDefault
  /// Whether the panel renders its own 输入串 header, owned by `OwlCandidatePanelSettings`.
  var panelShowPreedit = OwlCandidatePanelSettings.defaultShowPreedit
  /// 内嵌候选预览, owned by `OwlCandidatePanelSettings`. Feature 3.
  var panelInlineCandidate = OwlCandidatePanelSettings.defaultInlineCandidate
  /// 候选条翻页箭头, owned by `OwlCandidatePanelSettings`. Feature 4.
  var panelShowPaging = OwlCandidatePanelSettings.defaultShowPaging
  /// 切换提示通知, owned by `OwlCandidatePanelSettings`. Feature 5.
  var panelShowNotificationsWhen = OwlCandidatePanelSettings.defaultShowNotificationsWhen
  /// 候选格式预设, owned by `OwlCandidatePanelSettings`. Feature 7.
  var panelCandidateFormat = OwlCandidatePanelSettings.defaultCandidateFormat
  /// 多行后页行数, constrained and persisted by `OwlCandidatePanelSettings` (1–4).
  var panelScrollRows = OwlCandidatePanelSettings.defaultScrollRows
  /// G8 候选个数 mirror of `OwlKeyboardPreferences.pageSize` (Rime menu/page_size).
  /// Unlike the panel mirrors, this flows through the keyboard patch + 应用配置改动.
  var candidatePageSize: Int = 8

  // MARK: - 键盘输入 page mirrors (v0.3.1)

  /// Mirrors of `OwlKeyboardPreferences` for the 键盘输入 option groups. The delegate
  /// seeds each from the prefs home in `showSettings()`; the page writes back through
  /// both these mirrors AND `OwlKeyboardPreferences` (explicit `Binding(get:set:)`)
  /// so the UserDefaults key strings live solely in `OwlKeyboardPreferences`.
  /// Defaults here match the prefs defaults so the initial render is correct even
  /// before seeding.

  /// 输入方式: 拼音 / 双拼 (mirror of `OwlKeyboardPreferences.inputMethod`).
  var keyboardInputMethod: OwlInputMethod = .pinyin
  /// 双拼方案 (mirror of `OwlKeyboardPreferences.doublePinyin`).
  var keyboardDoublePinyin: OwlDoublePinyin = .flypy
  /// 四码唯一自动上屏 (mirror of `OwlKeyboardPreferences.wubiAutoCommitUnique`).
  var keyboardWubiAutoCommitUnique: Bool = true
  /// 第五码顶字上屏 (mirror of `OwlKeyboardPreferences.wubiFifthCodeTopCommit`).
  var keyboardWubiFifthCodeTopCommit: Bool = true
  /// 五笔编码提示 (mirror of `OwlKeyboardPreferences.wubiCodeHint`).
  var keyboardWubiCodeHint: Bool = true
  /// z 通配 (mirror of `OwlKeyboardPreferences.wubiZWildcard`).
  var keyboardWubiZWildcard: Bool = false
  /// 五笔空码自动清码 (mirror of `OwlKeyboardPreferences.wubiAutoClear`).
  var keyboardWubiAutoClear: Bool = false
  /// 五笔单字候选模式 (mirror of `OwlKeyboardPreferences.wubiCandidateMode`).
  var keyboardWubiCandidateMode: OwlWubiCandidateMode = .normal
  /// 五笔方案 (mirror of `OwlKeyboardPreferences.wubiScheme`).
  var keyboardWubiScheme: OwlWubiScheme = .jidian86
  /// z 临时拼音反查 (mirror of `OwlKeyboardPreferences.wubiZReverseLookup`).
  var keyboardWubiZReverseLookup: Bool = true
  /// ` 临时英文（五笔前缀英文通道，mirror of `OwlKeyboardPreferences.wubiEnglishChannel`）。Default false（出厂关）.
  var keyboardWubiEnglishChannel: Bool = false
  /// 记住我常用的词·个性化 (mirror of `OwlKeyboardPreferences.wubiUserDictLearning`).
  var keyboardWubiUserDictLearning: Bool = true
  /// 使用 Shift 切换中英文 (mirror of `OwlKeyboardPreferences.shiftSwitchCJK`).
  var keyboardShiftSwitchCJK: Bool = true
  /// 中文下中英标点切换 (mirror of `OwlKeyboardPreferences.cjkPunctToggle`).
  var keyboardCJKPunctToggle: Bool = false
  /// 输出繁体字形 (mirror of `OwlKeyboardPreferences.traditionalOutput`). Feature 1.
  /// Also drives the 默认状态 简繁体 picker (简体=false / 繁体=true).
  var keyboardTraditionalOutput: Bool = false
  /// 默认状态·中英文 (mirror of `OwlKeyboardPreferences.defaultAsciiMode`). 中文=false / 英文=true.
  var keyboardDefaultAsciiMode: Bool = false
  /// 默认状态·全半角 (mirror of `OwlKeyboardPreferences.defaultFullShape`). 半角=false / 全角=true.
  var keyboardDefaultFullShape: Bool = false
  /// 经典 Caps Lock 切换西文 (mirror of `OwlKeyboardPreferences.goodOldCapsLock`).
  var keyboardGoodOldCapsLock: Bool = true
  /// 减号等号翻页 (mirror of `OwlKeyboardPreferences.pageMinusEquals`).
  var keyboardPageMinusEquals: Bool = true
  /// 左右中括号翻页 (mirror of `OwlKeyboardPreferences.pageBrackets`).
  var keyboardPageBrackets: Bool = true
  /// 逗号句号翻页 (mirror of `OwlKeyboardPreferences.pageCommaPeriod`).
  var keyboardPageCommaPeriod: Bool = false
  /// 分号引号选 2/3 位 (mirror of `OwlKeyboardPreferences.select23Semicolon`).
  var keyboardSelect23Semicolon: Bool = false
  /// 「/」键弹出符号选单 (mirror of `OwlKeyboardPreferences.slashSymbolMenu`)。Default false；
  /// 关闭时裸 `/` 维持切英文并输出 ASCII slash 的既有行为。
  var keyboardSlashSymbolMenu: Bool = false
  /// 「<」键弹出符号选单 (mirror of `OwlKeyboardPreferences.angleSymbolMenu`)。Default false（出厂关）.
  var keyboardAngleSymbolMenu: Bool = false
  /// 中文与英文间加入空格 (mirror of `OwlKeyboardPreferences.cjkAlnumSpacing`).
  var keyboardCJKAlnumSpacing: Bool = false
  /// 中英文自动空格 legacy mirror.
  var keyboardCJKEnglishSpacing: Bool = false
  /// 中文与数字自动空格 legacy mirror.
  var keyboardCJKNumberSpacing: Bool = false
  /// 自动配对括号 (mirror of `OwlKeyboardPreferences.autoPairBrackets`); native pinyin defaults on.
  var keyboardAutoPairBrackets: Bool = true
  var keyboardSmartPunctuation: Bool = true
  var keyboardSmartPunctuationRepeat: Bool = true
  var keyboardSmartPunctuationSpace: Bool = false
  /// 这些 App 默认英文 (mirror of `OwlKeyboardPreferences.appEnglishBundleIDs`).
  var keyboardAppEnglishBundleIDsText: String = ""
  /// 逐键候选重排 (mirror of `OwlExperimentalPreferences.keyboardRerankEnabled`). Default false.
  var keyboardRerankEnabled: Bool = false
  /// 停顿候选重排 (mirror of `OwlExperimentalPreferences.settledRerankEnabled`). Default false.
  var settledRerankEnabled: Bool = false

  // MARK: - 皮肤外观 / 候选 emoji

  /// Selected candidate-panel skin. `OwlSettingsView` reads `skin.theme`, so editing it through
  /// `OwlCandidatePanelSettings` re-skins both the settings window and live candidate panel.
  var skin: OwlSkin = .deepred
  /// 在候选中显示 emoji (mirror of `OwlEmojiPreferences.candidateEmojiEnabled`). Default true（上游 macOS 默认）.
  var candidateEmojiEnabled: Bool = true
  var pinyinQuickPhraseCandidates: Bool = false
  /// Cloud AI enable — 全部划词技能的总闸 (mirror of `OwlCloudPreferences.isEnabled`).
  var cloudEnabled: Bool = false
  /// DeepSeek model id (mirror of `OwlCloudPreferences.deepSeekModel`).
  var cloudModel: String = OwlCloudPreferences.defaultDeepSeekModel
  /// 任意提问「联网搜索」(mirror of `OwlAskWebSearchSettings.isEnabled`). Default false（出厂关，opt-in）.
  var askWebSearchEnabled: Bool = OwlAskWebSearchSettings.isEnabled
  /// 划词菜单总开关 + 划词工具箱页内置技能 mirrors.
  var selectionMenuEnabled: Bool = OwlSelectionMenuPreferences.isEnabled
  var askAnythingSkillEnabled: Bool = OwlSelectionMenuPreferences.askEnabled
  var polishSkillEnabled: Bool = OwlSelectionMenuPreferences.polishEnabled
  var sourceVerificationSkillEnabled: Bool = OwlSelectionMenuPreferences.sourceVerificationEnabled
  var researchAssistSkillEnabled: Bool = OwlSelectionMenuPreferences.researchAssistEnabled
  var publishFormattingSkillEnabled: Bool = OwlSelectionMenuPreferences.publishFormattingEnabled
  var translationSkillEnabled: Bool = OwlSelectionMenuPreferences.translationEnabled
  var promptOptimizeSkillEnabled: Bool = OwlSelectionMenuPreferences.promptOptimizeEnabled
  var goalBriefSkillEnabled: Bool = OwlSelectionMenuPreferences.goalBriefEnabled
}

/// Single home for 划词菜单 + 划词工具箱页 built-in skill preferences.
///
/// Defaults are product-facing: the global menu is opt-in/off, while the two built-in
/// skills are active once the menu is enabled. Keep the UserDefaults keys here so the
/// settings page, menu bar item, and global selection watcher share one source.
// 2026-07-26 技能精简：公文排版（OwlSkillDocumentFormattingEnabled）、润色·多版本挑选
// （OwlSkillPolishVariantsEnabled）、润色·仿我的范例（OwlSkillPolishStyleMatchEnabled）、
// 结构化·加标签（OwlSkillPromptStructureEnabled）四个技能已删；旧偏好键成死数据，不迁移不解码。
enum OwlSelectionMenuPreferences {
  static let enabledKey = "OwlSelectionMenuEnabled"
  static let askEnabledKey = "OwlSkillAskAnythingEnabled"
  static let polishEnabledKey = "OwlSkillPolishEnabled"
  static let sourceVerificationEnabledKey = "OwlSkillSourceVerificationEnabled"
  static let researchAssistEnabledKey = "OwlSkillResearchAssistEnabled"
  static let publishFormattingEnabledKey = "OwlSkillPublishFormattingEnabled"
  static let translationEnabledKey = "OwlSkillTranslationEnabled"
  static let promptOptimizeEnabledKey = "OwlSkillPromptOptimizeEnabled"
  static let goalBriefEnabledKey = "OwlSkillGoalBriefEnabled"

  static var isEnabled: Bool {
    get { bool(enabledKey, default: false) }
    set { OwlDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  /// 任意提问（全部技能的兜底）自 2026-07-26 起有自己的技能开关，默认开。
  static var askEnabled: Bool {
    get { bool(askEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: askEnabledKey) }
  }

  static var polishEnabled: Bool {
    get { bool(polishEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: polishEnabledKey) }
  }

  static var sourceVerificationEnabled: Bool {
    get { bool(sourceVerificationEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: sourceVerificationEnabledKey) }
  }

  static var researchAssistEnabled: Bool {
    get { bool(researchAssistEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: researchAssistEnabledKey) }
  }

  static var publishFormattingEnabled: Bool {
    get { bool(publishFormattingEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: publishFormattingEnabledKey) }
  }

  static var translationEnabled: Bool {
    get { bool(translationEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: translationEnabledKey) }
  }

  static var promptOptimizeEnabled: Bool {
    get { bool(promptOptimizeEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: promptOptimizeEnabledKey) }
  }

  /// 任务书（目标七问）：与其他内置技能同策，默认开、随云端总闸生效。
  static var goalBriefEnabled: Bool {
    get { bool(goalBriefEnabledKey, default: true) }
    set { OwlDefaults.standard.set(newValue, forKey: goalBriefEnabledKey) }
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: enabledKey)
    OwlDefaults.standard.removeObject(forKey: askEnabledKey)
    OwlDefaults.standard.removeObject(forKey: polishEnabledKey)
    OwlDefaults.standard.removeObject(forKey: sourceVerificationEnabledKey)
    OwlDefaults.standard.removeObject(forKey: researchAssistEnabledKey)
    OwlDefaults.standard.removeObject(forKey: publishFormattingEnabledKey)
    OwlDefaults.standard.removeObject(forKey: translationEnabledKey)
    OwlDefaults.standard.removeObject(forKey: promptOptimizeEnabledKey)
    OwlDefaults.standard.removeObject(forKey: goalBriefEnabledKey)
  }

  private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
    guard OwlDefaults.standard.object(forKey: key) != nil else { return defaultValue }
    return OwlDefaults.standard.bool(forKey: key)
  }
}

struct OwlRimeSyncSettings {
  let rimeDir: URL

  init(rimeDir: URL = OwlApp.userDir) {
    self.rimeDir = rimeDir
  }

  var installationURL: URL {
    rimeDir.appendingPathComponent("installation.yaml")
  }

  func currentSyncDirectory() -> URL {
    guard let text = try? String(contentsOf: installationURL, encoding: .utf8),
          let raw = Self.topLevelValue("sync_dir", in: text),
          !raw.isEmpty else {
      return rimeDir.appendingPathComponent("sync", isDirectory: true)
    }
    return URL(
      fileURLWithPath: (raw as NSString).expandingTildeInPath,
      isDirectory: true
    ).standardizedFileURL
  }

  static func topLevelValue(_ key: String, in text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      guard line.hasPrefix("\(key):") else { continue }
      let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
      return yamlStringValue(String(raw))
    }
    return nil
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

}

enum OwlSettingsActions {
  static func set<T>(
    _ value: T,
    state: OwlSettingsState,
    keyPath: ReferenceWritableKeyPath<OwlSettingsState, T>,
    write: (T) -> Void
  ) {
    state[keyPath: keyPath] = value
    write(value)
  }

  static func toggle(
    state: OwlSettingsState,
    keyPath: ReferenceWritableKeyPath<OwlSettingsState, Bool>,
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
    _ method: OwlInputMethod,
    state: OwlSettingsState,
    applyConfig: () -> Void = {},
    onSelectSchema: (String) -> Void
  ) {
    set(method, state: state, keyPath: \.keyboardInputMethod) {
      OwlKeyboardPreferences.inputMethod = $0
    }
    onSelectSchema(method.schemaId(doublePinyin: state.keyboardDoublePinyin, wubiScheme: state.keyboardWubiScheme))
    applyConfig()
  }

  static func selectDoublePinyin(
    _ scheme: OwlDoublePinyin,
    state: OwlSettingsState,
    applyConfig: () -> Void = {},
    onSelectSchema: (String) -> Void
  ) {
    set(scheme, state: state, keyPath: \.keyboardDoublePinyin) {
      OwlKeyboardPreferences.doublePinyin = $0
    }
    if state.keyboardInputMethod == .doublePinyin {
      onSelectSchema(scheme.schemaId)
      applyConfig()
    }
  }

  static func selectWubiScheme(
    _ scheme: OwlWubiScheme,
    state: OwlSettingsState,
    applyConfig: () -> Void = {},
    onSelectSchema: (String) -> Void
  ) {
    set(scheme, state: state, keyPath: \.keyboardWubiScheme) {
      OwlKeyboardPreferences.wubiScheme = $0
    }
    if state.keyboardInputMethod == .wubi {
      onSelectSchema(scheme.schemaId)
      applyConfig()
    }
  }

  static func setAppEnglishBundleIDsText(_ text: String, state: OwlSettingsState) {
    state.keyboardAppEnglishBundleIDsText = text
    OwlKeyboardPreferences.appEnglishBundleIDs =
      OwlKeyboardPreferences.normalizedAppEnglishBundleIDs(from: text)
  }

  static func saveQuickSendEntry(
    phrase: String,
    code: String,
    editingCode: String?,
    entries: [OwlQuickSendEntry],
    persist: ([OwlQuickSendEntry]) throws -> ([OwlQuickSendEntry], Bool)
  ) throws -> (entries: [OwlQuickSendEntry], phrase: String, code: String, editingCode: String?, status: String) {
    let entry = try OwlQuickSendStore.entry(text: phrase, code: code)
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
    _ entry: OwlQuickSendEntry,
    editingCode: String?,
    entries: [OwlQuickSendEntry],
    persist: ([OwlQuickSendEntry]) throws -> ([OwlQuickSendEntry], Bool)
  ) throws -> (entries: [OwlQuickSendEntry], phrase: String?, code: String?, editingCode: String?, status: String) {
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
    return value ? "已启用；只在你点击捕获时读取纯文本剪贴板。" : "已关闭；Owltype 不读取系统剪贴板。"
  }

  static func captureClipboard(
    enabled: Bool,
    text: String?,
    capture: (String?) throws -> [OwlClipboardEntry]
  ) throws -> (entries: [OwlClipboardEntry]?, status: String) {
    guard enabled else { return (nil, "先启用剪贴板面板。") }
    return (try capture(text), "已捕获当前剪贴板；最多保留 \(OwlClipboardStore.maxEntries) 条。")
  }

  static func clearClipboard(
    clear: () throws -> Void
  ) throws -> (entries: [OwlClipboardEntry], status: String) {
    try clear()
    return ([], "已清空本地剪贴板记录。")
  }
}
