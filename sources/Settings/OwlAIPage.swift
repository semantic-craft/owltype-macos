//
//  OwlAIPage.swift
//  法墨输入法 (Owltype) — AI 配置 (provider) settings page
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

// MARK: - AI 配置

/// Visible product surface for the existing default-off Smart/Cloud lanes.
/// Network requests run only when the user asks to test a connection or fetch models.
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
  @State private var didLoadProviders = false
  @State private var defaultProviderID: String?
  @State private var providerKeyStates: [String: OwlProviderRegistry.KeyState] = [:]
  @State private var keyStatusRevision = UUID()
  @State private var loadedKeyStatusRevision: UUID?
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
  @State private var voiceASRProviderID = OwlVoiceSettings.asrProviderID
  @State private var voiceEndpointInput = OwlVoiceSettings.asrEndpoint
  @State private var voiceModelInput = OwlVoiceSettings.asrModel
  @State private var voiceFetchedModels: [String] = []
  @State private var asrKeyInput = ""
  @State private var asrKeyConfigured = false
  @State private var voiceASRHasDedicatedKey = false
  @State private var voiceASRHasSharedKey = false
  @State private var voiceASRStatus = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        providerSectionCard
        voiceInputSettingsCard
        aiCapabilitiesAndSearchCard
      }
      .padding(20)
    }
    .task {
      let initial = await Task.detached(priority: .userInitiated) {
        let profiles = OwlDefaults.isRunningUnitTests ? [] : OwlProviderProfileStore.shared.profiles()
        return (profiles, OwlQwenWorkspaceSettings.apiHost())
      }.value
      guard !Task.isCancelled else { return }
      (providers, qwenWorkspaceInput) = initial
      if qwenWorkspaceInput.isEmpty,
         let profile = providers.first(where: { OwlLLMProviderCatalog.inferredProviderID(for: $0) == "qwen" }),
         let host = OwlQwenWorkspace.apiHost(from: profile.endpoint) {
        qwenWorkspaceInput = host
      }
      didLoadProviders = true
      refreshVoiceASRKeyState()
    }
    .onChange(of: providers) { _, _ in refreshVoiceASRKeyState() }
    .task(id: keyStatusRevision) { await loadKeyStatus() }
  }

  private func refreshVoiceASRKeyState() {
    keyStatusRevision = UUID()
  }

  private func loadKeyStatus() async {
    guard didLoadProviders else { return }
    let revision = keyStatusRevision
    let profiles = providers
    let providerID = voiceASRProviderID
    let requiresKey = activeVoiceASRPreset.requiresAPIKey
    let snapshot = await Task.detached(priority: .utility) {
      let reader = OwlProviderRegistry()
      let defaultID = reader.defaultProfile?.id
      guard !OwlTestStorage.isEnabled else {
        return (defaultID, [String: OwlProviderRegistry.KeyState](), false, false)
      }
      let states = Dictionary(
        profiles.map { ($0.id, reader.keyState(for: $0)) },
        uniquingKeysWith: { first, _ in first }
      )
      guard requiresKey else { return (defaultID, states, false, false) }
      let dedicated = (try? OwlVoiceSettings.readDedicatedASRAPIKey(
        forProviderID: providerID, secrets: reader.secrets))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let shared = OwlVoiceSettings.readConfiguredProfileKey(
        forProviderID: providerID, store: reader.store, secrets: reader.secrets) ?? ""
      return (defaultID, states, !dedicated.isEmpty, !shared.isEmpty)
    }.value
    guard !Task.isCancelled, revision == keyStatusRevision else { return }
    (defaultProviderID, providerKeyStates, voiceASRHasDedicatedKey, voiceASRHasSharedKey) = snapshot
    asrKeyConfigured = voiceASRHasDedicatedKey || voiceASRHasSharedKey
    loadedKeyStatusRevision = revision
  }

  private var voiceASRKeyStatusText: String {
    guard loadedKeyStatusRevision == keyStatusRevision else { return "正在读取密钥状态…" }
    if voiceASRHasDedicatedKey {
      return "已单独设置"
    }
    if voiceASRHasSharedKey {
      return "已复用供应商密钥"
    }
    return "未设置"
  }

  // MARK: - 语音输入 · 云端语音识别

  private var activeVoiceASRPreset: OwlVoiceASRPreset {
    OwlVoiceASRCatalog.preset(id: voiceASRProviderID)
  }

  private var voiceAvailableModels: [String] {
    let current = OwlProviderCore.call("trim", ["text": voiceModelInput]) as String
    let seed = current.isEmpty || activeVoiceASRPreset.curatedModels.contains(current)
      ? activeVoiceASRPreset.curatedModels
      : [current] + activeVoiceASRPreset.curatedModels
    return OwlProviderModelList.merged(curated: seed, fetched: voiceFetchedModels)
  }

  private var voiceInputSettingsCard: some View {
    SettingsCard(title: "语音输入 · 云端语音识别", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "语音输入",
          subtitle: "按住右 Option (⌥) 说话，松手即上屏；按住期间点空格锁定免提，按 Esc 取消，按其他键自动退让组合键。",
          isOn: state.voiceInputEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.voiceInputEnabled) { enabled in
              OwlVoiceSettings.isEnabled = enabled
              if enabled, !OwlDefaults.isRunningUnitTests, OwlMicrophonePermission.status == .notDetermined {
                Task { _ = await OwlMicrophonePermission.request() }
              }
            }
          }
        )
        SettingsCardDivider(palette: palette)
        voiceASRConfigRows
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
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

  private var voiceASRConfigRows: some View {
    VStack(alignment: .leading, spacing: 10) {
      formRow("预设") {
        HStack(spacing: 8) {
          Menu {
            ForEach(OwlVoiceASRCatalog.presets) { preset in
              Button(preset.displayName) { selectVoiceASRPreset(preset) }
            }
          } label: {
            Text(activeVoiceASRPreset.displayName)
          }
          .fixedSize()
          .accessibilityLabel("选择语音识别预设")
          Spacer(minLength: 8)
          Text(voiceASRKeyStatusText)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(palette.ink3)
        }
      }
      voiceASRAPIKeyRows
    }
  }

  @ViewBuilder
  private var voiceASRAPIKeyRows: some View {
    formRow("端点") {
      TextField("ASR 端点，如 https://api.openai.com/v1/audio/transcriptions", text: $voiceEndpointInput)
        .textFieldStyle(.roundedBorder)
    }
    formRow("模型") {
      HStack(spacing: 8) {
        TextField("ASR 模型，如 gpt-transcribe", text: $voiceModelInput)
          .textFieldStyle(.roundedBorder)
        Menu {
          ForEach(voiceAvailableModels, id: \.self) { id in
            Button(id) {
              voiceModelInput = id
              OwlVoiceSettings.asrModel = id
            }
          }
        } label: {
          Text("选择")
        }
        .fixedSize()
        .accessibilityLabel("选择语音识别模型")
        smallButton("拉取模型") { fetchVoiceModels() }
      }
    }
    formRow("密钥") {
      HStack(spacing: 8) {
        SecureField(
          asrKeyConfigured ? "已设置 ●●●●●●（输入新 Key 可覆盖）"
            : "ASR API Key（写入 Keychain，同名供应商自动复用）",
          text: $asrKeyInput)
          .textFieldStyle(.roundedBorder)
        smallButton("粘贴") {
          if let str = NSPasteboard.general.string(forType: .string) {
            asrKeyInput = OwlProviderCore.call("trim", ["text": str])
          }
        }
        smallButton("保存") { saveVoiceASRSettings() }
          .disabled(activeVoiceASRPreset.requiresAPIKey && loadedKeyStatusRevision != keyStatusRevision)
        if voiceASRHasDedicatedKey {
          smallButton("清除") { clearVoiceASRAPIKey() }
        }
      }
    }
    formRow("") {
      Text("""
        格式 \(activeVoiceASRPreset.keyHint) · 存系统钥匙串。上方已配置同名供应商时自动复用密钥；\
        开启下方「语音润色」时自动复用已配置的 DeepSeek 供应商密钥。\(voiceASRStatus.isEmpty ? "" : "\n\n\(voiceASRStatus)")
        """)
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func selectVoiceASRPreset(_ preset: OwlVoiceASRPreset) {
    voiceASRProviderID = preset.id
    voiceASRHasDedicatedKey = false
    voiceASRHasSharedKey = false
    asrKeyConfigured = false
    voiceEndpointInput = preset.endpoint
    voiceModelInput = preset.defaultModel
    voiceFetchedModels = []
    voiceASRStatus = ""
    OwlVoiceSettings.asrProviderID = preset.id
    OwlVoiceSettings.asrEndpoint = preset.endpoint
    OwlVoiceSettings.asrModel = preset.defaultModel
    refreshVoiceASRKeyState()
  }

  private func saveVoiceASRSettings() {
    let result = OwlSettingsActions.saveVoiceASRSettings(
      providerID: voiceASRProviderID,
      endpoint: voiceEndpointInput,
      model: voiceModelInput,
      apiKey: asrKeyInput,
      isKeyAlreadyConfigured: asrKeyConfigured
    )
    asrKeyInput = result.input
    voiceEndpointInput = result.endpoint
    voiceModelInput = result.model
    voiceASRStatus = result.status
    refreshVoiceASRKeyState()
  }

  private func clearVoiceASRAPIKey() {
    voiceASRStatus = OwlSettingsActions.clearVoiceASRAPIKey(providerID: voiceASRProviderID)
    asrKeyInput = ""
    refreshVoiceASRKeyState()
  }

  private func fetchVoiceModels() {
    let trimmedEndpoint = OwlProviderCore.call("trim", ["text": voiceEndpointInput]) as String
    let effectiveEndpoint = trimmedEndpoint.isEmpty ? activeVoiceASRPreset.endpoint : trimmedEndpoint
    guard let endpoint = URL(string: effectiveEndpoint), OwlProviderRegistry.isHTTPS(endpoint) else {
      voiceASRStatus = "端点必须是 https。"
      return
    }
    let typedKey = OwlProviderCore.call("trim", ["text": asrKeyInput]) as String
    let storedKey = (try? OwlVoiceSettings.readASRAPIKey(
      forProviderID: voiceASRProviderID, store: registry.store, secrets: registry.secrets))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let effectiveKey = !typedKey.isEmpty ? typedKey : storedKey
    guard !effectiveKey.isEmpty else {
      voiceASRStatus = "请先填入 \(activeVoiceASRPreset.keyLabel) 再拉取"
      return
    }
    voiceASRStatus = "拉取模型中…"
    Task {
      do {
        let models = try await OwlProviderModelList.fetch(
          endpoint: endpoint, apiKey: effectiveKey, authStyle: .bearer)
        await MainActor.run {
          voiceFetchedModels = models
          if voiceModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceModelInput = voiceAvailableModels.first ?? activeVoiceASRPreset.defaultModel
          }
          voiceASRStatus = models.isEmpty
            ? "已连接，但未解析到模型"
            : "拉到 \(models.count) 个模型，点「选择」切换"
        }
      } catch {
        await MainActor.run {
          voiceASRStatus = "拉取失败，请检查端点与 Key"
        }
      }
    }
  }

  // MARK: - AI 能力与联网搜索

  /// The search provider and answering model the 联网 copy names, from the provider capabilities.
  static var searchName: String { OwlProviderCapabilities.askSearch.searchDisplayName ?? "" }
  static var searchModel: String { OwlProviderCapabilities.askSearch.model }

  private var aiCapabilitiesAndSearchCard: some View {
    SettingsCard(title: "AI 能力与联网搜索", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
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
        SettingsCardDivider(palette: palette)
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
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "联网搜索",
          subtitle: "供「任意提问」和「来源核验」使用，需配置 \(Self.searchName) 密钥。\(Self.searchModel) 作答并附来源；无可用档案时，任意提问退回普通问答。",
          isOn: state.askWebSearchEnabled,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.askWebSearchEnabled) {
              OwlAskWebSearchSettings.isEnabled = $0
            }
          }
        )

      }
    }
  }

  // MARK: - 模型供应商（配一个就行）

  /// Provider list + Responsay-parity LLM presets + generic add form, in one card.
  private var providerSectionCard: some View {
    SettingsCard(title: "模型供应商（配一个就行）", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 14) {
        providerList
        providerForm
      }
      .disabled(!didLoadProviders)
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
    let isActive = defaultProviderID == profile.id
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
            Text("\(profile.model.isEmpty ? "默认模型" : profile.model) · \(OwlLLMProviderCatalog.capabilitySummary(for: profile)) · \(providerKeyStates[profile.id]?.statusText ?? "密钥状态待确认")")
              .font(.system(size: 11.5, design: .monospaced))
              .foregroundStyle(palette.ink3)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.owlPlain)
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
    refreshVoiceASRKeyState()
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
          refreshVoiceASRKeyState()
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
        refreshVoiceASRKeyState()
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
    refreshVoiceASRKeyState()
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
    refreshVoiceASRKeyState()
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
    .buttonStyle(.owlPlain)
    .accessibilityLabel(title)
  }
}
