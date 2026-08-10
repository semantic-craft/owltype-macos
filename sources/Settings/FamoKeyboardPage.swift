//
//  FamoKeyboardPage.swift
//  法墨输入法 (Famo) — 键盘输入 settings page
//
//  v0.3.1: the input-method option groups (输入方式 / 中英文切换 / 候选翻页快捷键 /
//  候选快速选词 / 符号), modeled on the 豆包输入法 reference. Built from the shared
//  card kit (`SettingsCard` / `SettingsCheckRow` / `SettingsRadioRow` / `KeyChip` in
//  `FamoSettingsComponents.swift`) and persisted via `FamoKeyboardPreferences`.
//
//  Write-through pattern (v0.2.1/2.2): each control uses an explicit
//  `Binding(get:set:)` that updates BOTH the `FamoSettingsState` mirror AND
//  `FamoKeyboardPreferences`, so the UserDefaults key strings live solely in
//  `FamoKeyboardPreferences` (this file contains NO key literals). `@Observable`
//  `didSet` is intentionally avoided — it does not fire reliably under the macro.
//
//  Persistence boundary (see `.trellis/spec/frontend/famo-modern-ui-direction.md`):
//  these options map to Rime YAML. The page saves choices in UserDefaults and routes
//  Rime-backed toggles through the managed-block writer plus the existing deploy path.
//  Settings auto-apply; the page-level apply button is only a manual fallback for
//  forcing those derived patches again.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only — never
//  touches the IMK key-event hot path (FamoInputController).
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the settings UI).
//

import AppKit
import SwiftUI

/// The 键盘输入 detail page. Palette/theme/reduceTransparency come from
/// `FamoSettingsView` (same arg style as the other pages); `state` carries the mirror
/// fields seeded by the delegate from `FamoKeyboardPreferences`.
struct FamoKeyboardPage: View {
  @Bindable var state: FamoSettingsState
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool
  let onSelectSchema: (String) -> Void
  let onRedeploy: () -> Bool
  /// Track-2 config-only fast apply (deploy_config_file + live reselect + replay; no full
  /// `deploy()`). Used by every Rime-backed toggle on this page EXCEPT 模糊拼音.
  let onApplyKeyboardConfigFast: () -> Bool
  /// 模糊拼音 fast-ish apply (mtime-gated `fullCheck:false` maintenance — rebuilds the schema
  /// prism, not octagram — + reselect + replay). NOT instant; copy stays honest.
  let onApplyFuzzyConfigFast: () -> Bool

  /// Which card group this instance renders. 键盘输入 shows everything except the three
  /// shortcut cards; 快捷键设置 (a separate sidebar page) shows only those three. One view
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
  /// `FamoFuzzySnapshot.current()` on appear and whenever the fuzzy sheet closes (the
  /// sheet write-throughs to `FamoFuzzyPreferences`, so re-reading reflects the edits).
  @State private var fuzzySnapshot = FamoFuzzySnapshot.current()
  @State private var fuzzyEnabledCount = FamoFuzzySnapshot.current().enabledCount

  /// Compact click-to-apply state for Rime-backed rows. Local convenience transforms
  /// stay live-only and do not use this status line.
  @State private var isAutoApplyingRimeConfig = false
  @State private var autoApplyStatus: String?

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        switch variant {
        case .keyboard:
          applyConfigCard
          inputMethodCard
          dictPackCard
          defaultStateCard
          wubiCard
          fuzzyCard
          symbolCard
          candidateEmojiCard
          localConvenienceCard
          appEnglishCard
        case .shortcuts:
          cjkSwitchCard
          pagingCard
          quickSelectCard
          quickSendPanelHotKeyCard
          selectionMenuPanelHotKeyCard
          promptAssistantHotKeyCard
          noteCard
        }
      }
      .padding(20)
    }
    .onAppear { refreshFuzzySnapshot() }
    .sheet(isPresented: $showFuzzySheet, onDismiss: {
      refreshFuzzySnapshotAndApplyIfNeeded()
    }) {
      FamoFuzzySheet(palette: palette, theme: theme, reduceTransparency: reduceTransparency)
    }
    .sheet(isPresented: $showAppEnglishSheet, onDismiss: {
      if FamoKeyboardPreferences.appEnglishBundleIDs != appEnglishSnapshot {
        applyCurrentKeyboardSnapshot()
      }
    }) {
      FamoAppEnglishSheet(
        palette: palette,
        theme: theme,
        reduceTransparency: reduceTransparency,
        bundleIDs: FamoKeyboardPreferences.appEnglishBundleIDs,
        onChange: { newIDs in
          FamoSettingsActions.setAppEnglishBundleIDsText(newIDs.joined(separator: "\n"), state: state)
        }
      )
    }
  }

  // MARK: - 输入方式

  private var applyConfigCard: some View {
    SettingsCard(title: "", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 8) {
        // 配置改动本就自动应用 → 把「重新应用」从满宽主按钮降级为右侧次级钮，左侧常驻自动应用状态。
        HStack(spacing: 10) {
          HStack(spacing: 6) {
            if isAutoApplyingRimeConfig {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(FamoProvenanceColor.verified)
            }
            Text(autoApplyStatus ?? "改动已自动保存并应用")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(isAutoApplyingRimeConfig ? palette.ink2 : palette.ink3)
          }
          Spacer(minLength: 8)
          Button(action: { applyCurrentKeyboardSnapshot() }, label: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 12))
              Text("保存并重新应用")
                .font(.system(size: 13, weight: .medium))
            }
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
          .disabled(!rimeBackedRowsEnabled)
          .opacity(rimeBackedRowsEnabled ? 1 : 0.5)
          .accessibilityLabel("保存并重新应用")
        }

        Text("配置改动即时生效；此处仅用于异常时重新写入并应用当前键盘设置。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// 完整词库（方案B）：公开包只带清洁室精简词库；此卡展示 dict-pack 拉取状态并提供手动
  /// 触发。状态由 FamoDictPackCenter（@Observable）驱动，下载/校验/装配全在 Center/Fetcher。
  private var dictPackCard: some View {
    let center = FamoDictPackCenter.shared
    return SettingsCard(title: "完整词库", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          switch center.status {
          case .notInstalled:
            Text("未安装 — 当前为精简词库，候选质量受限")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
            dictPackActionButton("立即下载（约 90 MB）") { center.start() }
          case .downloading(let progress):
            ProgressView(value: progress)
              .controlSize(.small)
              .frame(maxWidth: 180)
            Text("下载中 \(Int(progress * 100))%")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
          case .deploying:
            ProgressView()
              .controlSize(.small)
            Text("正在编译词库…")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
          case .installed(let version):
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(FamoProvenanceColor.verified)
            Text("完整词库已安装（v\(version)）")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
          case .userProvided:
            Image(systemName: "checkmark.circle")
              .font(.system(size: 13))
              .foregroundStyle(FamoProvenanceColor.verified)
            Text("检测到自备完整词库（不由法墨管理，不会被覆盖）")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
          case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 13))
              .foregroundStyle(.orange)
            Text("下载失败：\(message)")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink2)
              .lineLimit(2)
            Spacer(minLength: 8)
            dictPackActionButton("重试") { center.start() }
          }
        }
        Text("完整词库来自第三方开源项目，为避免版权争议不随安装包分发，也不会在你不知情时自动下载。点下载后按固定版本从上游原仓库（雾凇拼音 / 极点五笔 / 八股文语法模型）获取并逐文件校验，完成后自动重新部署。")
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
        FamoSettingsActions.selectInputMethod(
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
        FamoSettingsActions.selectDoublePinyin(
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
        FamoSettingsActions.selectWubiScheme(
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
        ForEach(FamoInputMethod.allCases, id: \.self) { method in
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
          if method != FamoInputMethod.allCases.last {
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
      .disabled(!rimeBackedRowsEnabled)
      .opacity(rimeBackedRowsEnabled ? 1 : 0.55)
    }
  }

  private func doublePinyinPicker(
    methodBinding: Binding<FamoInputMethod>,
    schemeBinding: Binding<FamoDoublePinyin>
  ) -> some View {
    let pickerEnabled = Self.isDoublePinyinPickerEnabled(for: methodBinding.wrappedValue)
    return Group {
      Picker("双拼方案", selection: schemeBinding) {
        ForEach(FamoDoublePinyin.allCases, id: \.self) { scheme in
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

  static func isDoublePinyinPickerEnabled(for method: FamoInputMethod) -> Bool {
    method == .doublePinyin
  }

  static func doublePinyinPickerOpacity(for method: FamoInputMethod) -> Double {
    isDoublePinyinPickerEnabled(for: method) ? 1 : 0.4
  }

  /// 五笔方案 dropdown — same shape as `doublePinyinPicker`; lives in the 五笔输入 row and is
  /// enabled (full opacity) only when 五笔输入 is the selected method.
  private func wubiSchemePicker(
    methodBinding: Binding<FamoInputMethod>,
    schemeBinding: Binding<FamoWubiScheme>
  ) -> some View {
    let enabled = methodBinding.wrappedValue == .wubi
    return Picker("五笔方案", selection: schemeBinding) {
      ForEach(FamoWubiScheme.allCases, id: \.self) { scheme in
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
        FamoSettingsActions.set(newValue, state: state, keyPath: \.keyboardDefaultAsciiMode) {
          FamoKeyboardPreferences.defaultAsciiMode = $0
        }
        NSApp.famoAppDelegate.applyDefaultAsciiModeToLiveSession(newValue)
      }
    )
    let traditionalBinding = Binding(
      get: { state.keyboardTraditionalOutput },
      set: { newValue in
        FamoSettingsActions.set(newValue, state: state, keyPath: \.keyboardTraditionalOutput) {
          FamoKeyboardPreferences.traditionalOutput = $0
        }
        NSApp.famoAppDelegate.applyTraditionalOutputToLiveSession(newValue)
      }
    )
    let fullShapeBinding = Binding(
      get: { state.keyboardDefaultFullShape },
      set: { newValue in
        FamoSettingsActions.set(newValue, state: state, keyPath: \.keyboardDefaultFullShape) {
          FamoKeyboardPreferences.defaultFullShape = $0
        }
        NSApp.famoAppDelegate.applyDefaultFullShapeToLiveSession(newValue)
      }
    )
    return SettingsCard(
      title: "默认状态",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        defaultStatePickerRow(title: "中英文", selection: asciiBinding, offLabel: "中文", onLabel: "英文")
        SettingsCardDivider(palette: palette)
        defaultStatePickerRow(title: "简繁体", selection: traditionalBinding, offLabel: "简体", onLabel: "繁体")
        SettingsCardDivider(palette: palette)
        defaultStatePickerRow(title: "全半角", selection: fullShapeBinding, offLabel: "半角", onLabel: "全角")
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
        persistAndApplyRimeConfig {
          FamoSettingsActions.set(newValue, state: state, keyPath: \.keyboardWubiCandidateMode) {
            FamoKeyboardPreferences.wubiCandidateMode = $0
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
        SettingsToggleRow(
          title: "候选编码提示",
          isOn: state.keyboardWubiCodeHint,
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleWubiCodeHint() }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "空码自动清码",
          isOn: state.keyboardWubiAutoClear,
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleWubiAutoClear() }
        )
        SettingsCardDivider(palette: palette)
        HStack(spacing: 11) {
          Text("单字候选")
            .font(.system(size: 14))
            .foregroundStyle(palette.ink)
          Spacer(minLength: 8)
          FamoSegmentedControl(
            selection: modeBinding,
            options: FamoWubiCandidateMode.allCases.map { ($0.displayName, $0) },
            palette: palette
          )
          .frame(width: 220)
          .disabled(!rimeBackedRowsEnabled)
        }
        .padding(.vertical, 8)
        .opacity(rimeBackedRowsEnabled ? 1 : 0.55)
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "z 临时拼音反查",
          isOn: state.keyboardWubiZReverseLookup,
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleWubiZReverseLookup() }
        )
        Text("按 z 加拼音查字，候选右侧始终显示该字的五笔编码，边打边记；不受上面的「候选编码提示」影响。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "` 临时英文",
          isOn: state.keyboardWubiEnglishChannel,
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleWubiEnglishChannel() }
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
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleWubiUserDictLearning() }
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
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleShiftSwitchCJK() }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "Caps Lock 切换西文",
          isOn: state.keyboardGoodOldCapsLock,
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleGoodOldCapsLock() }
        )
      }
    }
  }

  // 简入繁出 卡已并入「默认状态」组的「简繁体」下拉（同一 `traditionalOutput` pref，
  // 去重，对标搜狗式默认状态）。

  // MARK: - 候选翻页快捷键

  /// ☑ 减号等号 [- =] · ☑ 左右中括号 [[ ]] · ☐ 逗号句号 [, 。]
  private var pagingCard: some View {
    SettingsCard(
      title: "候选翻页快捷键",
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
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { togglePageMinusEquals() }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "左右中括号翻页",
          isOn: state.keyboardPageBrackets,
          keys: ["[ ]"],
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { togglePageBrackets() }
        )
        SettingsCardDivider(palette: palette)
        SettingsCheckRow(
          title: "逗号句号翻页",
          isOn: state.keyboardPageCommaPeriod,
          keys: [", 。"],
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { togglePageCommaPeriod() }
        )
      }
    }
  }

  // MARK: - 候选快速选词

  /// ☐ 分号引号选 2/3 位 [; ']
  private var quickSelectCard: some View {
    SettingsCard(
      title: "候选快速选词",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        SettingsCheckRow(
          title: "分号引号选 2/3 位",
          isOn: state.keyboardSelect23Semicolon,
          keys: ["; '"],
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleSelect23Semicolon() }
        )
      }
    }
  }

  /// 快捷短语面板 summon hotkey (default off — the user RECORDS a combo here, same restricted range
  /// as 划词菜单; NOT a Rime key_binder, never touches the config pipeline). Was a three-preset
  /// Picker defaulting to ⌃⇧Space; both hotkeys now share `FamoHotKeyRecorderRow` and start unset.
  private var quickSendPanelHotKeyCard: some View {
    SettingsCard(
      title: "快捷短语面板",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      FamoHotKeyRecorderRow(slot: .quickSendPanel, palette: palette)
    }
  }

  /// 划词工具箱 summon hotkey (default off — the user RECORDS a combo here, restricted range; never
  /// a Rime key_binder). The recorder control + its labels live in the UI layer
  /// (`FamoHotKeyRecorderRow`); the IMK-path matcher reads the stored combo live, so recording
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
        FamoHotKeyRecorderRow(slot: .selectionMenu, palette: palette)
        Text("默认的内置唤起键为双击 ⌥（Option）键，无需录制；这里录的组合是并行入口，不录也不影响双击唤起。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // 任意提问的直达热键卡已随 FamoHotKeySlot.askAnything 一并退役（产品决策 2026-07-26）：
  // 任意提问是划词技能的兜底，入口收敛为唯一一条「选中文字 → 召唤划词工具箱」（状态栏菜单项同日删除）。

  /// 提示词助手直达热键（07-21 机主提案）：同一块快捷面板、初始分段=提示词。五笔的专属入口——
  /// 提示词表不挂五笔 schema（守四码上屏），打字触发只在拼音下存在。
  private var promptAssistantHotKeyCard: some View {
    SettingsCard(
      title: "提示词助手",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 8) {
        FamoHotKeyRecorderRow(slot: .promptAssistant, palette: palette)
        Text("按下热键直接打开提示词列表（任意输入方案可用，含五笔）；选中带 {{变量}} 的模板会先弹填空再插入。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: - 模糊拼音

  /// 模糊拼音 row with a summary line ("已开启 N 项" / "未开启") and a 「设置…」 button
  /// that opens `FamoFuzzySheet`. The sheet owns the per-pair toggles + write-through;
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
        .disabled(isAutoApplyingRimeConfig)
        .opacity(isAutoApplyingRimeConfig ? 0.55 : 1)
        .accessibilityLabel("设置模糊拼音")
      }
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
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
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleCJKPunct() }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "输入中文时 “/” 弹出符号选单",
          isOn: state.keyboardSlashSymbolMenu,
          palette: palette,
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleSlashSymbolMenu() }
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
          isEnabled: rimeBackedRowsEnabled,
          onToggle: { toggleAngleSymbolMenu() }
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

  /// 在打字候选里显示 emoji — drives the rime-ice 原生 `emoji` switch, applied LIVE via the
  /// delegate (no redeploy). Famo ships it OFF (famo-seed.sh resets the schema switch 1→0).
  /// Relocated here from the removed 表情符号 page (the 表情/符号面板 itself lives on the menu bar).
  private var candidateEmojiCard: some View {
    SettingsCard(title: "", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "在候选中显示 emoji",
          isOn: state.candidateEmojiEnabled,
          palette: palette,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.candidateEmojiEnabled) {
              FamoEmojiPreferences.candidateEmojiEnabled = $0
            }
            NSApp.famoAppDelegate.applyEmojiSuggestionToLiveSession(state.candidateEmojiEnabled)
          }
        )
        Text("打开后，打字时 emoji 会作为候选出现（如 weixiao → 微笑 😊）。默认关闭；也可用 ⌃⇧E 或输入法菜单临时切换。")
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
        // 07-21 机主拍板改名：配对表早已不限于括号（含引号 + ASCII），名称与最初需求「成对输入」对齐。
        // 注释必须在 SettingsToggleRow( 之外——覆盖清单的提取正则不容 `(` 与 `title:` 之间有注释行。
        SettingsToggleRow(
          title: "成对输入",
          isOn: state.keyboardAutoPairBrackets,
          palette: palette,
          onToggle: { toggleAutoPairBrackets() }
        )
        Text("输入下列开符号自动补全成对：（） 【】 《》 〈〉 「」 『』 〔〕 “” ‘’ <> () [] {}。标准文本应用中光标停在符号中间，其余应用光标在符号后。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .padding(.bottom, 4)
      }
    }
  }

  /// 指定「应用」默认使用英文: a row summarising how many apps are set + a 「管理…」 button
  /// that opens `FamoAppEnglishSheet` (WeChat-style icon/name picker, replaces the old
  /// comma-separated bundle-ID text field). Storage + apply path are unchanged.
  private var appEnglishCard: some View {
    SettingsCard(
      title: "指定「应用」默认使用英文",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      HStack(spacing: 10) {
        Text(appEnglishSummary)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
        Spacer(minLength: 0)
        Button(action: {
          appEnglishSnapshot = FamoKeyboardPreferences.appEnglishBundleIDs
          showAppEnglishSheet = true
        }) {
          Text("管理…")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.accent.opacity(0.6), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("管理…")
      }
      .padding(.vertical, 4)
    }
  }

  /// Reactive count of configured apps (reads the observed mirror, not prefs, so the row
  /// refreshes after the sheet closes). Phrased so the empty state still explains itself.
  private var appEnglishSummary: String {
    let ids = FamoKeyboardPreferences.normalizedAppEnglishBundleIDs(
      from: state.keyboardAppEnglishBundleIDsText
    )
    return ids.isEmpty ? "未指定应用（指定后该应用默认英文输入）" : "已指定 \(ids.count) 个应用"
  }

  // MARK: - 说明 footnote

  /// Persistence-boundary note for the 快捷键 page, whose Rime-backed rows also auto-apply.
  private var noteCard: some View {
    SettingsCard(
      title: "",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text("快捷键配置会自动写入 ~/Library/Application Support/Famo 并应用。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var rimeBackedRowsEnabled: Bool {
    !isAutoApplyingRimeConfig
  }

  private func persistAndApplyRimeConfig(_ mutation: () -> Void) {
    guard !isAutoApplyingRimeConfig else { return }
    mutation()
    applyCurrentKeyboardSnapshot()
  }

  /// Track-2 config-only apply path (页内 Rime-backed toggles + App 默认英文). Writes the
  /// managed patch, then the FAST config_file deploy + live reselect + replay makes it
  /// effective immediately — no full `deploy()` / shutdownRime.
  private func applyCurrentKeyboardSnapshot() {
    applyKeyboardSnapshot(progress: "正在应用配置…", apply: onApplyKeyboardConfigFast)
  }

  /// 模糊拼音 apply path. `speller/algebra` rebuilds the schema PRISM, which the config-only
  /// fast path does NOT do, so this uses the mtime-gated `fullCheck:false` maintenance —
  /// faster than the full `deploy()` but honestly not instant (copy says "可能需要片刻").
  private func applyFuzzyKeyboardSnapshot() {
    applyKeyboardSnapshot(progress: "正在应用模糊拼音（可能需要片刻）…", apply: onApplyFuzzyConfigFast)
  }

  private func applyKeyboardSnapshot(progress: String, apply: @escaping () -> Bool) {
    guard !isAutoApplyingRimeConfig else { return }
    isAutoApplyingRimeConfig = true
    autoApplyStatus = progress

    DispatchQueue.main.async {
      do {
        let written = try FamoManagedKeyboardPatchPlan.apply(snapshot: FamoKeyboardSnapshot.current())
        autoApplyStatus = Self.autoApplyStatusMessage(
          written: written,
          deploySucceeded: apply()
        )
      } catch FamoConfigWriteError.refusedNeverTouch(let name) {
        autoApplyStatus = "已拒绝写入受保护文件：\(name)。改动未生效，请查看诊断日志。"
      } catch {
        autoApplyStatus = "写入失败，改动未生效，请查看诊断日志：\(error.localizedDescription)"
      }
      isAutoApplyingRimeConfig = false
    }
  }

  private func refreshFuzzySnapshot() {
    let current = FamoFuzzySnapshot.current()
    fuzzySnapshot = current
    fuzzyEnabledCount = current.enabledCount
  }

  private func refreshFuzzySnapshotAndApplyIfNeeded() {
    let previous = fuzzySnapshot
    refreshFuzzySnapshot()
    if fuzzySnapshot != previous {
      applyFuzzyKeyboardSnapshot()
    }
  }

  static func autoApplyStatusMessage(written: [String], deploySucceeded: Bool) -> String {
    let files = written.joined(separator: "、")
    if deploySucceeded {
      return files.isEmpty ? "配置已生效。" : "已生效：\(files)。"
    }
    return files.isEmpty
      ? "应用失败，改动未生效，请查看诊断日志。"
      : "已写入 \(files)，但应用失败；改动未生效，请查看诊断日志。"
  }

  // MARK: - Bool write-through helpers

  // Each toggle flips the mirror + writes through to `FamoKeyboardPreferences` in one
  // place, keeping the card bodies declarative and the key literals out of this file.

  private func toggleShiftSwitchCJK() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardShiftSwitchCJK) {
        FamoKeyboardPreferences.shiftSwitchCJK = $0
      }
    }
  }

  private func toggleCJKPunct() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardCJKPunctToggle) {
        FamoKeyboardPreferences.cjkPunctToggle = $0
      }
    }
  }

  private func toggleGoodOldCapsLock() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardGoodOldCapsLock) {
        FamoKeyboardPreferences.goodOldCapsLock = $0
      }
    }
  }

  private func togglePageMinusEquals() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardPageMinusEquals) {
        FamoKeyboardPreferences.pageMinusEquals = $0
      }
    }
  }

  private func togglePageBrackets() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardPageBrackets) {
        FamoKeyboardPreferences.pageBrackets = $0
      }
    }
  }

  private func togglePageCommaPeriod() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardPageCommaPeriod) {
        FamoKeyboardPreferences.pageCommaPeriod = $0
      }
    }
  }

  private func toggleSelect23Semicolon() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardSelect23Semicolon) {
        FamoKeyboardPreferences.select23Semicolon = $0
      }
    }
  }

  // 左右 Command 选 2/3：暂不开放——UI 行 isEnabled:false，snapshot 硬编码 false 且由
  // FamoSettingsE2ETests 锁死（macOS 优先处理 ⌘，待真机验证后再加绑定）。故此处刻意没有
  // toggle handler；别再加回来，否则就是一个永远不会被调用的死开关。

  private func toggleWubiCodeHint() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardWubiCodeHint) {
        FamoKeyboardPreferences.wubiCodeHint = $0
      }
    }
  }

  private func toggleWubiAutoClear() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardWubiAutoClear) {
        FamoKeyboardPreferences.wubiAutoClear = $0
      }
    }
  }

  private func toggleWubiZReverseLookup() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardWubiZReverseLookup) {
        FamoKeyboardPreferences.wubiZReverseLookup = $0
      }
    }
  }

  private func toggleWubiEnglishChannel() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardWubiEnglishChannel) {
        FamoKeyboardPreferences.wubiEnglishChannel = $0
      }
    }
  }

  private func toggleWubiUserDictLearning() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardWubiUserDictLearning) {
        FamoKeyboardPreferences.wubiUserDictLearning = $0
      }
    }
  }

  private func toggleAngleSymbolMenu() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardAngleSymbolMenu) {
        FamoKeyboardPreferences.angleSymbolMenu = $0
      }
    }
  }

  private func toggleSlashSymbolMenu() {
    persistAndApplyRimeConfig {
      FamoSettingsActions.toggle(state: state, keyPath: \.keyboardSlashSymbolMenu) {
        FamoKeyboardPreferences.slashSymbolMenu = $0
      }
    }
  }

  private func toggleCJKAlnumSpacing() {
    FamoSettingsActions.toggle(state: state, keyPath: \.keyboardCJKAlnumSpacing) {
      FamoKeyboardPreferences.cjkAlnumSpacing = $0
      state.keyboardCJKEnglishSpacing = $0
      state.keyboardCJKNumberSpacing = $0
    }
  }

  /// 自动配对括号 (task 07-02) — a Famo-side cached flag read live at the commit seam by the
  /// `FamoAutoPair` decision; like 中文与英文间加入空格 it must NOT trigger a Rime apply/deploy.
  private func toggleAutoPairBrackets() {
    FamoSettingsActions.toggle(state: state, keyPath: \.keyboardAutoPairBrackets) {
      FamoKeyboardPreferences.autoPairBrackets = $0
    }
  }
}
