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

  // AI 供应商 (multi-provider profiles, B1). The store + secret store default to the live homes;
  // both are reachable only through the tested `OwlSettingsActions` funcs (write-only key field).
  private let providerStore = OwlProviderProfileStore.shared
  private let providerSecrets: OwlSecretStoring = OwlProviderKeychain()
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
  /// `OwlSettingsActions.updateProviderProfile`).
  @State private var editingProfile: OwlProviderProfile?
  /// 百炼 Workspace ID / API Host。非密钥，所有 Qwen 供应商档案共用这一项。
  @State private var qwenWorkspaceInput = ""
  @State private var qwenWorkspaceKeyInput = ""
  /// 新增流程里「拉取最新」已经用这把 Key 调通过：profile 落库后补标验证（见 `addProvider`）。
  @State private var pendingKeyVerified = false

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        providerSectionCard
        askWebSearchCard
      }
      .padding(20)
    }
    .onAppear {
      // Unit-test rendering must never enumerate the user's real provider file and then ask the
      // real Keychain for every row. Besides violating test isolation, a test-signed host can
      // block indefinitely in SecItemCopyMatching. Product and UI-test processes keep the live
      // stores; pure unit tests render the documented empty state.
      providers = OwlDefaults.isRunningUnitTests ? [] : providerStore.profiles()
      qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost()
      if qwenWorkspaceInput.isEmpty,
         let profile = providers.first(where: {
           OwlLLMProviderCatalog.inferredProviderID(for: $0) == "qwen"
         }),
         let host = OwlQwenWorkspace.apiHost(from: profile.endpoint) {
        qwenWorkspaceInput = host
      }
    }
  }

  // MARK: - 任意提问 · 联网搜索

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
          subtitle: "开启后，「任意提问」会交给已配好密钥的 DeepSeek 联网作答；关闭时用模型自有知识回答。只作用于任意提问，不影响划词技能与打字候选。",
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
          联网由 DeepSeek 内置搜索完成，需在上面添加 DeepSeek 供应商并选用 deepseek-v4-flash（Pro 不支持联网）。\
          回答窗口会标注搜索来源。没有可用的 DeepSeek 档案时，退回普通问答。

          任意提问优先减少思考等待：支持关闭思考的模型默认关闭；MiniMax M3.1 Flash 不支持关闭，\
          使用低思考强度，M3 则关闭思考。DeepSeek 内置联网需保留思考。
          """)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
    }
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
    let isActive = providerStore.defaultProfile?.id == profile.id
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
            Text("\(profile.model.isEmpty ? "默认模型" : profile.model) · \(OwlSettingsActions.providerProfileKeyStatus(profile, secrets: providerSecrets)) · \(OwlLLMProviderCatalog.sourceSupport(for: profile).displayName)")
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
    let preset: [String]
    switch providerID {
    case "deepseek":
      preset = [OwlCloudPreferences.defaultDeepSeekModel, OwlCloudPreferences.reasonerDeepSeekModel]
    case "qwen":
      // 默认 3.8 Flash，另提供 Plus/Max；型号清单由 catalog 统一维护。
      preset = OwlLLMProviderCatalog.qwenModels
    case "minimax":
      preset = OwlLLMProviderCatalog.minimaxModels
    case OwlLLMProviderCatalog.customID:
      preset = []
    default:
      preset = OwlLLMProviderCatalog.preset(id: providerID).map { [$0.model] } ?? []
    }
    guard let current = editingProfile?.model, !current.isEmpty else { return preset }
    return [current] + preset.filter { $0 != current }
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

  /// Prefill the add form from a one-tap preset; the user only pastes the key. DeepSeek keeps the
  /// Chat·V4 Flash / Reasoner·V4 Pro quick model toggle; the others show a plain model field.
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
    // 每家一条：先移除同一供应商的旧配置（含其 Keychain 键），再添加。
    let newKey = dedupKey(providerID: providerID, endpointHost: URL(string: effectiveEndpoint)?.host)
    for existing in providers where dedupKey(
      providerID: OwlLLMProviderCatalog.inferredProviderID(for: existing),
      endpointHost: existing.endpoint.host) == newKey {
      _ = OwlSettingsActions.deleteProviderProfile(existing, store: providerStore, secrets: providerSecrets)
    }
    // Custom entries have no preset name — derive one from the endpoint host so rows stay distinct.
    let name = isCustomProvider
      ? "自定义 · \(URL(string: providerEndpoint)?.host ?? "OpenAI 兼容")"
      : providerName
    let result = OwlSettingsActions.addProviderProfile(
      displayName: name,
      endpoint: effectiveEndpoint,
      model: providerModel,
      apiKey: providerKeyInput,
      makeDefault: true,
      store: providerStore,
      secrets: providerSecrets,
      providerID: providerID
    )
    providers = result.profiles
    providerStatus = result.status
    if result.status.hasPrefix("已添加") {
      persistQwenWorkspaceIfNeeded()
      // 「拉取最新」验证过的正是刚存进去的这把 Key —— 落库后补标，行状态才写「已验证」。
      if pendingKeyVerified,
         let added = result.profiles.first(where: {
           OwlLLMProviderCatalog.inferredProviderID(for: $0) == providerID
         }) {
        OwlSettingsActions.markProviderProfileKeyVerified(added)
        providers = providerStore.profiles()
      }
      pendingKeyVerified = false
      fillCustomPreset()
      providerName = ""       // back to the empty 「选择 LLM 预设…」 prompt
      providerKeyInput = ""
    }
  }

  /// One-per-vendor key: a known preset dedupes by its provider id; custom / unknown by endpoint host.
  private func dedupKey(providerID: String, endpointHost: String?) -> String {
    providerID.isEmpty || providerID == OwlLLMProviderCatalog.customID
      ? "host:\(endpointHost ?? "")"
      : "id:\(providerID)"
  }

  /// 「拉取最新」: GET the provider's `/models` with the typed endpoint + key, merge into the model
  /// dropdown. Curated preset models remain the fallback if the fetch fails or returns nothing.
  private func fetchModels() {
    guard let effectiveEndpoint = prepareProviderEndpoint(),
          let endpoint = URL(string: effectiveEndpoint),
          OwlSettingsActions.isHTTPSEndpoint(endpoint) else {
      providerStatus = "端点必须是 https"; return
    }
    let probe = OwlSettingsActions.providerProbeKey(
      editing: editingProfile, endpoint: endpoint, typedKey: providerKeyInput,
      store: providerStore, secrets: providerSecrets)
    if let status = probe.status { providerStatus = status; return }
    guard let key = probe.key else { providerStatus = "请先填入 API Key 再拉取"; return }
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
          // 新增流程里 profile 还不存在，先记 flag，`addProvider` 落库后再补标。
          if let editingProfile {
            OwlSettingsActions.markProviderProfileKeyVerified(editingProfile)
            providers = providerStore.profiles()
          } else {
            pendingKeyVerified = true
          }
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
          OwlSettingsActions.isHTTPSEndpoint(endpoint) else {
      providerStatus = "端点必须是 https"; return
    }
    let model = providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { providerStatus = "请先填模型再验证"; return }
    let probe = OwlSettingsActions.providerProbeKey(
      editing: editingProfile, endpoint: endpoint, typedKey: providerKeyInput,
      store: providerStore, secrets: providerSecrets)
    if let status = probe.status { providerStatus = status; return }
    guard let key = probe.key else { providerStatus = "请先填入 API Key 再验证"; return }
    let authStyle = OwlProviderAuthHeaderStyle.bearer

    providerStatus = "验证中…（\(model)）"
    Task {
      let outcome = await OwlProviderConnectivityCheck.run(
        endpoint: endpoint, providerID: providerID, model: model,
        apiKey: key, authStyle: authStyle)
      await MainActor.run {
        providerStatus = outcome.statusText
        guard outcome.isOK else { return }
        // 与 `fetchModels` 同一条：新增流程里 profile 还不存在，先记 flag，落库后再补标。
        if let editingProfile {
          OwlSettingsActions.markProviderProfileKeyVerified(editingProfile)
          providers = providerStore.profiles()
        } else {
          pendingKeyVerified = true
        }
      }
    }
  }

  private func saveQwenWorkspaceSetting() {
    let result = OwlSettingsActions.saveQwenWorkspace(
      qwenWorkspaceInput, apiKey: qwenWorkspaceKeyInput, store: providerStore, secrets: providerSecrets)
    providers = result.profiles
    providerStatus = result.status
    guard result.saved else { return }
    qwenWorkspaceKeyInput = ""
    qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost()
    if providerID == "qwen" {
      providerEndpoint = OwlQwenWorkspaceSettings.responsesEndpoint().absoluteString
    }
  }

  private func resolvedQwenEndpoint() -> URL? {
    let trimmed = qwenWorkspaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
      ? URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)
      : OwlQwenWorkspace.responsesEndpoint(for: trimmed)
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

  private func persistQwenWorkspaceIfNeeded() {
    guard providerID == "qwen" else { return }
    _ = OwlQwenWorkspaceSettings.save(qwenWorkspaceInput)
    qwenWorkspaceInput = OwlQwenWorkspaceSettings.apiHost()
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
    let result = OwlSettingsActions.updateProviderProfile(
      profile,
      endpoint: effectiveEndpoint,
      model: providerModel,
      apiKey: providerKeyInput,
      store: providerStore,
      secrets: providerSecrets
    )
    providers = result.profiles
    providerStatus = result.status
    if result.status.hasPrefix("已保存") {
      persistQwenWorkspaceIfNeeded()
      editingProfile = nil
      fillCustomPreset()
      providerName = ""
      providerKeyInput = ""
      providerStatus = result.status
    } else {
      editingProfile = OwlSettingsActions.providerProfileForRetry(profile, profiles: result.profiles)
    }
  }

  /// 一键从剪贴板填入 API Key（比 ⌘V / 右键更显眼，绕开菜单快捷键问题）。仍走现有的「添加并设为默认」持久化。
  private func pasteProviderKey() {
    if let s = NSPasteboard.general.string(forType: .string) {
      providerKeyInput = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func setDefaultProvider(_ profile: OwlProviderProfile) {
    let result = OwlSettingsActions.setDefaultProviderProfile(profile, store: providerStore)
    providers = result.profiles
    providerStatus = result.status
  }

  private func deleteProvider(_ profile: OwlProviderProfile) {
    let result = OwlSettingsActions.deleteProviderProfile(profile, store: providerStore, secrets: providerSecrets)
    providers = result.profiles
    providerStatus = result.status
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
