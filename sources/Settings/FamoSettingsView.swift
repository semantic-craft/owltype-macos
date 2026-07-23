//
//  FamoSettingsView.swift
//  法墨输入法 (Famo) — SwiftUI settings window
//
//  v0.3: the settings UI as a sidebar-nav app (NavigationSplitView, 豆包/微信-style).
//  Left = a List of user-facing pages (键盘输入 / 候选窗外观 / 快捷短语 / 关于); right = grouped
//  深大红 cards. 深大红 themed (light/dark via `colorScheme`), honors Reduce Motion /
//  Reduce Transparency like `FamoCandidatePanelView`.
//
//  The v0.2.x section builders (`schemaSection`, `candidateDisplaySection`,
//  `actionSection`, `statusLine`) are
//  REUSED unchanged — only re-grouped under the sidebar pages. The 关于 / 键盘输入 page
//  bodies live in `FamoSettingsPages.swift`; the shared card chrome in
//  `FamoSettingsComponents.swift` (`SettingsCard`).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only.
//  Actions are forwarded to the delegate via the `on…` closures; no Rime / disk
//  IO happens in the view itself.
//

import AppKit
import SwiftUI

struct FamoSettingsView: View {
  @Bindable var state: FamoSettingsState

  /// Tap a schema row → switch the active schema (`schema_id`). Wired to the
  /// delegate's `selectSchema(_:)`.
  let onSelectSchema: (String) -> Void
  /// 应用配置改动 → delegate `deploy()` (the heavy full maintenance; 维护与诊断「重新部署」).
  let onRedeploy: () -> Bool
  /// Track-2 config-only fast apply → delegate `applyKeyboardConfigFast()` (deploy_config_file
  /// + live reselect + replay; no `shutdownRime`). Used for 候选个数 / 键位 / 标点 / schema_list.
  let onApplyKeyboardConfigFast: () -> Bool
  /// 模糊拼音 fast-ish apply → delegate `applyFuzzyConfigFast()` (mtime-gated `fullCheck:false`
  /// maintenance — rebuilds the affected schema prism + reselect + replay).
  let onApplyFuzzyConfigFast: () -> Bool
  /// 同步用户数据 → delegate `syncUserData()`.
  let onSyncUserData: () -> Void
  /// 设置同步目录 → delegate-owned NSOpenPanel + installation.yaml write.
  let onChooseSyncDirectory: () -> Void
  /// 打开用户目录 → delegate `openRimeFolder()`.
  let onOpenRimeFolder: () -> Void
  /// 日志 → delegate `openLogFolder()`.
  let onOpenLog: () -> Void
  /// 欢迎与引导 → delegate `showOnboarding()`.
  let onShowOnboarding: () -> Void
  /// Candidate-panel visual prefs changed → refresh any visible candidate panel.
  let onPanelPreferencesChanged: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  @State private var isApplyingCandidatePageSize = false
  @State private var candidatePageSizeApplyStatus: String?

  /// Active theme = the chosen skin (`皮肤外观` page). Writing `state.skin` re-skins the
  /// whole window. Shared palette/theme with the candidate panel.
  private var theme: FamoCandidateTheme { state.skin.theme }

  /// Resolved palette for the window's active color scheme.
  private var palette: FamoCandidatePalette {
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
    .accessibilityIdentifier("FamoSettingsView")
    .onAppear {
      // Delegate-free seed of the skin / emoji mirrors from their prefs homes, so the
      // window opens reflecting the saved choices (the pages write back through both).
      state.skin = FamoSkinPreferences.skin
      state.candidateEmojiEnabled = FamoEmojiPreferences.candidateEmojiEnabled
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    // No `List(selection:)`: its native sidebar selection draws a system (blue) highlight
    // that fights our green accent pill ("蓝绿打架"). Drive selection by tap instead — same
    // pattern as `schemaRow` — so only our own selected background shows.
    List {
      Section {
        ForEach(FamoSettingsPage.visibleCases) { page in
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

  /// Footer pinned to the sidebar bottom — engine + version (the design's "librime · v…").
  private var sidebarFooter: some View {
    HStack(spacing: 0) {
      Text(state.librimeVersion.isEmpty ? "librime" : "librime · v\(state.librimeVersion)")
        .font(.system(size: 11))
        .foregroundStyle(palette.ink3)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("法墨输入法")
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(palette.ink)
      Text("Famo")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.ink3)
    }
    .padding(.bottom, 6)
    .textCase(nil)
  }

  @ViewBuilder
  private func sidebarRow(_ page: FamoSettingsPage) -> some View {
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
        FamoKeyboardPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onSelectSchema: onSelectSchema,
          onRedeploy: onRedeploy,
          onApplyKeyboardConfigFast: onApplyKeyboardConfigFast,
          onApplyFuzzyConfigFast: onApplyFuzzyConfigFast
        )
      case .shortcuts:
        FamoKeyboardPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onSelectSchema: onSelectSchema,
          onRedeploy: onRedeploy,
          onApplyKeyboardConfigFast: onApplyKeyboardConfigFast,
          onApplyFuzzyConfigFast: onApplyFuzzyConfigFast,
          variant: .shortcuts
        )
      case .appearance:
        appearancePage
      case .schemes:
        schemesPage
      case .quickSend:
        FamoQuickSendPage(
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onRedeploy: onRedeploy
        )
      case .prompts:
        FamoPromptPage(
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency
        )
      case .skin:
        FamoSkinPage(
          state: state,
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency,
          onPanelPreferencesChanged: onPanelPreferencesChanged
        )
      case .diagnostics:
        FamoDiagnosticsPage(
          palette: palette,
          theme: theme,
          reduceTransparency: reduceTransparency
        )
      case .about:
        FamoAboutPage(
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
      FamoSettingsActions.selectSchemaRow(
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
        Text("这些操作通常不需要每天使用；当设置没有立即生效、需要同步输入习惯，或排查问题时再打开。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
        FamoSyncDirectoryInfo(path: state.syncDirectoryDisplayPath, palette: palette)

        actionButton(title: FamoInputMenuTitles.deploy, systemImage: "arrow.triangle.2.circlepath") {
          _ = onRedeploy()
        }
        actionButton(title: FamoInputMenuTitles.syncDirectory, systemImage: "folder.badge.gearshape", action: onChooseSyncDirectory)
        actionButton(title: FamoInputMenuTitles.syncUserData, systemImage: "arrow.triangle.2.circlepath", action: onSyncUserData)
        actionButton(title: FamoInputMenuTitles.rimeConfig, systemImage: "folder", action: onOpenRimeFolder)
        actionButton(title: FamoInputMenuTitles.logs, systemImage: "doc.text.magnifyingglass", action: onOpenLog)
        actionButton(title: FamoInputMenuTitles.onboarding, systemImage: "sparkles", action: onShowOnboarding)
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
        NSWorkspace.shared.open(FamoPanelFontDesign.notoSerifSCDownloadURL)
      } label: {
        Label("下载 Noto Serif SC 字体", systemImage: "arrow.down.circle")
      }
      .buttonStyle(FamoFilledButtonStyle(palette: palette))
      .accessibilityLabel("下载 Noto Serif SC 字体")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Candidate display (G8)

  /// 候选显示: orientation / typeface / count / animation / scroll-vs-single. The four
  /// panel options write through `FamoPanelPreferences` (live — next composition reflects
  /// them, like 候选窗外观). 候选个数 is Rime `menu/page_size`, so it flows through the
  /// keyboard patch + the fast config_file apply (`onApplyKeyboardConfigFast`) — effective
  /// immediately, no full `deploy()`. Each `Binding` writes BOTH the observable mirror AND
  /// the prefs home, keeping the UserDefaults key strings in one place.
  private var candidateDisplaySection: some View {
    let orientationBinding = Binding(
      get: { state.panelOrientation },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelOrientation) {
            FamoPanelPreferences.orientation = $0
          }
        }
      }
    )
    let fontDesignBinding = Binding(
      get: { state.panelFontDesign },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelFontDesign) {
            FamoPanelPreferences.fontDesign = $0
          }
        }
      }
    )
    let fontSizeBinding = Binding(
      get: { state.panelFontSize },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelFontSize) {
            FamoPanelPreferences.fontSize = $0
          }
        }
      }
    )
    let animationsBinding = Binding(
      get: { state.panelAnimationsEnabled },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelAnimationsEnabled) {
            FamoPanelPreferences.animationsEnabled = $0
          }
        }
      }
    )
    let showPreeditBinding = Binding(
      get: { state.panelShowPreedit },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelShowPreedit) {
            FamoPanelPreferences.showPreedit = $0
          }
        }
      }
    )
    let pageSizeBinding = Binding(
      get: { state.candidatePageSize },
      set: { persistAndApplyCandidatePageSize($0) }
    )
    let inlineCandidateBinding = Binding(
      get: { state.panelInlineCandidate },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelInlineCandidate) {
            FamoPanelPreferences.inlineCandidate = $0
          }
        }
      }
    )
    let showPagingBinding = Binding(
      get: { state.panelShowPaging },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelShowPaging) {
            FamoPanelPreferences.showPaging = $0
          }
        }
      }
    )
    let notificationsBinding = Binding(
      get: { state.panelShowNotificationsWhen },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelShowNotificationsWhen) {
            FamoPanelPreferences.showNotificationsWhen = $0
          }
        }
      }
    )
    let candidateFormatBinding = Binding(
      get: { state.panelCandidateFormat },
      set: { newValue in
        persistPanelPreference {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.panelCandidateFormat) {
            FamoPanelPreferences.candidateFormat = $0
          }
        }
      }
    )
    return sectionCard(title: "候选显示") {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("排列方向")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          FamoSegmentedControl(
            selection: orientationBinding,
            options: [("自动", .auto), ("横排", .horizontal), ("竖排", .vertical), ("折行", .flow)],
            palette: palette
          )
          Text("横排=单行候选条，竖排=纵向列表，折行=横向多行矩形。横排/折行可点候选条右侧箭头临时展开为列表。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("候选字体")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          FamoSegmentedControl(
            selection: fontDesignBinding,
            options: [("默认", .default), ("衬线", .serif), ("圆体", .rounded), ("Noto Serif SC", .notoSerifSC)],
            palette: palette
          )
          if state.panelFontDesign == .notoSerifSC && !FamoPanelFontDesign.isNotoSerifSCInstalled {
            notoSerifSCDownloadPrompt
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("候选字号")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          FamoSegmentedControl(
            selection: fontSizeBinding,
            options: [("小", .small), ("中", .medium), ("大", .large)],
            palette: palette
          )
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("候选个数")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          FamoSegmentedControl(
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
          Text("关掉后候选窗顶部不再重复拼音串，仅保留 App 内联预编辑。")
            .font(.system(size: 11))
            .foregroundStyle(palette.ink3)
        }

        // Feature 7 — 候选格式预设（自绘面板 honor，不读 squirrel.yaml）。
        VStack(alignment: .leading, spacing: 6) {
          Text("候选格式")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink2)
          FamoSegmentedControl(
            selection: candidateFormatBinding,
            options: [("标准", .full), ("隐藏注释", .noComment), ("仅候选", .candidateOnly)],
            palette: palette
          )
          Text("标准=序号+候选+注释；隐藏注释=去掉拼音/释义；仅候选=只留候选字。法务徽章不受影响。")
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
          FamoSegmentedControl(
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

  private func persistPanelPreference(_ mutation: () -> Void) {
    mutation()
    onPanelPreferencesChanged()
  }

  private func persistAndApplyCandidatePageSize(_ value: Int) {
    guard !isApplyingCandidatePageSize else { return }
    FamoSettingsActions.set(value, state: state, keyPath: \.candidatePageSize) {
      FamoKeyboardPreferences.pageSize = $0
    }
    applyCandidatePageSize()
  }

  private func applyCandidatePageSize() {
    guard !isApplyingCandidatePageSize else { return }
    isApplyingCandidatePageSize = true
    candidatePageSizeApplyStatus = "正在应用候选个数…"

    DispatchQueue.main.async {
      do {
        // 候选个数 is Rime `menu/page_size` (config-only): write the managed patch, then the
        // fast config_file deploy + live reselect makes it effective immediately (no full
        // `deploy()` / shutdownRime). page_size lives in `default.yaml`, which Famo's schema
        // does not shadow, so the override is honored.
        let written = try FamoManagedKeyboardPatchPlan.apply(snapshot: FamoKeyboardSnapshot.current())
        candidatePageSizeApplyStatus = Self.candidatePageSizeApplyStatusMessage(
          written: written,
          deploySucceeded: onApplyKeyboardConfigFast()
        )
      } catch FamoConfigWriteError.refusedNeverTouch(let name) {
        candidatePageSizeApplyStatus = "已拒绝写入受保护文件：\(name)。候选个数未生效，请查看诊断日志。"
      } catch {
        candidatePageSizeApplyStatus = "写入失败，候选个数未生效，请查看诊断日志：\(error.localizedDescription)"
      }
      isApplyingCandidatePageSize = false
    }
  }

  static func candidatePageSizeApplyStatusMessage(written: [String], deploySucceeded: Bool) -> String {
    let files = written.joined(separator: "、")
    if deploySucceeded {
      return files.isEmpty ? "候选个数已生效。" : "候选个数已生效：\(files)。"
    }
    return files.isEmpty
      ? "应用失败，候选个数未生效，请查看诊断日志。"
      : "已写入 \(files)，但应用失败；候选个数未生效，请查看诊断日志。"
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

  /// Thin wrapper over the extracted `SettingsCard` kit (`FamoSettingsComponents.swift`)
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

private struct FamoSyncDirectoryInfo: View {
  let path: String
  let palette: FamoCandidatePalette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("同步用户数据会合并并备份 Rime 用户词典、自造词、词频和输入习惯快照；目录可放在 iCloud、Dropbox 或 OneDrive，Famo 不会自动上传。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text("同步目录")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(palette.ink2)
        Text(path.isEmpty ? "未读取" : path)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(palette.ink3)
          .lineLimit(2)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
