//
//  OwlAIPage.swift
//  猫头鹰输入法 (Owltype) — AI 配置 (provider) settings page
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

// MARK: - AI 配置

/// Visible product surface for the existing default-off Smart/Cloud lanes.
/// This page only writes preferences and Keychain; it never sends a network request.
///
/// The 云端 AI（全局）on/off (`OwlCloudPreferences.isEnabled`) lives on 划词工具箱页
/// (`OwlSkillsPage.cloudCard`) instead — 划词工具箱页 is the thing that actually depends on it.
/// This page is just 供应商（配一个就行）— Responsay-style LLM-only presets + a generic
/// OpenAI-compatible add form. Keys live in the per-provider `OwlProviderKeychain`.
struct OwlAIPage: View {
  @Bindable var state: OwlSettingsState
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  // AI 供应商 (multi-provider profiles, B1). Profiles, their keys and verification markers change
  // only through the tested `OwlProviderRegistry` (write-only key field). `@State` keeps one
  // registry across re-renders, so a probe's result reaches the save that follows it.
  @State private var registry = OwlProviderRegistry()
  @State private var providers: [OwlProviderProfile] = []
  @State private var providerID = OwlLLMProviderCatalog.customID
  @State private var providerName = ""
  @State private var providerEndpoint = "https://api.openai.com/v1/chat/completions"
  @State private var providerModel = ""
  @State private var providerKeyInput = ""
  @State private var providerStatus = ""
  /// Hint for the active preset's key format; shown as the API Key field prompt.
  @State private var providerKeyHint = ""
  /// Live model ids pulled by 「拉取最新」; merged after the preset's curated models.
  @State private var fetchedModels: [String] = []
  /// Non-nil = the form is editing this saved profile instead of adding a new one. Editing keeps the
  /// profile's `id`/`secretName`, so 换模型 doesn't need the key re-pasted (see
  /// `OwlProviderRegistry.replaceEndpoint`).
  @State private var editingProfile: OwlProviderProfile?
  /// 百炼 Workspace ID / API Host。非密钥，所有 Qwen 供应商档案共用这一项。
  @State private var qwenWorkspaceInput = ""
  @State private var qwenWorkspaceKeyInput = ""
  @State private var doubaoSearchKeyInput = ""
  @State private var doubaoSearchKeyConfigured = false
  @State private var doubaoSearchKeyStatus = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        providerSectionCard
        aiCandidateSettingsCard
        voiceInputSettingsCard
        aiWritingSettingsCard
        askWebSearchCard
        sourceVerificationSearchCard
      }
      .padding(20)
    }
    .onAppear {
      // Unit-test rendering must never enumerate the user's real provider file and then ask the
      // real Keychain for every row. Besides violating test isolation, a test-signed host can
      // block indefinitely in SecItemCopyMatching. Product processes keep the live stores; UI tests use isolated files and blocked
      // personal Keychain access. Pure unit tests render the documented empty state.
      providers = OwlDefaults.isRunningUnitTests ? [] : registry.profiles
      qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost()
      doubaoSearchKeyConfigured = !OwlDefaults.isRunningUnitTests
        && OwlDoubaoSearchKeyStore.isConfigured(secrets: registry.secrets)
      if qwenWorkspaceInput.isEmpty,
         let profile = providers.first(where: {
           OwlLLMProviderCatalog.inferredProviderID(for: $0) == "qwen"
         }),
         let host = OwlQwenWorkspace.apiHost(from: profile.endpoint) {
        qwenWorkspaceInput = host
      }
    }
  }

  // MARK: - AI 候选 · 云端联想

  private var aiCandidateSettingsCard: some View {
    SettingsCard(title: "AI 候选 · 云端联想", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "AI 联想",
          subtitle: "打字停顿 120ms 后触发云端生成式「AI 联想」，首条 AI 候选固定在候选窗首页末位展示且带 AI 徽标，前排本地候选不跳变。",
          isOn: state.aiAssociationEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.aiAssociationEnabled) {
              OwlAICandidatePreferences.aiAssociationEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "英文模式 AI 候选",
          subtitle: "在英文输入模式下停顿同样提供云端 AI 候选补全与联想。",
          isOn: state.aiEnglishCandidateEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.aiEnglishCandidateEnabled) {
              OwlAICandidatePreferences.aiEnglishCandidateEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "Jev 选词",
          subtitle: "打字停顿后基于上文语义从本地候选列表中智能提权最匹配词条至首位，零词表外幻觉。",
          isOn: state.jevDiscriminativeRerankEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.jevDiscriminativeRerankEnabled) {
              OwlAICandidatePreferences.jevDiscriminativeRerankEnabled = $0
            }
          }
        )
      }
    }
  }

  // MARK: - 语音输入 · xAI Grok ASR

  private var voiceInputSettingsCard: some View {
    SettingsCard(title: "语音输入 · xAI Grok ASR", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "语音输入",
          subtitle: "按住热键说话或单击切换开启录音，实时语音胶囊波形 HUD 上屏。",
          isOn: state.voiceInputEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.voiceInputEnabled) {
              OwlVoiceSettings.isEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "语音润色",
          subtitle: "转写后调用 DeepSeek 智能去除口水词、纠偏同音词与补全标点；若超时无感降级直接上屏原文。",
          isOn: state.voicePolishEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.voicePolishEnabled) {
              OwlVoiceSettings.isPolishEnabled = $0
            }
          }
        )
      }
    }
  }

  // MARK: - AI 写作辅助 · 对话面板

  private var aiWritingSettingsCard: some View {
    SettingsCard(title: "AI 写作辅助 · 对话面板", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "AI 对话面板",
          subtitle: "打字输入 /ai 指令或按 Shift+K 呼出非激活 AI 对话面板，支持一键上屏与替换选区。",
          isOn: state.aiWritingPanelEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.aiWritingPanelEnabled) {
              OwlAIWritingSettings.isEnabled = $0
            }
          }
        )
      }
    }
  }

  // MARK: - 任意提问 · 联网搜索

  /// The search provider and answering model the 联网 copy names, from the provider capabilities.
  static var searchName: String { OwlProviderCapabilities.askSearch.searchDisplayName ?? "" }
  static var searchModel: String { OwlProviderCapabilities.askSearch.model }

  /// 任意提问 的联网搜索开关。只作用于「任意提问」：划词技能、候选、听写都不受影响。
  ///
  /// 开启后这一问会路由到一个**已配好密钥、能联网的 DeepSeek 档案**，与上面选定的默认供应商
  /// 解耦 —— 默认供应商是别家时，这一问仍能真的搜到。没有可用的 DeepSeek 档案时自动退回普通问答，
  /// 不报错。
  private var askWebSearchCard: some View {
    SettingsCard(title: "任意提问 · 联网搜索", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "联网搜索",
          subtitle: "开启后，「任意提问」会交给已配好密钥的 \(Self.searchName) 联网作答；关闭时用模型自有知识回答。只作用于任意提问，不影响划词技能与打字候选。",
          isOn: state.askWebSearchEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.askWebSearchEnabled) {
              OwlAskWebSearchSettings.isEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        Text("""
          联网先用 \(Self.searchName) 搜索接口取回网页，再由 \(Self.searchModel) 依据结果作答，需在上面添加 \(Self.searchName) 供应商。\
          回答末尾列出引用的网页。没有可用的 \(Self.searchName) 档案时，退回普通问答。

          任意提问优先减少思考等待：支持关闭思考的模型默认关闭；MiniMax M3.1 Flash 不支持关闭，\
          使用低思考强度，M3 则关闭思考。
          """)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
    }
  }

  // MARK: - 来源核验 · 豆包搜索

  /// 来源核验的检索层。Key 与上面「供应商」里的模型 Key 分开存：豆包搜索的 Key 要在火山引擎
  /// 联网搜索控制台单独建，方舟模型 Key 打不通（`700901`）。配好后由豆包搜索取回网页，
  /// 默认供应商对照判断 —— 默认配的是哪家都能核验。
  private var sourceVerificationSearchCard: some View {
    SettingsCard(title: "来源核验 · 豆包搜索", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 11) {
          Text("豆包搜索 API Key")
            .font(.system(size: 14))
            .foregroundStyle(palette.ink)
          Spacer(minLength: 8)
          Text(doubaoSearchKeyConfigured ? "已设置" : "未设置")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(palette.ink3)
        }
        HStack(spacing: 8) {
          // 保存后输入框按「只写不回显」契约清空；占位符换成已设置态，否则空框看起来像没存上。
          SecureField(
            doubaoSearchKeyConfigured ? "已设置 ●●●●●●（输入新 Key 可覆盖）"
              : "豆包搜索 API Key（写入 Keychain）",
            text: $doubaoSearchKeyInput)
            .textFieldStyle(.roundedBorder)
          smallButton("粘贴") {
            if let s = NSPasteboard.general.string(forType: .string) {
              doubaoSearchKeyInput = OwlProviderCore.call("trim", ["text": s])
            }
          }
          smallButton("保存") { saveDoubaoSearchKey() }
          if doubaoSearchKeyConfigured {
            smallButton("清除") { clearDoubaoSearchKey() }
          }
        }
        Text("""
          来源核验用豆包搜索（Global 版）与 \(Self.searchName) 搜索取回网页，配了哪个用哪个，来源只取自搜索结果。\
          配有 \(Self.searchName) 供应商时由 \(Self.searchModel) 对照判断，否则交给默认供应商；只配 \(Self.searchName) 也能核验。\
          这把 Key 与方舟模型 Key 不同：在火山引擎「联网搜索控制台 → API Key 管理 → 按量后付费」创建，\
          每月 500 次免费。\(doubaoSearchKeyStatus.isEmpty ? "" : "\n\n\(doubaoSearchKeyStatus)")
          """)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 8)
    }
  }

  private func saveDoubaoSearchKey() {
    let result = OwlSettingsActions.saveDoubaoSearchKey(
      doubaoSearchKeyInput, secrets: registry.secrets)
    doubaoSearchKeyInput = result.input
    doubaoSearchKeyStatus = result.status
    doubaoSearchKeyConfigured = OwlDoubaoSearchKeyStore.isConfigured(secrets: registry.secrets)
  }

  private func clearDoubaoSearchKey() {
    doubaoSearchKeyStatus = OwlSettingsActions.clearDoubaoSearchKey(secrets: registry.secrets)
    doubaoSearchKeyInput = ""
    doubaoSearchKeyConfigured = OwlDoubaoSearchKeyStore.isConfigured(secrets: registry.secrets)
  }

  // MARK: - 供应商（配一个就行）

  /// Provider list + Responsay-parity LLM presets + generic add form, in one card.
  private var providerSectionCard: some View {
    SettingsCard(title: "供应商（配一个就行）", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 14) {
        providerList
        providerForm
      }
    }
  }

  private var providerList: some View {
    Group {
      if providers.isEmpty {
        Text("还没有配置 AI 供应商。从下方下拉选一个 LLM 预设最快，只需粘贴 Key；或选「自定义（OpenAI 兼容）」接入任意 OpenAI 兼容端点。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          ForEach(providers) { profile in
            providerRow(profile)
            if profile.id != providers.last?.id {
              SettingsCardDivider(palette: palette)
            }
          }
        }
      }
    }
  }

  /// One provider row as a single-select **radio** option: a leading indicator (filled = the active
  /// default, hollow = tap to switch) makes "one default among many" read as one consistent control,
  /// replacing the old inverted ✓ that sat on the *non*-default rows (a bare, unlabeled checkmark that
  /// read as "this one is selected" while meaning the opposite). Tapping anywhere on the row except 🗑
  /// sets it default; the trash button stays a separate control. The active marker follows the
  /// **valid** default (`OwlProviderProfileStore.defaultProfile`), so a retired profile that still
  /// carries `isDefault` in the file is not shown as the active provider.
  @ViewBuilder
  private func providerRow(_ profile: OwlProviderProfile) -> some View {
    let isActive = registry.defaultProfile?.id == profile.id
    HStack(spacing: 10) {
      Button(action: { if !isActive { setDefaultProvider(profile) } }) {
        HStack(spacing: 10) {
          Image(systemName: isActive ? "circle.inset.filled" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(isActive ? palette.accent : palette.ink3)
          VStack(alignment: .leading, spacing: 2) {
            Text(profile.displayName)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(palette.ink)
            Text("\(profile.model.isEmpty ? "默认模型" : profile.model) · \(registry.keyState(for: profile).statusText)")
              .font(.system(size: 11.5, design: .monospaced))
              .foregroundStyle(palette.ink3)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isActive ? "\(profile.displayName)（当前默认）" : "设为默认：\(profile.displayName)")
      .accessibilityAddTraits(isActive ? .isSelected : [])

      Button(action: { beginEdit(profile) }) {
        Image(systemName: "slider.horizontal.3")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("修改模型：\(profile.displayName)")

      Button(action: { deleteProvider(profile) }) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("删除供应商")
    }
    .padding(.vertical, 8)
  }

  /// The add/edit provider form as an aligned 标签列 + 控件列 layout (方案 B): every row is
  /// 「label · control」 so the dropdowns and fields share one left edge. The preset & model
  /// dropdowns are plain `Menu`s — the old `.borderlessButton` + hand-drawn box collapsed to a
  /// bare, chevron-leading control on macOS Tahoe; the default menu style paints a real bordered
  /// pop-up, like the pickers on 键盘输入.
  private var providerForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      // 编辑已配好的一家时不给「预设」——预设的作用是带出 name/endpoint/model，这三样此刻已经有了；
      // 留着只会让人误以为必须重选一遍。改成一行「正在修改：xx」提示当前编辑对象。
      if let editingProfile {
        formRow("修改") {
          Text(editingProfile.displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.ink)
        }
      } else {
        formRow("预设") { presetControl }
      }
      if providerID == "qwen" {
        formRow("空间") { qwenWorkspaceControl }
      }
      formRow("端点") { endpointControl }
      formRow("模型") { modelControl }
      formRow("密钥") { keyControl }
      formRow("") { addFooter }
    }
  }

  private var qwenWorkspaceControl: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField("Workspace ID 或 API Host", text: qwenWorkspaceBinding)
          .textFieldStyle(.roundedBorder)
        smallButton("保存空间") { saveQwenWorkspaceSetting() }
      }
      SecureField("新 Workspace 的 API Key（换空间时必填）", text: $qwenWorkspaceKeyInput)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
      Text(qwenWorkspaceHelp)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var qwenWorkspaceBinding: Binding<String> {
    Binding(
      get: { qwenWorkspaceInput },
      set: { newValue in
        qwenWorkspaceInput = newValue
        guard providerID == "qwen" else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          providerEndpoint = OwlLLMProviderCatalog.qwenResponsesEndpoint
        } else if let endpoint = OwlQwenWorkspace.responsesEndpoint(for: trimmed) {
          providerEndpoint = endpoint.absoluteString
        }
      }
    )
  }

  private var qwenWorkspaceHelp: String {
    let trimmed = qwenWorkspaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return "留空时使用 dashscope.aliyuncs.com 通用 Responses 端点。"
    }
    guard let host = OwlQwenWorkspace.normalizedAPIHost(trimmed) else {
      return "格式无效：请填 ws-…，或 ws-….cn-beijing.maas.aliyuncs.com。"
    }
    return "API Host：\(host)"
  }

  /// One 「label · control」 row: a fixed-width right-aligned label + the control filling the rest,
  /// so every control lines up on a single left edge.
  private func formRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.system(size: 13))
        .foregroundStyle(palette.ink3)
        .frame(width: 40, alignment: .trailing)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// 预设下拉：一档填一家（name/endpoint/model 自动带出，用户只粘 Key）+ 自定义。默认 Menu 样式，
  /// 在 Tahoe 上渲染成带边框的弹出按钮。
  private var presetControl: some View {
    Menu {
      ForEach(OwlLLMProviderCatalog.presets) { preset in
        Button(preset.displayName) { fillPreset(preset) }
      }
      Divider()
      Button("自定义（OpenAI 兼容）") { fillCustomPreset() }
    } label: {
      Text(providerName.isEmpty ? "选择 LLM 预设…" : providerName)
    }
    .fixedSize()
    .accessibilityLabel("选择供应商预设")
  }

  /// 端点：预设自动匹配、只读展示；自定义时才可编辑。
  @ViewBuilder private var endpointControl: some View {
    if isCustomProvider {
      TextField("https 端点", text: $providerEndpoint)
        .textFieldStyle(.roundedBorder)
    } else if let host = URL(string: providerEndpoint)?.host {
      Text(host)
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundStyle(palette.ink3)
    } else {
      Text("选预设后自动填充")
        .font(.system(size: 12.5))
        .foregroundStyle(palette.ink3)
    }
  }

  /// 模型：可自由输入，或从 curated + 拉取结果里选（右侧下拉），或「拉取最新」拉 /models。
  private var modelControl: some View {
    HStack(spacing: 8) {
      TextField("模型，如 gpt-4o / deepseek-chat", text: $providerModel)
        .textFieldStyle(.roundedBorder)
      if !availableModels.isEmpty {
        Menu {
          ForEach(availableModels, id: \.self) { id in
            Button(id) { providerModel = id }
          }
        } label: {
          Text("选择")
        }
        .fixedSize()
        .accessibilityLabel("选择模型")
      }
      smallButton("拉取最新") { fetchModels() }
      // 与「拉取最新」并排但管两件事：那个只证明主机通、Key 有效，**完全不检查你选的型号**。
      // 详见 `OwlProviderConnectivityCheck`。
      smallButton("验证连通性") { checkConnectivity() }
    }
  }

  /// API Key：写入 per-provider Keychain（Owltype 自己写 → ACL 正确）。
  private var keyControl: some View {
    HStack(spacing: 8) {
      SecureField(secureFieldPrompt, text: $providerKeyInput)
        .textFieldStyle(.roundedBorder)
      smallButton("粘贴") { pasteProviderKey() }
    }
  }

  /// 「添加并设为默认」/ 编辑态的「保存修改」+「取消」+ 状态回显。
  private var addFooter: some View {
    HStack(spacing: 8) {
      if editingProfile == nil {
        smallButton("添加并设为默认") { addProvider() }
      } else {
        smallButton("保存修改") { saveEdit() }
        smallButton("取消") { cancelEdit() }
      }
      if !providerStatus.isEmpty {
        Text(providerStatus)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
      }
    }
  }

  private var isCustomProvider: Bool { providerID == OwlLLMProviderCatalog.customID }

  /// The preset's built-in model(s) — the always-available fallback shown before / without a fetch.
  ///
  /// 编辑态下把该供应商**当前用的**模型排在最前：预设里写死的那个型号会过时（供应商发新版比我们发版
  /// 快），当前值不在列表里就会给人「只能选回旧型号」的错觉。
  private var curatedModels: [String] {
    OwlProviderCore.call("curatedModels", ["providerID": providerID, "current": editingProfile?.model ?? ""])
  }

  private var availableModels: [String] {
    OwlProviderModelList.merged(curated: curatedModels, fetched: fetchedModels)
  }

  /// The API Key field prompt — the active preset's key-format hint, or a generic line.
  /// 编辑态改口径：留空不再是「稍后再填」，而是「保持已存的 Key 不变」。
  private var secureFieldPrompt: String {
    let hint = providerKeyHint.isEmpty ? "" : "\(providerKeyHint)，"
    return editingProfile == nil
      ? "API Key（\(hint)写入 Keychain，可留空稍后再填）"
      : "API Key（\(hint)留空＝保持现有 Key 不变）"
  }

  /// Prefill the add form from a one-tap preset; the user only pastes the key. The model field
  /// starts at the preset's default; `curatedModels` lists the alternatives in 选择模型.
  private func fillPreset(_ preset: OwlLLMProviderPreset) {
    providerID = preset.id
    providerName = preset.displayName
    if preset.id == "qwen" {
      providerEndpoint = resolvedQwenEndpoint()?.absoluteString ?? preset.endpoint
    } else {
      providerEndpoint = preset.endpoint
    }
    providerModel = preset.model
    providerKeyHint = preset.keyHint
    fetchedModels = []
    providerStatus = ""
  }

  /// Reset the add form to a blank generic OpenAI-compatible entry.
  private func fillCustomPreset() {
    providerID = OwlLLMProviderCatalog.customID
    providerName = "自定义（OpenAI 兼容）"
    providerEndpoint = "https://api.openai.com/v1/chat/completions"
    providerModel = ""
    providerKeyHint = ""
    fetchedModels = []
    providerStatus = ""
  }

  private func addProvider() {
    guard let effectiveEndpoint = prepareProviderEndpoint() else { return }
    // Custom entries have no preset name — derive one from the endpoint host so rows stay distinct.
    let name = isCustomProvider
      ? "自定义 · \(URL(string: providerEndpoint)?.host ?? "OpenAI 兼容")"
      : providerName
    // 每家一条：registry 在同一次写入里换掉同一供应商的旧配置；失败时旧配置与其 Key 原样保留。
    let form = OwlProviderRegistry.Form(
      providerID: providerID,
      displayName: name,
      endpoint: effectiveEndpoint,
      model: providerModel,
      qwenWorkspace: providerID == "qwen" ? qwenWorkspaceInput : nil)
    let change = registry.upsert(form, key: providerKeyInput)
    providers = change.profiles
    providerStatus = change.outcome.statusText
    guard case .added = change.outcome else { return }
    if providerID == "qwen" { qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost() }
    fillCustomPreset()
    providerName = ""       // back to the empty 「选择 LLM 预设…」 prompt
    providerKeyInput = ""
  }

  /// 「拉取最新」: GET the provider's `/models` with the typed endpoint + key, merge into the model
  /// dropdown. Curated preset models remain the fallback if the fetch fails or returns nothing.
  private func fetchModels() {
    guard let effectiveEndpoint = prepareProviderEndpoint(),
          let endpoint = URL(string: effectiveEndpoint),
          OwlProviderRegistry.isHTTPS(endpoint) else {
      providerStatus = "端点必须是 https"; return
    }
    let probedProfile = editingProfile
    guard let key = probeKey(missing: "请先填入 API Key 再拉取", endpoint: endpoint) else { return }
    let authStyle = OwlProviderAuthHeaderStyle.bearer
    providerStatus = "拉取模型中…"
    Task {
      do {
        let models = try await OwlProviderModelList.fetch(endpoint: endpoint, apiKey: key, authStyle: authStyle)
        await MainActor.run {
          fetchedModels = models
          if providerModel.isEmpty { providerModel = availableModels.first ?? "" }
          providerStatus = models.isEmpty ? "已连接，但未解析到模型" : "拉到 \(models.count) 个模型，点右侧下拉选择"
          // 这一次 `/models` 是拿这把 Key 真的调通的 —— 记下来，行状态才敢写「已验证」。
          // 新增或换 Key 时 profile 还没存这把 Key，由 registry 在保存同一组端点 + Key 时补标。
          registry.probeSucceeded(endpoint: endpoint, key: key, editing: probedProfile)
          providers = registry.profiles
        }
      } catch {
        await MainActor.run { providerStatus = "拉取失败，请检查端点与 Key" }
      }
    }
  }

  /// 「验证连通性」：拿表单里这组 端点 + 模型 + Key 真发一次最小请求。
  ///
  /// 与 `fetchModels` 共用「Key 字段为空且端点同源才读取 Keychain」的规则 —— 已配好的一家 Key 字段永远是
  /// 空的（只写不回显），不回落就等于「已存在的供应商永远验不了」。
  ///
  /// 成功也要落一次「已验证」：这是拿这把 Key 真的调通了，比 `/models` 更有说服力。
  private func checkConnectivity() {
    guard let effectiveEndpoint = prepareProviderEndpoint(),
          let endpoint = URL(string: effectiveEndpoint),
          OwlProviderRegistry.isHTTPS(endpoint) else {
      providerStatus = "端点必须是 https"; return
    }
    let model = OwlProviderCore.call("trim", ["text": providerModel]) as String
    guard !model.isEmpty else { providerStatus = "请先填模型再验证"; return }
    let probedProfile = editingProfile
    guard let key = probeKey(missing: "请先填入 API Key 再验证", endpoint: endpoint) else { return }
    let authStyle = OwlProviderAuthHeaderStyle.bearer

    providerStatus = "验证中…（\(model)）"
    Task {
      let outcome = await OwlProviderConnectivityCheck.run(
        endpoint: endpoint, providerID: providerID, model: model,
        apiKey: key, authStyle: authStyle)
      await MainActor.run {
        providerStatus = outcome.statusText
        guard outcome.isOK else { return }
        // 与 `fetchModels` 同一条。
        registry.probeSucceeded(endpoint: endpoint, key: key, editing: probedProfile)
        providers = registry.profiles
      }
    }
  }

  /// The key 「拉取最新」 and 「验证连通性」 send, or nil after showing why there is none.
  private func probeKey(missing: String, endpoint: URL) -> String? {
    switch registry.probeKey(editing: editingProfile, endpoint: endpoint, typedKey: providerKeyInput) {
    case let .key(key):
      return key
    case .missing:
      providerStatus = missing
    case .needsReplacementKey:
      providerStatus = OwlProviderRegistry.ProbeKey.replacementKeyPrompt
    }
    return nil
  }

  private func saveQwenWorkspaceSetting() {
    let change = registry.applyQwenWorkspace(qwenWorkspaceInput, key: qwenWorkspaceKeyInput)
    providers = change.profiles
    editingProfile = OwlSettingsActions.editingProfileAfterWorkspaceSave(
      editingProfile, profiles: change.profiles)
    providerStatus = change.outcome.statusText
    guard case .saved = change.outcome else { return }
    qwenWorkspaceKeyInput = ""
    qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost()
    if providerID == "qwen" {
      providerEndpoint = OwlQwenWorkspaceSettings.responsesEndpoint().absoluteString
    }
  }

  private func resolvedQwenEndpoint() -> URL? {
    let value: String? = OwlProviderHost().required("resolvedWorkspace", ["input": qwenWorkspaceInput])
    return value.flatMap(URL.init(string:))
  }

  /// Qwen 的端点由 Workspace 输入生成；其他供应商仍使用原端点字段。
  private func prepareProviderEndpoint() -> String? {
    guard providerID == "qwen" else { return providerEndpoint }
    guard let endpoint = resolvedQwenEndpoint() else {
      providerStatus = "Workspace ID / API Host 格式无效。"
      return nil
    }
    providerEndpoint = endpoint.absoluteString
    return providerEndpoint
  }

  /// Load a saved provider into the form so its model / endpoint can be changed in place.
  private func beginEdit(_ profile: OwlProviderProfile) {
    editingProfile = profile
    providerID = OwlLLMProviderCatalog.formProviderID(for: profile)
    providerName = profile.displayName
    providerEndpoint = profile.endpoint.absoluteString
    if providerID == "qwen" {
      qwenWorkspaceInput = OwlQwenWorkspace.apiHost(from: profile.endpoint)
        ?? OwlQwenWorkspaceSettings.apiHost()
      providerEndpoint = resolvedQwenEndpoint()?.absoluteString ?? profile.endpoint.absoluteString
    }
    providerModel = profile.model
    providerKeyHint = OwlLLMProviderCatalog.preset(id: providerID)?.keyHint ?? ""
    providerKeyInput = ""
    fetchedModels = []
    providerStatus = "点「拉取最新」看该供应商当前有哪些模型，选好后点「保存修改」。"
  }

  private func cancelEdit() {
    editingProfile = nil
    fillCustomPreset()
    providerName = ""
    providerKeyInput = ""
    providerStatus = ""
  }

  /// Save the edited profile in place — keeps its Keychain entry unless a new key was typed.
  private func saveEdit() {
    guard let profile = editingProfile else { return }
    guard let effectiveEndpoint = prepareProviderEndpoint() else { return }
    let change = registry.replaceEndpoint(
      of: profile,
      endpoint: effectiveEndpoint,
      model: providerModel,
      key: providerKeyInput,
      qwenWorkspace: providerID == "qwen" ? qwenWorkspaceInput : nil
    )
    providers = change.profiles
    providerStatus = change.outcome.statusText
    if case .saved = change.outcome {
      if providerID == "qwen" { qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost() }
      editingProfile = nil
      fillCustomPreset()
      providerName = ""
      providerKeyInput = ""
      providerStatus = change.outcome.statusText
    } else {
      editingProfile = OwlSettingsActions.providerProfileForRetry(profile, profiles: change.profiles)
    }
  }

  /// 一键从剪贴板填入 API Key（比 ⌘V / 右键更显眼，绕开菜单快捷键问题）。仍走现有的「添加并设为默认」持久化。
  private func pasteProviderKey() {
    if let s = NSPasteboard.general.string(forType: .string) {
      providerKeyInput = OwlProviderCore.call("trim", ["text": s])
    }
  }

  private func setDefaultProvider(_ profile: OwlProviderProfile) {
    let change = registry.setDefault(profile)
    providers = change.profiles
    providerStatus = change.outcome.statusText
  }

  private func deleteProvider(_ profile: OwlProviderProfile) {
    let change = registry.delete(profile)
    providers = change.profiles
    providerStatus = change.outcome.statusText
    // 删掉的正是正在编辑的那条 → 表单退回新增态，否则「保存修改」会写回一条已删除的 profile。
    if editingProfile?.id == profile.id {
      editingProfile = nil
      fillCustomPreset()
      providerName = ""
      providerKeyInput = ""
    }
  }

  private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.accent) }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}
