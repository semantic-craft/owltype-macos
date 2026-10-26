//
//  OwlSettingsView.swift
//  猫头鹰输入法 (Owltype) — SwiftUI settings window
//
//  v0.3: the settings UI as a sidebar-nav app (NavigationSplitView, 豆包/微信-style).
//  Left = a List of user-facing pages (键盘输入 / 候选窗外观 / AI 配置 / 关于); right = grouped
//  深大红 cards. 深大红 themed (light/dark via `colorScheme`), honors Reduce Motion /
//  Reduce Transparency like `OwlCandidatePanelView`.
//
//  The v0.2.x section builders (`schemaSection`, `candidateDisplaySection`,
//  `actionSection`, `statusLine`) are
//  REUSED unchanged — only re-grouped under the sidebar pages. The 关于 / 键盘输入 page
//  bodies live in `OwlSettingsPages.swift`; the shared card chrome in
//  `OwlSettingsComponents.swift` (`SettingsCard`).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only.
//  Actions are forwarded to the delegate via the `on…` closures; no Rime / disk
//  IO happens in the view itself.
//

import AppKit
import SwiftUI

/// Delegate-owned user-data actions exposed by the settings maintenance page.
struct OwlSettingsUserDataActions {
  let migrateLegacy: () -> Void
  let resetUserDict: () -> Void
}

struct OwlSettingsView: View {
  @Bindable var state: OwlSettingsState

  /// Tap a schema row → switch the active schema (`schema_id`). Wired to the
  /// delegate's `selectSchema(_:)`.
  let onSelectSchema: (String) -> Void
  /// 应用配置改动 → delegate `deploy()` (the heavy full maintenance; 维护与诊断「重新部署」).
  let onRedeploy: () -> Bool
  /// Track-2 config-only fast apply → shared settings application (deploy_config_file
  /// + live reselect + replay; no `shutdownRime`). Used for 候选个数 / 键位 / 标点 / schema_list.
  let onApplyKeyboardConfigFast: () throws -> OwlKeyboardSettingsApplication.Outcome
  /// 模糊拼音 fast-ish apply → shared settings application (mtime-gated `fullCheck:false`
  /// maintenance — rebuilds the affected schema prism, not octagram — + reselect + replay).
  let onApplyFuzzyConfigFast: () throws -> OwlKeyboardSettingsApplication.Outcome
  /// 迁移与重置 → delegate-owned user-data operations.
  let userDataActions: OwlSettingsUserDataActions
  /// 打开用户目录 → delegate `openRimeFolder()`.
  let onOpenRimeFolder: () -> Void
  /// 日志 → delegate `openLogFolder()`.
  let onOpenLog: () -> Void
  /// 欢迎与引导 → delegate `showOnboarding()`.
  let onShowOnboarding: () -> Void
  /// Candidate setting changed → refresh all live runtime consumers.
  let onPanelPreferencesChanged: () -> Void
  var writesRimeConfiguration = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  @State private var isApplyingCandidatePageSize = false
  @State private var candidatePageSizeApplyStatus: String?

  /// Active theme = the chosen skin (`皮肤外观` page). Writing `state.skin` re-skins the
  /// whole window. Shared palette/theme with the candidate panel.
  private var theme: OwlCandidateTheme { state.skin.theme }

  /// Resolved palette for the window's active color scheme.
  private var palette: OwlCandidatePalette {
    theme.palette(for: colorScheme)
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .background(windowBackground)
    .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: state.currentSchemaId)
    .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: state.skin)
    .accessibilityIdentifier("OwlSettingsView")
    .onAppear {
      // Delegate-free reseed so direct settings-view hosts and window reopen read the complete
      // candidate appearance lifecycle from its module boundary.
      OwlCandidatePanelSettings.live.seed(state)
      state.candidateEmojiEnabled = OwlEmojiPreferences.candidateEmojiEnabled
      state.pinyinQuickPhraseCandidates = OwlKeyboardPreferences.pinyinQuickPhraseCandidates
      state.cloudEnabled = OwlCloudPreferences.isEnabled
      state.cloudModel = OwlCloudPreferences.deepSeekModel
      state.selectionMenuEnabled = OwlSelectionMenuPreferences.isEnabled
      state.askAnythingSkillEnabled = OwlSelectionMenuPreferences.askEnabled
      state.sourceVerificationSkillEnabled = OwlSelectionMenuPreferences.sourceVerificationEnabled
      state.researchAssistSkillEnabled = OwlSelectionMenuPreferences.researchAssistEnabled
      state.publishFormattingSkillEnabled = OwlSelectionMenuPreferences.publishFormattingEnabled
      state.translationSkillEnabled = OwlSelectionMenuPreferences.translationEnabled
      state.promptOptimizeSkillEnabled = OwlSelectionMenuPreferences.promptOptimizeEnabled
      state.goalBriefSkillEnabled = OwlSelectionMenuPreferences.goalBriefEnabled
      state.keyboardRerankEnabled = OwlExperimentalPreferences.keyboardRerankEnabled
      state.settledRerankEnabled = OwlExperimentalPreferences.settledRerankEnabled
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    // No `List(selection:)`: its native sidebar selection draws a system (blue) highlight
    // that fights our green accent pill ("蓝绿打架"). Drive selection by tap instead — same
    // pattern as `schemaRow` — so only our own selected background shows.
    List {
      Section {
        ForEach(OwlSettingsPage.visibleCases) { page in
          sidebarRow(page)
            .onTapGesture { state.selectedPage = page }
        }
      } header: {
        sidebarHeader
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 188, ideal: 200, max: 230)
    .scrollContentBackground(.hidden)
    .background(windowBackground)
    .safeAreaInset(edge: .bottom) { sidebarFooter }
  }

  /// Footer pinned to the sidebar bottom — Rust engine + version.
  private var sidebarFooter: some View {
    HStack(spacing: 0) {
      Text(engineFooterText)
        .font(.system(size: 11))
        .foregroundStyle(palette.ink3)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var engineFooterText: String {
    let version = state.librimeVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !version.isEmpty else { return "Rust 引擎" }
    let prefix = "msime-rust-"
    if version.hasPrefix(prefix) {
      return "msime-rust · v\(version.dropFirst(prefix.count))"
    }
    return "Rust 引擎 · \(version)"
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("猫头鹰输入法")
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(palette.ink)
      Text("Owltype")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.ink3)
    }
    .padding(.bottom, 6)
    .textCase(nil)
  }

  @ViewBuilder
  private func sidebarRow(_ page: OwlSettingsPage) -> some View {
    let selected = page == state.selectedPage
    HStack(spacing: 10) {
      Image(systemName: page.symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 24, height: 24)
        .foregroundStyle(selected ? palette.onAccent : palette.ink2)
        .background {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? palette.onAccent.opacity(0.2) : palette.card2)
        }
        .accessibilityHidden(true)
      Text(page.title)
        .font(.system(size: 14, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? palette.onAccent : palette.ink)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.accent)
      }
    }
    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
    .listRowBackground(Color.clear)
    .contentShape(Rectangle())
    .accessibilityIdentifier("settings.sidebar.\(page.rawValue)")
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    Group {
      switch state.selectedPage {
      case .keyboard:
        OwlKeyboardPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onSelectSchema: onSelectSchema,
          onRedeploy: onRedeploy,
          onApplyKeyboardConfigFast: onApplyKeyboardConfigFast,
          onApplyFuzzyConfigFast: onApplyFuzzyConfigFast,
          writesRimeConfiguration: writesRimeConfiguration
        )
      case .shortcuts:
        OwlKeyboardPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onSelectSchema: onSelectSchema,
          onRedeploy: onRedeploy,
          onApplyKeyboardConfigFast: onApplyKeyboardConfigFast,
          onApplyFuzzyConfigFast: onApplyFuzzyConfigFast,
          writesRimeConfiguration: writesRimeConfiguration,
          variant: .shortcuts
        )
      case .appearance:
        appearancePage
      case .schemes:
        schemesPage
      case .quickSend:
        OwlTemplateSettingsRoute(palette: palette, onRedeploy: { _ = onRedeploy() })
      case .clipboard:
        OwlClipboardPage(
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency
        )
      case .project:
        OwlSkillsPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency
        )
      case .ai:
        OwlAIPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency
        )
      case .skin:
        OwlSkinPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onPanelPreferencesChanged: onPanelPreferencesChanged
        )
      case .diagnostics:
        OwlDiagnosticsPage(
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency
        )
      case .about:
        OwlAboutPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          actionSection: { AnyView(actionSection) },
          statusLine: { AnyView(statusLine) }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(windowBackground)
  }

  // MARK: - Inline pages (reuse v0.2.x section builders verbatim)

  private var appearancePage: some View {
    ScrollView {
      VStack(spacing: 20) {
        // 候选窗设置 = candidate display only. 外观模式 + 皮肤预览 dropped (redundant — the
        // 皮肤外观 page owns skin + 明暗); 候选键位 live on the 快捷键设置 page.
        candidateDisplaySection
      }
      .padding(20)
    }
  }

  private var schemesPage: some View {
    ScrollView {
      VStack(spacing: 20) {
        schemaSection
      }
      .padding(20)
    }
  }

  // MARK: - Schema switching

  private var schemaSection: some View {
    sectionCard(title: "方案切换") {
      if state.schemas.isEmpty {
        Text("未找到已安装方案，请先应用配置改动。")
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 6) {
          ForEach(state.schemas) { schema in
            schemaRow(schema)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func schemaRow(_ schema: SchemaItem) -> some View {
    let selected = schema.id == state.currentSchemaId
    HStack(spacing: 10) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .foregroundStyle(selected ? palette.accent : palette.ink3)
      VStack(alignment: .leading, spacing: 1) {
        Text(schema.name)
          .font(.system(size: 14, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? palette.onAccent : palette.ink)
        Text(schema.id)
          .font(.system(size: 11))
          .foregroundStyle(selected ? palette.onAccent.opacity(0.8) : palette.ink3)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.accent)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture {
      OwlSettingsActions.selectSchemaRow(
        schema,
        currentSchemaID: state.currentSchemaId,
        onSelectSchema: onSelectSchema
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
  }

  // MARK: - Actions

  private var actionSection: some View {
    sectionCard(title: "维护与诊断") {
      VStack(spacing: 10) {
        Text("这些操作通常不需要每天使用；当设置没有立即生效、需要迁移旧版记录或排查问题时再打开。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)

        actionButton(title: OwlInputMenuTitles.deploy, systemImage: "arrow.triangle.2.circlepath") {
          _ = onRedeploy()
        }
        actionButton(title: OwlInputMenuTitles.migrateLegacyUserData, systemImage: "arrow.right.arrow.left.square", action: userDataActions.migrateLegacy)
        actionButton(title: OwlInputMenuTitles.resetUserDict, systemImage: "trash", action: userDataActions.resetUserDict)
        actionButton(title: OwlInputMenuTitles.rimeConfig, systemImage: "folder", action: onOpenRimeFolder)
        actionButton(title: OwlInputMenuTitles.logs, systemImage: "doc.text.magnifyingglass", action: onOpenLog)
        actionButton(title: OwlInputMenuTitles.onboarding, systemImage: "sparkles", action: onShowOnboarding)
      }
    }
  }

  private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
        Text(title)
          .font(.system(size: 14, weight: .medium))
        Spacer(minLength: 0)
      }
      .foregroundStyle(palette.onAccent)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.accent)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private var notoSerifSCDownloadPrompt: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("本机未安装 Noto Serif SC；候选窗会先用系统衬线回退。")
        .font(.system(size: 11))
        .foregroundStyle(palette.ink3)
      Button {
        NSWorkspace.shared.open(OwlCandidateFontSelection.notoSerifSCDownloadURL)
      } label: {
        Label("下载 Noto Serif SC 字体", systemImage: "arrow.down.circle")
      }
      .buttonStyle(OwlFilledButtonStyle(palette: palette))
      .accessibilityLabel("下载 Noto Serif SC 字体")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var mapleMonoDownloadPrompt: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("本机未安装 Maple Mono；候选窗会先用系统等宽字体回退。下载后解压，双击字体文件即可安装。")
        .font(.system(size: 11)).foregroundStyle(palette.ink3)
      Button { NSWorkspace.shared.open(OwlCandidateFontSelection.mapleMonoDownloadURL) } label: {
        Label("下载 Maple Mono CN 字体包", systemImage: "arrow.down.circle")
      }
      .buttonStyle(OwlFilledButtonStyle(palette: palette))
      .accessibilityLabel("下载 Maple Mono CN 字体包")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Candidate display (G8)

  /// 候选显示: every rendered panel option crosses `OwlCandidatePanelSettings` as one lifecycle.
  /// 候选个数 is Rime `menu/page_size`, so it flows through the keyboard patch + the fast
  /// config_file apply (`onApplyKeyboardConfigFast`) — effective immediately, no full `deploy()`.
  private var candidateDisplaySection: some View {
    let orientationBinding = Binding(
      get: { state.panelOrientation },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .orientation(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let fontSelectionBinding = Binding(
      get: { state.candidateFont.selection },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .font(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let fontSizeBinding = Binding(
      get: { state.panelFontSize },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .size(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let animationsBinding = Binding(
      get: { state.panelAnimationsEnabled },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .animationsEnabled(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let showPreeditBinding = Binding(
      get: { state.panelShowPreedit },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .showPreedit(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let pageSizeBinding = Binding(
      get: { state.candidatePageSize },
      set: { persistAndApplyCandidatePageSize($0) }
    )
    let inlineCandidateBinding = Binding(
      get: { state.panelInlineCandidate },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .inlineCandidate(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let showPagingBinding = Binding(
      get: { state.panelShowPaging },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .showPaging(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let notificationsBinding = Binding(
      get: { state.panelShowNotificationsWhen },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .showNotificationsWhen(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let candidateFormatBinding = Binding(
      get: { state.panelCandidateFormat },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .candidateFormat(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    let scrollRowsBinding = Binding(
      get: { state.panelScrollRows },
      set: { newValue in
        OwlCandidatePanelSettings.live.edit(
          .scrollRows(newValue), state: state, onChange: onPanelPreferencesChanged)
      }
    )
    return sectionCard(title: "候选显示") {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("排列方向")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          OwlSegmentedControl(
            selection: orientationBinding,
            options: [("自动", .auto), ("横排", .horizontal), ("竖排", .vertical), ("多行", .scroll)],
            palette: palette
          )
          Text("横排显示单行候选，竖排显示纵向列表。多行在翻页后显示多页候选，上方保留上一页，下方显示后续页，各列对齐。点击候选区的展开箭头可临时切换为列表。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
          if state.panelOrientation == .scroll {
            OwlSegmentedControl(
              selection: scrollRowsBinding,
              options: [("跟 1 页", 1), ("跟 2 页", 2), ("跟 3 页", 3), ("跟 4 页", 4)],
              palette: palette
            )
            Text("前/后页行稍淡、无序号，可用鼠标点选；数字键仍只对应带序号的当前页。")
              .font(.system(size: 11))
              .foregroundStyle(palette.ink3)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("候选字体")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          OwlSegmentedControl(
            selection: fontSelectionBinding,
            options: [("默认", .default), ("衬线", .serif), ("圆体", .rounded), ("Noto Serif SC", .notoSerifSC), ("Maple Mono", .mapleMono)],
            palette: palette
          )
          if state.candidateFont.unavailableSelection == .notoSerifSC {
            notoSerifSCDownloadPrompt
          }
          if state.candidateFont.unavailableSelection == .mapleMono {
            mapleMonoDownloadPrompt
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("候选窗尺寸")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          OwlSegmentedControl(
            selection: fontSizeBinding,
            options: [("小", .small), ("中", .medium), ("大", .large), ("特大", .extraLarge)],
            palette: palette
          )
          Text("候选字与面板留白一起缩放，整块候选窗按档位放大或收紧。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("候选个数")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          OwlSegmentedControl(
            selection: pageSizeBinding,
            options: [("3", 3), ("4", 4), ("5", 5), ("6", 6), ("7", 7), ("8", 8), ("9", 9)],
            palette: palette
          )
          .disabled(isApplyingCandidatePageSize)
          Text(candidatePageSizeApplyStatus ?? "改后立即生效（无需「重新部署」）。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        Toggle(isOn: animationsBinding) {
          Text("候选条动画")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
        }
        .tint(palette.accent)

        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: showPreeditBinding) {
            Text("候选窗显示输入串")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(palette.ink2)
          }
          .tint(palette.accent)
          Text("关掉后候选窗顶部不再重复拼音串，仅保留 App 内联预编辑。竖排下始终不显示。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        // Feature 7 — 候选格式预设（自绘面板 honor，不读 squirrel.yaml）。
        VStack(alignment: .leading, spacing: 6) {
          Text("候选格式")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          OwlSegmentedControl(
            selection: candidateFormatBinding,
            options: [("标准", .full), ("隐藏注释", .noComment), ("仅候选", .candidateOnly)],
            palette: palette
          )
          Text("标准=序号+候选+注释；隐藏注释=去掉拼音/释义；仅候选=只留候选字。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        // Feature 4 — 候选条翻页箭头（自绘面板）。
        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: showPagingBinding) {
            Text("候选条翻页箭头")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(palette.ink2)
          }
          .tint(palette.accent)
          Text("关掉后候选条不再显示上/下页圆点（鼠标翻页入口）；键盘翻页键不受影响。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        // Feature 3 — 内嵌候选预览（styleFlags.inlineCandidate 驱动）。
        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: inlineCandidateBinding) {
            Text("内嵌候选预览")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(palette.ink2)
          }
          .tint(palette.accent)
          Text("把高亮候选直接预览到 App 内联文本中（切换方案或重新输入后生效）。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        // Feature 5 — 切换提示通知（始终 / 智能 / 从不）。
        VStack(alignment: .leading, spacing: 6) {
          Text("切换提示通知")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          OwlSegmentedControl(
            selection: notificationsBinding,
            options: [("始终", .always), ("智能", .appropriate), ("从不", .never)],
            palette: palette
          )
          Text("方案 / 中英 / 简繁 切换时是否弹出提示；智能只在切换方案时提示。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

      }
    }
  }

  private func persistAndApplyCandidatePageSize(_ value: Int) {
    guard !isApplyingCandidatePageSize else { return }
    OwlSettingsActions.set(value, state: state, keyPath: \.candidatePageSize) {
      OwlKeyboardPreferences.pageSize = $0
    }
    applyCandidatePageSize()
  }

  private func applyCandidatePageSize() {
    guard !isApplyingCandidatePageSize else { return }
    isApplyingCandidatePageSize = true
    candidatePageSizeApplyStatus = "正在应用候选个数…"

    DispatchQueue.main.async {
      do {
        // Saving and activation belong to the shared settings application.
        let outcome = try onApplyKeyboardConfigFast()
        candidatePageSizeApplyStatus = Self.candidatePageSizeApplyStatusMessage(
          written: outcome.written,
          deploySucceeded: outcome.succeeded
        )
      } catch OwlConfigWriteError.refusedNeverTouch(let name) {
        candidatePageSizeApplyStatus = "已拒绝写入受保护文件：\(name)。候选个数未生效，请查看诊断日志。"
      } catch {
        candidatePageSizeApplyStatus = writesRimeConfiguration
          ? "写入失败，候选个数未生效，请查看诊断日志：\(error.localizedDescription)"
          : "应用失败，候选个数未生效，请查看诊断日志：\(error.localizedDescription)"
      }
      isApplyingCandidatePageSize = false
    }
  }

  static func candidatePageSizeApplyStatusMessage(
    written: [String],
    deploySucceeded: Bool,
    writesRimeConfiguration: Bool = true
  ) -> String {
    let files = written.joined(separator: "、")
    if deploySucceeded {
      return files.isEmpty ? "候选个数已生效。" : "候选个数已生效：\(files)。"
    }
    return files.isEmpty
      ? "应用失败，候选个数未生效，请查看诊断日志。"
      : writesRimeConfiguration
        ? "已写入 \(files)，但应用失败；候选个数未生效，请查看诊断日志。"
        : "应用失败，候选个数未生效，请查看诊断日志。"
  }

  // MARK: - Status line

  private var statusLine: some View {
    Text(state.statusMessage)
      .font(.system(size: 12))
      .foregroundStyle(palette.ink2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.card2)
      }
  }

  // MARK: - Shared chrome

  /// Thin wrapper over the extracted `SettingsCard` kit (`OwlSettingsComponents.swift`)
  /// so the v0.2.x section builders keep their original call sites.
  @ViewBuilder
  private func sectionCard<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    SettingsCard(
      title: title,
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency,
      content: content
    )
  }

  @ViewBuilder
  private var windowBackground: some View {
    // Darker than the cards so the lighter `card` panels float (the design's depth).
    if reduceTransparency {
      palette.card2.ignoresSafeArea()
    } else {
      palette.card2.opacity(0.94).ignoresSafeArea()
    }
  }
}
