//
//  FamoAIPage.swift
//  法墨输入法 (Famo) — AI 配置 (provider) settings page
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
/// The 云端 AI（全局）on/off (`FamoCloudPreferences.isEnabled`) lives on 技能平台
/// (`FamoSkillsPage.cloudCard`) instead — 技能平台 is the thing that actually depends on it.
/// This page is just 供应商（配一个就行）— Responsay-style LLM-only presets + a generic
/// OpenAI-compatible add form. Keys live in the per-provider `FamoProviderKeychain`.
struct FamoAIPage: View {
  @Bindable var state: FamoSettingsState
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool

  // AI 供应商 (multi-provider profiles, B1). The store + secret store default to the live homes;
  // both are reachable only through the tested `FamoSettingsActions` funcs (write-only key field).
  private let providerStore = FamoProviderProfileStore.shared
  private let providerSecrets: FamoSecretStoring = FamoProviderKeychain()
  @State private var providers: [FamoProviderProfile] = []
  @State private var providerID = FamoLLMProviderCatalog.customID
  @State private var providerName = ""
  @State private var providerEndpoint = "https://api.openai.com/v1/chat/completions"
  @State private var providerModel = ""
  @State private var providerKeyInput = ""
  @State private var providerStatus = ""
  /// Hint for the active preset's key format; shown as the API Key field prompt.
  @State private var providerKeyHint = ""
  /// Live model ids pulled by 「拉取最新」; merged after the preset's curated models.
  @State private var fetchedModels: [String] = []
  /// 刚刚被「拉取最新」真的调通过的那把 Key。添加供应商时若与表单里的 Key 一致，就给新档案打上
  /// 「已验证」——「Keychain 里有值」和「这把 Key 能用」是两回事。
  @State private var fetchVerifiedKey: String?
  /// 「联网搜索专用 Key」的输入内容，按凭据 id 分开；与供应商密钥一样只写不回显。
  @State private var searchKeyInputs: [String: String] = [:]
  @State private var searchKeyStatus = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        providerSectionCard
        askWebSearchCard
      }
      .padding(20)
    }
    .onAppear {
      providers = providerStore.profiles()
    }
  }

  // MARK: - 任意提问 · 联网搜索

  /// 任意提问 的联网搜索开关 + 专用 Key + 联网模型选择。只作用于「任意提问」：划词技能、候选、听写
  /// 都不受影响。
  ///
  /// 开启后这一问会路由到一个**已配好密钥的可联网供应商**（联网搜索专用的 豆包搜索 / Perplexity，或
  /// 已配好密钥的 阿里云百炼 / 小米MiMo / OpenAI），与上面选定的默认供应商解耦 —— 默认供应商（常见是
  /// DeepSeek）不支持联网时，这一问仍能真的搜到。全都没配密钥、或全都调不通时自动退回普通问答，不报错。
  private var askWebSearchCard: some View {
    SettingsCard(title: "任意提问 · 联网搜索", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "联网搜索",
          subtitle: "开启后，「任意提问」会交给已配好密钥的联网供应商（豆包搜索 / Perplexity / 阿里云百炼 / 小米MiMo / OpenAI）联网作答；关闭时用模型自有知识回答。只作用于任意提问，不影响划词技能与打字候选。",
          isOn: state.askWebSearchEnabled,
          palette: palette,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.askWebSearchEnabled) {
              FamoAskWebSearchSettings.isEnabled = $0
            }
          }
        )
        if state.askWebSearchEnabled {
          SettingsCardDivider(palette: palette)
          searchCredentialSection
          SettingsCardDivider(palette: palette)
          askWebSearchProviderRow
        }
        SettingsCardDivider(palette: palette)
        Text("开启后你的提问会交给联网供应商检索后作答。某一家调不通时（密钥失效、未开通、额度用尽）会自动顺位到下一家已配好的；全都不可用才退回普通问答，而不是让这一问失败。真正的网络错误/超时仍会如实报错。回答窗口的署名会标出最终由谁作答、有没有联网。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
    }
  }

  /// 「联网搜索专用 Key」区块：豆包搜索 / Perplexity 各一行。
  ///
  /// 与上面的「供应商」列表刻意分开：这两家不是用来当主模型的 —— 豆包搜索只返回网页结果（答案仍由主
  /// 模型写），它的 Key 也取自火山「联网搜索控制台」而不是方舟。写入 `famo.search.*` 的 Keychain 条目，
  /// 与供应商密钥互不影响。
  private var searchCredentialSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("联网搜索专用 Key")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.ink)
      ForEach(FamoSearchCredential.allCases, id: \.rawValue) { credential in
        searchCredentialRow(credential)
      }
      if !searchKeyStatus.isEmpty {
        Text(searchKeyStatus)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
      }
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 一家专用凭据一行：名称 + 只写不回显的 Key 输入框 + 粘贴/保存/清除 + 状态。
  private func searchCredentialRow(_ credential: FamoSearchCredential) -> some View {
    let input = Binding(
      get: { searchKeyInputs[credential.rawValue] ?? "" },
      set: { searchKeyInputs[credential.rawValue] = $0 }
    )
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(credential.displayName)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink)
          .frame(width: 76, alignment: .leading)
        SecureField("API Key（写入 Keychain，只写不回显）", text: input)
          .textFieldStyle(.roundedBorder)
        smallButton("粘贴") {
          if let s = NSPasteboard.general.string(forType: .string) {
            input.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
        smallButton("保存") {
          let result = FamoSettingsActions.saveSearchCredentialKey(
            credential, apiKey: input.wrappedValue, secrets: providerSecrets)
          input.wrappedValue = result.input
          searchKeyStatus = result.status
        }
        smallButton("清除") {
          searchKeyStatus = FamoSettingsActions.clearSearchCredentialKey(
            credential, secrets: providerSecrets)
          input.wrappedValue = ""
        }
      }
      Text("\(FamoSettingsActions.searchCredentialKeyStatus(credential, secrets: providerSecrets)) · \(credential.keyHint) · \(credential.endpoint.host ?? "")")
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(palette.ink3)
        .padding(.leading, 84)
    }
  }

  /// 「联网模型」下拉：自动 + 全部可联网供应商（专用凭据两家 + 内建搜索三家）。只在联网搜索打开时出现。
  ///
  /// 选择**只影响尝试顺序**：选中的那家没填 API Key、或请求发出后被拒（未开通/密钥失效/额度用尽）时，
  /// 仍会顺位到下一家已配好的，而不是让这一问不联网（与 `FamoAskSearchResolver` /
  /// `FamoAskSearchFailover` 的降级一致；到底谁答的由回答窗的署名标出）。
  private var askWebSearchProviderRow: some View {
    let binding = Binding(
      get: { state.askWebSearchProvider },
      set: { newValue in
        FamoSettingsActions.set(newValue, state: state, keyPath: \.askWebSearchProvider) {
          FamoAskSearchProviderSettings.rawValue = $0
        }
      }
    )
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 11) {
        Text("联网模型")
          .font(.system(size: 14))
          .foregroundStyle(palette.ink)
        Spacer(minLength: 8)
        Picker("联网模型", selection: binding) {
          Text("自动").tag("")
          ForEach(FamoSearchControl.searchProviderIDs, id: \.self) { providerID in
            Text(FamoSearchControl.displayName(for: providerID) ?? providerID).tag(providerID)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      Text("「自动」= 先用上面填了专用 Key 的 豆包搜索 / Perplexity；都没填时，当前默认供应商本身能联网就用它，否则按 阿里云百炼 → 小米MiMo → OpenAI 找第一个填了 API Key 的。指定某一家只是把它排到最前；那家没填 Key、或调不通时仍会顺位到下一家，不会因此不联网。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
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
  /// sets it default; the trash button stays a separate control.
  private func providerRow(_ profile: FamoProviderProfile) -> some View {
    HStack(spacing: 10) {
      Button(action: { if !profile.isDefault { setDefaultProvider(profile) } }) {
        HStack(spacing: 10) {
          Image(systemName: profile.isDefault ? "circle.inset.filled" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(profile.isDefault ? palette.accent : palette.ink3)
          VStack(alignment: .leading, spacing: 2) {
            Text(profile.displayName)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(palette.ink)
            Text("\(profile.model.isEmpty ? "默认模型" : profile.model) · \(FamoSettingsActions.providerProfileKeyStatus(profile, secrets: providerSecrets)) · \(FamoLLMProviderCatalog.sourceSupport(for: profile).displayName)")
              .font(.system(size: 11.5, design: .monospaced))
              .foregroundStyle(palette.ink3)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(profile.isDefault ? "\(profile.displayName)（当前默认）" : "设为默认：\(profile.displayName)")
      .accessibilityAddTraits(profile.isDefault ? .isSelected : [])

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
      formRow("预设") { presetControl }
      formRow("端点") { endpointControl }
      formRow("模型") { modelControl }
      formRow("密钥") { keyControl }
      formRow("") { addFooter }
    }
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
      ForEach(FamoLLMProviderCatalog.presets) { preset in
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
    }
  }

  /// API Key：写入 per-provider Keychain（Famo 自己写 → ACL 正确）。
  private var keyControl: some View {
    HStack(spacing: 8) {
      SecureField(secureFieldPrompt, text: $providerKeyInput)
        .textFieldStyle(.roundedBorder)
      smallButton("粘贴") { pasteProviderKey() }
    }
  }

  /// 「添加并设为默认」+ 状态回显。
  private var addFooter: some View {
    HStack(spacing: 8) {
      smallButton("添加并设为默认") { addProvider() }
      if !providerStatus.isEmpty {
        Text(providerStatus)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
      }
    }
  }

  private var isCustomProvider: Bool { providerID == FamoLLMProviderCatalog.customID }

  /// The preset's built-in model(s) — the always-available fallback shown before / without a fetch.
  private var curatedModels: [String] {
    switch providerID {
    case "deepseek":
      return [FamoCloudPreferences.defaultDeepSeekModel, FamoCloudPreferences.reasonerDeepSeekModel]
    case FamoLLMProviderCatalog.customID:
      return []
    default:
      return FamoLLMProviderCatalog.preset(id: providerID).map { [$0.model] } ?? []
    }
  }

  private var availableModels: [String] {
    FamoProviderModelList.merged(curated: curatedModels, fetched: fetchedModels)
  }

  /// The API Key field prompt — the active preset's key-format hint, or a generic line.
  private var secureFieldPrompt: String {
    providerKeyHint.isEmpty
      ? "API Key（写入 Keychain，可留空稍后再填）"
      : "API Key（\(providerKeyHint)，写入 Keychain，可留空稍后再填）"
  }

  /// Prefill the add form from a one-tap preset; the user only pastes the key. DeepSeek keeps the
  /// Chat·V4 Flash / Reasoner·V4 Pro quick model toggle; the others show a plain model field.
  private func fillPreset(_ preset: FamoLLMProviderPreset) {
    providerID = preset.id
    providerName = preset.displayName
    providerEndpoint = preset.endpoint
    providerModel = preset.model
    providerKeyHint = preset.keyHint
    fetchedModels = []
    providerStatus = ""
  }

  /// Reset the add form to a blank generic OpenAI-compatible entry.
  private func fillCustomPreset() {
    providerID = FamoLLMProviderCatalog.customID
    providerName = "自定义（OpenAI 兼容）"
    providerEndpoint = "https://api.openai.com/v1/chat/completions"
    providerModel = ""
    providerKeyHint = ""
    fetchedModels = []
    providerStatus = ""
  }

  private func addProvider() {
    // 每家一条：先移除同一供应商的旧配置（含其 Keychain 键），再添加。
    let newKey = dedupKey(providerID: providerID, endpointHost: URL(string: providerEndpoint)?.host)
    for existing in providers where dedupKey(
      providerID: FamoLLMProviderCatalog.inferredProviderID(for: existing),
      endpointHost: existing.endpoint.host) == newKey {
      _ = FamoSettingsActions.deleteProviderProfile(existing, store: providerStore, secrets: providerSecrets)
    }
    // Custom entries have no preset name — derive one from the endpoint host so rows stay distinct.
    let name = isCustomProvider
      ? "自定义 · \(URL(string: providerEndpoint)?.host ?? "OpenAI 兼容")"
      : providerName
    let result = FamoSettingsActions.addProviderProfile(
      displayName: name,
      endpoint: providerEndpoint,
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
      // 这把 Key 刚在「拉取最新」里真的调通过 → 新档案直接算「已验证」，用户不必再试一次。
      let saved = providerKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
      if !saved.isEmpty, saved == fetchVerifiedKey,
         let added = result.profiles.first(where: {
           FamoLLMProviderCatalog.inferredProviderID(for: $0) == providerID
         }) {
        FamoSettingsActions.markProviderProfileKeyVerified(added)
      }
      fetchVerifiedKey = nil
      fillCustomPreset()
      providerName = ""       // back to the empty 「选择 LLM 预设…」 prompt
      providerKeyInput = ""
    }
  }

  /// One-per-vendor key: a known preset dedupes by its provider id; custom / unknown by endpoint host.
  private func dedupKey(providerID: String, endpointHost: String?) -> String {
    providerID.isEmpty || providerID == FamoLLMProviderCatalog.customID
      ? "host:\(endpointHost ?? "")"
      : "id:\(providerID)"
  }

  /// 「拉取最新」: GET the provider's `/models` with the typed endpoint + key, merge into the model
  /// dropdown. Curated preset models remain the fallback if the fetch fails or returns nothing.
  private func fetchModels() {
    guard let endpoint = URL(string: providerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          endpoint.scheme == "https" else {
      providerStatus = "端点必须是 https"; return
    }
    let key = providerKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { providerStatus = "请先填入 API Key 再拉取"; return }
    let authStyle = FamoLLMProviderCatalog.preset(id: providerID)?.authHeaderStyle ?? .bearer
    providerStatus = "拉取模型中…"
    Task {
      do {
        let models = try await FamoProviderModelList.fetch(endpoint: endpoint, apiKey: key, authStyle: authStyle)
        await MainActor.run {
          fetchedModels = models
          // 拉通了 = 这把 Key 对这个端点真的有效。记下来，添加时给新档案打「已验证」。
          fetchVerifiedKey = key
          if providerModel.isEmpty { providerModel = availableModels.first ?? "" }
          providerStatus = models.isEmpty ? "已连接，但未解析到模型" : "拉到 \(models.count) 个模型，点右侧下拉选择"
        }
      } catch {
        await MainActor.run {
          fetchVerifiedKey = nil
          providerStatus = "拉取失败，请检查端点与 Key"
        }
      }
    }
  }

  /// 一键从剪贴板填入 API Key（比 ⌘V / 右键更显眼，绕开菜单快捷键问题）。仍走现有的「添加并设为默认」持久化。
  private func pasteProviderKey() {
    if let s = NSPasteboard.general.string(forType: .string) {
      providerKeyInput = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func setDefaultProvider(_ profile: FamoProviderProfile) {
    let result = FamoSettingsActions.setDefaultProviderProfile(profile, store: providerStore)
    providers = result.profiles
    providerStatus = result.status
  }

  private func deleteProvider(_ profile: FamoProviderProfile) {
    let result = FamoSettingsActions.deleteProviderProfile(profile, store: providerStore, secrets: providerSecrets)
    providers = result.profiles
    providerStatus = result.status
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
