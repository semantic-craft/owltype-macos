// Keyboard input settings persist preferences and apply them to active Rust sessions.

import AppKit
import SwiftUI

/// The 键盘输入 detail page. Palette/theme/reduceTransparency come from
/// `OwlSettingsView` (same arg style as the other pages); `state` carries the mirror
/// fields seeded by the delegate from `OwlKeyboardPreferences`.
struct OwlKeyboardPage: View {
  @Bindable var state: OwlSettingsState
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool
  let onSelectSchema: (String) -> Void
  let onRedeploy: () -> Bool
  /// Track-2 config-only fast apply (deploy_config_file + live reselect + replay; no full
  /// `deploy()`). Used by every Rime-backed toggle on this page EXCEPT 模糊拼音.
  let onApplyKeyboardConfigFast: () throws -> OwlKeyboardSettingsApplication.Outcome
  /// 模糊拼音 fast-ish apply (mtime-gated `fullCheck:false` maintenance — rebuilds the schema
  /// prism, not octagram — + reselect + replay). NOT instant; copy stays honest.
  let onApplyFuzzyConfigFast: () throws -> OwlKeyboardSettingsApplication.Outcome
  var writesConfigPatches = true

  /// Which card group this instance renders. 键盘输入 shows the four input cards plus the
  /// collapsed 高级 section; 快捷键设置 (a separate sidebar page) shows the five shortcut items. One view
  /// + one apply path, two sidebar entries — avoids duplicating all the toggle plumbing.
  enum Variant { case keyboard, shortcuts }  // ponytail: one view, two sidebar pages
  var variant: Variant = .keyboard

  /// Drives the 模糊拼音 「设置…」 `.sheet`.
  @State private var showFuzzySheet = false

  /// Drives the 指定「应用」默认英文 「管理…」 `.sheet`. `appEnglishSnapshot` records the
  /// bundle-ID list at open time so the parent applies the Rime patch once on dismiss
  /// only if something actually changed (matches the 模糊拼音 sheet's apply-on-close).
  @State private var showAppEnglishSheet = false
  @State private var appEnglishSnapshot: [String] = []

  /// Latest fuzzy snapshot, shown in the 模糊拼音 row summary. Refreshed from
  /// `OwlFuzzySnapshot.current()` on appear and whenever the fuzzy sheet closes (the
  /// sheet write-throughs to `OwlFuzzyPreferences`, so re-reading reflects the edits).
  @State private var fuzzySnapshot = OwlFuzzySnapshot.current()
  @State private var fuzzyEnabledCount = OwlFuzzySnapshot.current().enabledCount

  /// Settings apply as soon as a row changes, so the page shows nothing on success; a failed
  /// apply stays on screen until the next one succeeds. Local convenience transforms stay
  /// live-only and never report here.
  @State private var isAutoApplyingConfig = false
  @State private var applyFailure: String?

  /// 高级 starts collapsed: the four main cards cover everyday input.
  @State private var showAdvanced = false
  @State private var rerankRuntimeStatuses =
    OwlRerankRuntimeStatusRegistry.shared.snapshot()
  @State private var rerankStatusTimer: Timer?

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if let applyFailure {
          applyFailureCard(applyFailure)
        }
        switch variant {
        case .keyboard:
          inputMethodCard
          defaultStateCard
          fuzzyCard
          dictPackCard
          advancedToggle
          if showAdvanced {
            wubiCard
            rerankCard
            symbolCard
            candidateEmojiCard
            localConvenienceCard
          }
        case .shortcuts:
          cjkSwitchCard
          pagingAndSelectCard
          OwlPinnedWordsSettings(palette: palette, theme: theme, reduceTransparency: reduceTransparency)
          quickSendPanelHotKeyCard
          selectionMenuPanelHotKeyCard
        }
      }
      .padding(20)
    }
    .onAppear {
      refreshFuzzySnapshot()
      startRerankStatusRefresh()
    }
    .onDisappear {
      rerankStatusTimer?.invalidate()
      rerankStatusTimer = nil
    }
    .sheet(isPresented: $showFuzzySheet, onDismiss: {
      refreshFuzzySnapshotAndApplyIfNeeded()
    }) {
      OwlFuzzySheet(palette: palette, theme: theme, reduceTransparency: reduceTransparency)
    }
    .sheet(isPresented: $showAppEnglishSheet, onDismiss: {
      if OwlKeyboardPreferences.appEnglishBundleIDs != appEnglishSnapshot {
        applyCurrentKeyboardSnapshot()
      }
    }) {
      OwlAppEnglishSheet(
        palette: palette,
        theme: theme,
        reduceTransparency: reduceTransparency,
        bundleIDs: OwlKeyboardPreferences.appEnglishBundleIDs,
        onChange: { newIDs in
          OwlSettingsActions.setAppEnglishBundleIDsText(newIDs.joined(separator: "\n"), state: state)
        }
      )
    }
  }

  // MARK: - 输入方式

  /// Shown only after an apply failed, so a change that did not take effect is never silent.
  private func applyFailureCard(_ message: String) -> some View {
    SettingsCard(title: "", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 13))
          .foregroundStyle(.orange)
        Text(message)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// 高级：五笔细节、本地重排、符号、emoji 与快捷短语、本地便捷输入。Collapsed by default.
  private var advancedToggle: some View {
    Button(action: { showAdvanced.toggle() }, label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .rotationEffect(.degrees(showAdvanced ? 90 : 0))
        Text("高级")
          .font(.system(size: 13, weight: .semibold))
        Text("五笔、本地重排、符号、emoji 与快捷短语、便捷输入")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
        Spacer(minLength: 0)
      }
      .foregroundStyle(palette.ink2)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    })
    .buttonStyle(.plain)
    .accessibilityLabel(showAdvanced ? "收起高级设置" : "展开高级设置")
    .accessibilityIdentifier("settings.keyboard.advanced")
  }

  /// 完整词库（方案B）：公开包只带清洁室精简词库；此卡展示 dict-pack 拉取状态并提供手动
  /// 触发。状态由 OwlDictPackCenter（@Observable）驱动，准备/启用/回退都在 Center。
  private var dictPackCard: some View {
    let center = OwlDictPackCenter.shared
    return SettingsCard(title: "完整词库", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          switch center.status {
          case .notInstalled:
            Text("未启用 — 当前使用随包精简资源")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
            dictPackActionButton("立即下载（约 90 MB）") { center.prepare() }
          case .preparing(let progress):
            ProgressView(value: progress)
              .controlSize(.small)
              .frame(maxWidth: 180)
            Text("下载、校验并生成资源 \(Int(progress * 100))%")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
          case .prepared(let version):
            Image(systemName: "checkmark.seal")
              .font(.system(size: 13))
              .foregroundStyle(palette.accentDeep)
            Text("候选 v\(version) 已生成，尚未启用")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
            dictPackActionButton("启用") { center.activate() }
          case .activating:
            ProgressView()
              .controlSize(.small)
            Text("正在校验并启用资源…")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
          case .rollingBack:
            ProgressView()
              .controlSize(.small)
            Text("正在校验并回退资源…")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
          case .installed(let version):
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(OwlProvenanceColor.verified)
            Text(center.isAwaitingLiveSessionRefresh
              ? "完整词库 v\(version) 已启用；当前输入完成后自动生效"
              : "完整词库已安装（v\(version)）")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
            if let target = center.rollbackTargetVersion {
              dictPackActionButton("回退到 v\(target)") { center.rollback() }
            }
          case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 13))
              .foregroundStyle(.orange)
            Text(message)
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
              .lineLimit(2)
            Spacer(minLength: 8)
            dictPackActionButton("重试") { center.retryFailedOperation() }
          }
        }
        if let candidate = center.preparedCandidate {
          Text(
            "生成统计：拼音 \(candidate.pinyinEntries.formatted()) 条 · "
              + "五笔 \(candidate.wubiEntries.formatted()) 条 · "
              + "英文 \(candidate.englishEntries.formatted()) 条 · "
              + "拒绝 \(candidate.rejectedEntries.formatted()) 条"
          )
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          Text("许可证：\(candidate.licenseIdentifiers.joined(separator: "、")) · 摘要 \(candidate.digest.prefix(19))…")
            .font(.system(size: 11.5))
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("完整词库来自第三方开源项目，为避免版权争议不随安装包分发，也不会在你不知情时自动下载。下载后会先校验版本、摘要和许可证，再显示生成统计；只有点「启用」才切换资源代次，旧版本保留可回退。更新不改写 msime-user 学习库，也不触发 Rime 部署。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear { center.refresh() }
  }

  private func dictPackActionButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action, label: {
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.accentDeep)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.card2)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(palette.accentDeep.opacity(0.30), lineWidth: 1)
        }
        .contentShape(Rectangle())
    })
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  /// ◉ 拼音输入 / ○ 双拼输入 [小鹤双拼 ▼] / ○ 五笔 86 / ○ 五笔拼音混输.
  /// The scheme `Picker` is enabled only when 双拼 is selected. Radios write the
  /// input-method mirror + prefs; the Picker writes the double-pinyin mirror + prefs.
  private var inputMethodCard: some View {
    let methodBinding = Binding(
      get: { state.keyboardInputMethod },
      set: { newValue in
        OwlSettingsActions.selectInputMethod(
          newValue,
          state: state,
          applyConfig: applyCurrentKeyboardSnapshot,
          onSelectSchema: onSelectSchema
        )
      }
    )
    let schemeBinding = Binding(
      get: { state.keyboardDoublePinyin },
      set: { newValue in
        OwlSettingsActions.selectDoublePinyin(
          newValue,
          state: state,
          applyConfig: applyCurrentKeyboardSnapshot,
          onSelectSchema: onSelectSchema
        )
      }
    )
    let wubiSchemeBinding = Binding(
      get: { state.keyboardWubiScheme },
      set: { newValue in
        OwlSettingsActions.selectWubiScheme(
          newValue,
          state: state,
          applyConfig: applyCurrentKeyboardSnapshot,
          onSelectSchema: onSelectSchema
        )
      }
    )
    return SettingsCard(
      title: "输入方式",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        ForEach(OwlInputMethod.allCases, id: \.self) { method in
          SettingsRadioRow(
            title: method.displayName,
            isSelected: methodBinding.wrappedValue == method,
            palette: palette,
            onSelect: { methodBinding.wrappedValue = method }
          ) {
            if method == .doublePinyin {
              doublePinyinPicker(methodBinding: methodBinding, schemeBinding: schemeBinding)
            } else if method == .wubi {
              wubiSchemePicker(methodBinding: methodBinding, schemeBinding: wubiSchemeBinding)
            }
          }
          if method != OwlInputMethod.allCases.last {
            SettingsCardDivider(palette: palette)
          }
        }
        // 底座方案署名：拼音 / 双拼走雾凇拼音（rime-ice），五笔走极点五笔 86。
        // 用户看得见自己在用谁家的方案，也是 GPL 上游的显性致谢。
        Text("拼音与双拼底座：雾凇拼音 rime-ice；五笔：极点五笔 86。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
      .disabled(!configBackedRowsEnabled)
      .opacity(configBackedRowsEnabled ? 1 : 0.55)
    }
  }

  private func doublePinyinPicker(
    methodBinding: Binding<OwlInputMethod>,
    schemeBinding: Binding<OwlDoublePinyin>
  ) -> some View {
    let pickerEnabled = Self.isDoublePinyinPickerEnabled(for: methodBinding.wrappedValue)
    return Group {
      Picker("双拼方案", selection: schemeBinding) {
        ForEach(OwlDoublePinyin.allCases, id: \.self) { scheme in
          Text(scheme.displayName).tag(scheme)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      .disabled(!pickerEnabled)
      .opacity(Self.doublePinyinPickerOpacity(for: methodBinding.wrappedValue))
    }
  }

  static func isDoublePinyinPickerEnabled(for method: OwlInputMethod) -> Bool {
    method == .doublePinyin
  }

  static func doublePinyinPickerOpacity(for method: OwlInputMethod) -> Double {
    isDoublePinyinPickerEnabled(for: method) ? 1 : 0.4
  }

  /// 五笔方案 dropdown — same shape as `doublePinyinPicker`; lives in the 五笔输入 row and is
  /// enabled (full opacity) only when 五笔输入 is the selected method.
  private func wubiSchemePicker(
    methodBinding: Binding<OwlInputMethod>,
    schemeBinding: Binding<OwlWubiScheme>
  ) -> some View {
    let enabled = methodBinding.wrappedValue == .wubi
    return Picker("五笔方案", selection: schemeBinding) {
      ForEach(OwlWubiScheme.allCases, id: \.self) { scheme in
        Text(scheme.displayName).tag(scheme)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.4)
  }

  // MARK: - 默认状态（搜狗式：新会话 / 切 App 时的初始态）

  /// 中英文 / 简繁体 / 全半角 三个下拉，决定输入法激活时的初始状态（跨会话持久）。简繁体复用
  /// `traditionalOutput`（原「简入繁出」卡的唯一入口）；中英文 / 全半角 走新增的 `defaultAsciiMode`
  /// / `defaultFullShape` pref。改下拉即写 pref + 对当前 live session 立即生效；新 session 从 pref seed。
  private var defaultStateCard: some View {
    let asciiBinding = Binding(
      get: { state.keyboardDefaultAsciiMode },
      set: { newValue in
        setSwitch(.defaultAsciiMode, newValue)
        NSApp.owlAppDelegate.applyDefaultAsciiModeToLiveSession(newValue)
      }
    )
    let traditionalBinding = Binding(
      get: { state.keyboardTraditionalOutput },
      set: { newValue in
        setSwitch(.traditionalOutput, newValue)
        NSApp.owlAppDelegate.applyTraditionalOutputToLiveSession(newValue)
      }
    )
    let fullShapeBinding = Binding(
      get: { state.keyboardDefaultFullShape },
      set: { newValue in
        setSwitch(.defaultFullShape, newValue)
        NSApp.owlAppDelegate.applyDefaultFullShapeToLiveSession(newValue)
      }
    )
    return SettingsCard(
      title: "中英文与初始状态",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        OwlAppModeControls(palette: palette)
        defaultStatePickerRow(title: "初始中英文", selection: asciiBinding, offLabel: "中文", onLabel: "英文")
        SettingsCardDivider(palette: palette)
        defaultStatePickerRow(title: "简繁体", selection: traditionalBinding, offLabel: "简体", onLabel: "繁体")
        SettingsCardDivider(palette: palette)
        defaultStatePickerRow(title: "全半角", selection: fullShapeBinding, offLabel: "半角", onLabel: "全角")
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("指定应用初始英文").font(.system(size: 13))
            Text(appEnglishSummary + "；已有记忆时优先恢复上次选择。")
              .font(.system(size: 12)).foregroundStyle(palette.ink3)
          }
          Spacer()
          Button("管理…") {
            appEnglishSnapshot = OwlKeyboardPreferences.appEnglishBundleIDs
            showAppEnglishSheet = true
          }
        }.padding(.vertical, 10)
        Text("简繁体打开后全拼 / 双拼 / 五笔候选转繁体（s2t），立即生效。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
    }
  }

  /// A 默认状态 row: left label + a hidden-label two-option menu `Picker` over a Bool
  /// (false→`offLabel` / true→`onLabel`). Same layout as the wubi 单字候选 row.
  private func defaultStatePickerRow(
    title: String,
    selection: Binding<Bool>,
    offLabel: String,
    onLabel: String
  ) -> some View {
    HStack(spacing: 11) {
      Text(title)
        .font(.system(size: 14))
        .foregroundStyle(palette.ink)
      Spacer(minLength: 8)
      Picker(title, selection: selection) {
        Text(offLabel).tag(false)
        Text(onLabel).tag(true)
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
    }
    .padding(.vertical, 8)
  }

  // MARK: - 五笔

  private var wubiCard: some View {
    let modeBinding = Binding(
      get: { state.keyboardWubiCandidateMode },
      set: { newValue in
        persistAndApplyConfig {
          OwlSettingsActions.set(newValue, state: state, keyPath: \.keyboardWubiCandidateMode) {
            OwlKeyboardPreferences.wubiCandidateMode = $0
          }
        }
      }
    )
    return SettingsCard(
      title: "五笔",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        OwlWubiCommitSettings(
          autoCommitUnique: state.keyboardWubiAutoCommitUnique,
          fifthCodeTopCommit: state.keyboardWubiFifthCodeTopCommit,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggleAutoCommitUnique: { toggle(.wubiAutoCommitUnique) },
          onToggleFifthCodeTopCommit: { toggle(.wubiFifthCodeTopCommit) }
        )
        OwlWubiLookupSettings(
          codeHint: state.keyboardWubiCodeHint,
          zWildcard: state.keyboardWubiZWildcard,
          zReverseLookup: state.keyboardWubiZReverseLookup,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggleCodeHint: { toggle(.wubiCodeHint) },
          onToggleZWildcard: { toggle(.wubiZWildcard) },
          onToggleZReverseLookup: { toggle(.wubiZReverseLookup) }
        )
        SettingsToggleRow(
          title: "空码自动清码",
          isOn: state.keyboardWubiAutoClear,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.wubiAutoClear) }
        )
        SettingsCardDivider(palette: palette)
        HStack(spacing: 11) {
          Text("单字候选")
            .font(.system(size: 14))
            .foregroundStyle(palette.ink)
          Spacer(minLength: 8)
          OwlSegmentedControl(
            selection: modeBinding,
            options: OwlWubiCandidateMode.allCases.map { ($0.displayName, $0) },
            palette: palette
          )
          .frame(width: 220)
          .disabled(!configBackedRowsEnabled)
        }
        .padding(.vertical, 8)
        .opacity(configBackedRowsEnabled ? 1 : 0.55)
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "` 临时英文",
          isOn: state.keyboardWubiEnglishChannel,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.wubiEnglishChannel) }
        )
        Text("按 `（反引号）后直接打英文单词，候选出英文、上屏后回到五笔；不切换模式，也不影响四码上屏。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "记住我常用的词（个性化）",
          isOn: state.keyboardWubiUserDictLearning,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.wubiUserDictLearning) }
        )
      }
    }
  }

  // MARK: - 中英文状态切换

  /// ☑ 使用 Shift 切换中英文 [⇧]（左右 Shift 都切）· ☑ Caps Lock 切换西文（经典 good_old_caps_lock）。
  /// (中文下使用英文标点 moved to the 「符号」card on the 键盘输入 page.)
  private var cjkSwitchCard: some View {
    SettingsCard(
      title: "中英文状态切换",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        SettingsCheckRow(
          title: "使用 Shift 切换中英文",
          isOn: state.keyboardShiftSwitchCJK,
          keys: ["⇧"],
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.shiftSwitchCJK) }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "Caps Lock 切换西文",
          isOn: state.keyboardGoodOldCapsLock,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.goodOldCapsLock) }
        )
      }
    }
  }

  // 简入繁出 卡已并入「默认状态」组的「简繁体」下拉（同一 `traditionalOutput` pref，
  // 去重，对标搜狗式默认状态）。

  // MARK: - 翻页与选词键

  /// ☑ 减号等号 [- =] · ☐ 左右中括号 [[ ]] · ☑ 逗号句号 [, 。] · ☐ 分号引号选 2/3 位 [; ']
  private var pagingAndSelectCard: some View {
    SettingsCard(
      title: "翻页与选词键",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        SettingsCheckRow(
          title: "减号等号翻页",
          isOn: state.keyboardPageMinusEquals,
          keys: ["- ="],
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.pageMinusEquals) }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "左右中括号翻页",
          isOn: state.keyboardPageBrackets,
          keys: ["[ ]"],
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.pageBrackets) }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "逗号句号翻页",
          isOn: state.keyboardPageCommaPeriod,
          keys: [", 。"],
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.pageCommaPeriod) }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "分号引号选 2/3 位",
          isOn: state.keyboardSelect23Semicolon,
          keys: ["; '"],
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.select23Semicolon) }
        )
      }
    }
  }

  /// 快捷短语面板 summon hotkey (default off — the user RECORDS a combo here, same restricted range
  /// as 划词菜单; NOT a Rime key_binder, never touches the config pipeline). Was a three-preset
  /// Picker defaulting to ⌃⇧Space; both hotkeys now share `OwlHotKeyRecorderRow` and start unset.
  private var quickSendPanelHotKeyCard: some View {
    SettingsCard(
      title: "快捷片段",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 12) {
        OwlHotKeyRecorderRow(slot: .quickSendPanel, palette: palette)
        DisclosureGroup("直达提示词筛选（可选）") {
          OwlHotKeyRecorderRow(slot: .promptAssistant, palette: palette)
          Text("打开同一个快捷片段库并筛选提示词，已有快捷键继续有效。")
            .font(.system(size: 12)).foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// 划词工具箱 summon hotkey (default off — the user RECORDS a combo here, restricted range; never
  /// a Rime key_binder). The recorder control + its labels live in the UI layer
  /// (`OwlHotKeyRecorderRow`); the IMK-path matcher reads the stored combo live, so recording
  /// needs no re-registration. 工具箱 enable（双击 ⌥ 手势）/permission live on 划词工具箱页；本热键
  /// 是平行入口，不受那个开关约束。
  private var selectionMenuPanelHotKeyCard: some View {
    SettingsCard(
      title: "划词工具箱",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 8) {
        OwlHotKeyRecorderRow(slot: .selectionMenu, palette: palette)
        Text("默认的内置唤起键为双击 ⌥（Option）键，无需录制；这里录的组合是并行入口，不录也不影响双击唤起。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: - 模糊拼音

  /// 模糊拼音 row with a summary line ("已开启 N 项" / "未开启") and a 「设置…」 button
  /// that opens `OwlFuzzySheet`. The sheet owns the per-pair toggles + write-through;
  /// this card only summarizes and launches it (no key literals here).
  private var fuzzyCard: some View {
    SettingsCard(
      title: "模糊拼音",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("模糊拼音")
            .font(.system(size: 14))
            .foregroundStyle(palette.ink)
          Text(fuzzyEnabledCount == 0 ? "未开启" : "已开启 \(fuzzyEnabledCount) 项")
            .font(.system(size: 12))
            .foregroundStyle(palette.ink3)
        }
        Spacer(minLength: 8)
        Button(action: { showFuzzySheet = true }) {
          Text("设置…")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accent)
            }
        }
        .buttonStyle(.plain)
        .disabled(isAutoApplyingConfig)
        .opacity(isAutoApplyingConfig ? 0.55 : 1)
        .accessibilityLabel("设置模糊拼音")
      }
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 本地轻量重排

  private var rerankCard: some View {
    SettingsCard(
      title: "本地轻量重排（实验）",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 10) {
        SettingsToggleRow(
          title: "逐键候选重排",
          isOn: state.keyboardRerankEnabled,
          palette: palette,
          onToggle: { toggleKeyboardRerank() }
        )
        Text("每次按键用 4.3 MB 本地模型轻量排序；按真实来源保护精确词、用户置顶、快捷短语和生成句。\(rerankResourceSummary(.keyboard))")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
        Text(rerankStatusLine(.keyboard))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.ink2)
          .frame(maxWidth: .infinity, alignment: .leading)

        SettingsCardDivider(palette: palette)

        SettingsToggleRow(
          title: "停顿候选重排",
          isOn: state.settledRerankEnabled,
          palette: palette,
          onToggle: { toggleSettledRerank() }
        )
        Text("停止输入 150 ms 后用 24.3 MB 桌面模型在后台重排；旧结果会丢弃并归还模型，不阻塞继续输入。\(rerankResourceSummary(.settled))")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
        Text(rerankStatusLine(.settled))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.ink2)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text("两个开关默认关闭。模型来自 metasequoiaime/chinese-ime-lm model-v1；权重许可 Apache-2.0，来源与完整 SHA-256 随模型 manifest 提供。")
          .font(.system(size: 11))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - 符号

  /// 中文标点模式、`/` 与 `<` 的可选候选菜单。
  private var symbolCard: some View {
    SettingsCard(
      title: "符号",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "中文下使用英文标点",
          isOn: state.keyboardCJKPunctToggle,
          palette: palette,
          isEnabled: configBackedRowsEnabled,
          onToggle: { toggle(.cjkPunctToggle) }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "输入中文时 “/” 弹出符号选单",
          isOn: state.keyboardSlashSymbolMenu,
          palette: palette,
          isEnabled: symbolMenusEnabled,
          onToggle: { toggle(.slashSymbolMenu) }
        )
        Text("打开后按 / 键从 、 / ／ ÷ 里挑一个；关闭时维持默认行为：提交当前中文候选、切到英文并直接输入 /。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "输入中文时 “<” 弹出符号选单",
          isOn: state.keyboardAngleSymbolMenu,
          palette: palette,
          isEnabled: symbolMenusEnabled,
          onToggle: { toggle(.angleSymbolMenu) }
        )
        Text("按 < 键从 《 〈 < 「 “ 里挑一个；首选仍是 《，继续打字会自动上屏首选。配合「成对输入」，选出的开括号（含弯引号）会自动补全成对。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
      }
    }
  }

  // MARK: - 候选 emoji

  /// 在打字候选里显示 emoji, applied live via the delegate (no redeploy). Defaults on when never
  /// stored, like the pinned macOS upstream (`OwlEmojiPreferences.candidateEmojiEnabled`).
  private var candidateEmojiCard: some View {
    SettingsCard(title: "emoji 与快捷短语", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "在候选中显示 emoji",
          isOn: state.candidateEmojiEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.candidateEmojiEnabled) {
              OwlEmojiPreferences.candidateEmojiEnabled = $0
            }
            NSApp.owlAppDelegate.applyEmojiSuggestionToLiveSession(state.candidateEmojiEnabled)
          }
        )
        SettingsToggleRow(
          title: "普通候选中显示快捷短语", isOn: state.quickPhraseCandidates,
          palette: palette, onToggle: { toggle(.quickPhraseCandidates) }
        )
        Text("打开后，打字时 emoji 会作为候选出现（如 weixiao → 微笑 😊）。默认开启，与水杉一致。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
      }
    }
  }

  private var localConvenienceCard: some View {
    SettingsCard(
      title: "本地便捷输入",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "中文与英文间加入空格",
          isOn: state.keyboardCJKAlnumSpacing,
          palette: palette,
          onToggle: { toggleCJKAlnumSpacing() }
        )
        SettingsCardDivider(palette: palette)
        smartPunctuationRows
        // 07-21 机主拍板改名：配对表早已不限于括号（含引号 + ASCII），名称与最初需求「成对输入」对齐。
        // 注释必须在 SettingsToggleRow( 之外——覆盖清单的提取正则不容 `(` 与 `title:` 之间有注释行。
        SettingsToggleRow(
          title: "成对输入",
          isOn: state.keyboardAutoPairBrackets,
          palette: palette,
          onToggle: { toggle(.autoPairBrackets) }
        )
        Text("拼音输入括号或引号时补全闭合符，闭合符随当前组合一起提交。五笔保留原有配对方式。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
      }
    }
  }

  /// 指定「应用」默认使用英文: a row summarising how many apps are set + a 「管理…」 button
  /// that opens `OwlAppEnglishSheet` (WeChat-style icon/name picker, replaces the old
  /// comma-separated bundle-ID text field). Storage + apply path are unchanged.
  /// Reactive count of configured apps (reads the observed mirror, not prefs, so the row
  /// refreshes after the sheet closes). Phrased so the empty state still explains itself.
  private var appEnglishSummary: String {
    let ids = OwlKeyboardPreferences.normalizedAppEnglishBundleIDs(
      from: state.keyboardAppEnglishBundleIDsText
    )
    return ids.isEmpty ? "未指定应用（指定后该应用默认英文输入）" : "已指定 \(ids.count) 个应用"
  }

  private var configBackedRowsEnabled: Bool {
    !isAutoApplyingConfig
  }

  private var symbolMenusEnabled: Bool {
    configBackedRowsEnabled
  }

  private func persistAndApplyConfig(_ mutation: () -> Void) {
    guard !isAutoApplyingConfig else { return }
    mutation()
    applyCurrentKeyboardSnapshot()
  }

  /// Track-2 config-only apply path (页内 Rime-backed toggles + App 默认英文). The shared application module writes the
  /// managed patch, then config deploy + live reselect + replay makes it
  /// effective immediately — no full `EngineRuntime.redeploy()`.
  private func applyCurrentKeyboardSnapshot() {
    applyKeyboardSnapshot(onApplyKeyboardConfigFast)
  }

  /// 模糊拼音 apply path. `speller/algebra` rebuilds the schema PRISM, which the config-only
  /// fast path does NOT do, so this uses the mtime-gated `fullCheck:false` maintenance —
  /// faster than the full `deploy()` but not instant.
  private func applyFuzzyKeyboardSnapshot() {
    applyKeyboardSnapshot(onApplyFuzzyConfigFast)
  }

  private func applyKeyboardSnapshot(_ apply: @escaping () throws -> OwlKeyboardSettingsApplication.Outcome) {
    guard !isAutoApplyingConfig else { return }
    isAutoApplyingConfig = true

    DispatchQueue.main.async {
      do {
        let outcome = try apply()
        applyFailure = outcome.succeeded
          ? nil
          : Self.autoApplyStatusMessage(
            written: outcome.written,
            deploySucceeded: false,
            writesConfigPatches: writesConfigPatches
          )
      } catch OwlConfigWriteError.refusedNeverTouch(let name) {
        applyFailure = "已拒绝写入受保护文件：\(name)。改动未生效，请查看诊断日志。"
      } catch {
        applyFailure = writesConfigPatches
          ? "写入失败，改动未生效，请查看诊断日志：\(error.localizedDescription)"
          : "应用失败，改动未生效，请查看诊断日志：\(error.localizedDescription)"
      }
      isAutoApplyingConfig = false
    }
  }

  private func refreshFuzzySnapshot() {
    let current = OwlFuzzySnapshot.current()
    fuzzySnapshot = current
    fuzzyEnabledCount = current.enabledCount
  }

  private func startRerankStatusRefresh() {
    rerankRuntimeStatuses = OwlRerankRuntimeStatusRegistry.shared.snapshot()
    rerankStatusTimer?.invalidate()
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
      rerankRuntimeStatuses = OwlRerankRuntimeStatusRegistry.shared.snapshot()
    }
    rerankStatusTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func rerankResourceSummary(_ kind: OwlRerankModelKind) -> String {
    let descriptor = OwlRerankModelDescriptor.descriptor(for: kind)
    return "\(descriptor.version) · \(descriptor.license) · SHA-256 \(descriptor.sha256Prefix)…"
  }

  private func rerankStatusLine(_ kind: OwlRerankModelKind) -> String {
    guard OwlExperimentalPreferences.rerankEnabled(for: kind) else {
      return "状态：已关闭"
    }
    if let runtime = rerankRuntimeStatuses[kind] {
      switch runtime.state {
      case "ready":
        return "状态：已加载并完成 SHA-256 校验"
      case "loading":
        return "状态：正在后台校验并加载…"
      case "missing":
        return "状态：包内模型缺失，输入继续使用普通排序"
      case "corrupt":
        return "状态：模型校验失败，输入继续使用普通排序"
      case "oversized":
        return "状态：模型文件超出大小上限，已拒绝加载"
      case "error":
        return "状态：加载失败，输入继续使用普通排序"
      case "disabled":
        return "状态：已关闭"
      default:
        return "状态：\(runtime.state)"
      }
    }

    let descriptor = OwlRerankModelDescriptor.descriptor(for: kind)
    guard let url = descriptor.url(sharedSupportURL: Bundle.main.sharedSupportURL) else {
      return "状态：应用资源目录不可用"
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value
    guard let size else {
      return "状态：包内模型缺失"
    }
    guard size == descriptor.expectedSize else {
      return "状态：文件大小不符（\(size) bytes）"
    }
    return "状态：随包文件已就位，输入后加载"
  }

  private func refreshFuzzySnapshotAndApplyIfNeeded() {
    let previous = fuzzySnapshot
    refreshFuzzySnapshot()
    if fuzzySnapshot != previous {
      applyFuzzyKeyboardSnapshot()
    }
  }

  static func autoApplyStatusMessage(
    written: [String],
    deploySucceeded: Bool,
    writesConfigPatches: Bool = true
  ) -> String {
    let files = written.joined(separator: "、")
    if deploySucceeded {
      return files.isEmpty ? "配置已生效。" : "已生效：\(files)。"
    }
    return files.isEmpty
      ? "应用失败，改动未生效，请查看诊断日志。"
      : writesConfigPatches
        ? "已写入 \(files)，但应用失败；改动未生效，请查看诊断日志。"
        : "应用失败，改动未生效，请查看诊断日志。"
  }

  // MARK: - Switch write path

  /// The one write path for catalog switches: update the mirror, persist through the catalog,
  /// then re-apply the keyboard configuration when the row asks for it.
  func toggle(_ toggle: OwlKeyboardSwitch) {
    setSwitch(toggle, !state[keyPath: toggle.row.mirror])
  }

  func setSwitch(_ toggle: OwlKeyboardSwitch, _ value: Bool) {
    let write = {
      OwlSettingsActions.set(value, state: state, keyPath: toggle.row.mirror) {
        OwlKeyboardSettingsCatalog.live.set(toggle, $0)
      }
    }
    if toggle.row.reappliesConfiguration {
      persistAndApplyConfig(write)
    } else {
      write()
    }
  }

  // 左右 Command 选 2/3：暂不开放——UI 行 isEnabled:false，snapshot 硬编码 false 且由
  // OwlSettingsE2ETests 锁死（macOS 优先处理 ⌘，待真机验证后再加绑定）。故此处刻意没有
  // toggle handler；别再加回来，否则就是一个永远不会被调用的死开关。

  /// One UI switch over two catalog keys, so it is not a catalog row of its own.
  private func toggleCJKAlnumSpacing() {
    OwlSettingsActions.toggle(state: state, keyPath: \.keyboardCJKAlnumSpacing) {
      OwlKeyboardPreferences.cjkAlnumSpacing = $0
      state.keyboardCJKEnglishSpacing = $0
      state.keyboardCJKNumberSpacing = $0
    }
  }

  private func toggleKeyboardRerank() {
    OwlSettingsActions.toggle(state: state, keyPath: \.keyboardRerankEnabled) {
      OwlExperimentalPreferences.keyboardRerankEnabled = $0
    }
    rerankRuntimeStatuses = OwlRerankRuntimeStatusRegistry.shared.snapshot()
  }

  private func toggleSettledRerank() {
    OwlSettingsActions.toggle(state: state, keyPath: \.settledRerankEnabled) {
      OwlExperimentalPreferences.settledRerankEnabled = $0
    }
    rerankRuntimeStatuses = OwlRerankRuntimeStatusRegistry.shared.snapshot()
  }
}
