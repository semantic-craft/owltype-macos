//
//  OwlSettingsPages.swift
//  猫头鹰输入法 (Owltype) — SwiftUI settings window
//
//  v0.3: the 关于 (About) sidebar page + the 皮肤预览 section for the
//  NavigationSplitView shell in `OwlSettingsView`. The 候选窗外观 / 输入方案 pages
//  stay inline in `OwlSettingsView` because they reuse its v0.2.x section builders;
//  the 键盘输入 page moved to its own `OwlKeyboardPage.swift` (v0.3.1) once it grew
//  the full option groups.
//
//  Both use the shared `SettingsCard` kit (`OwlSettingsComponents.swift`) and are
//  palette-driven (no hardcoded colors). 关于 reads versions/credits from the
//  passed-in `state` (seeded by the delegate) + `Bundle.main`.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only.
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the settings UI).
//

import AppKit
import SwiftUI

// MARK: - 关于 (About)

/// About page: app version, librime version, installed-schema count, maintenance /
/// diagnostic actions + status line, and a credits card.
///
/// `actionSection` / `statusLine` are passed in as builders so the page reuses
/// `OwlSettingsView`'s v0.2.x section builders verbatim (same callbacks/state),
/// rather than duplicating the button chrome.
struct OwlAboutPage: View {
  @Bindable var state: OwlSettingsState
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool
  let actionSection: () -> AnyView
  let statusLine: () -> AnyView

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        infoCard
        actionSection()
        if !state.statusMessage.isEmpty {
          statusLine()
        }
        creditsCard
      }
      .padding(20)
    }
  }

  // MARK: Version / count

  private var infoCard: some View {
    SettingsCard(
      title: "关于猫头鹰",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 0) {
        infoRow(label: "猫头鹰输入法", value: appVersionDisplay)
        SettingsCardDivider(palette: palette)
        infoRow(label: "构建标识", value: appBuildIdentityDisplay)
        SettingsCardDivider(palette: palette)
        infoRow(label: "设计与开发", value: "深圳大学法律人工智能实训实验室")
        if !state.librimeVersion.isEmpty {
          SettingsCardDivider(palette: palette)
          infoRow(label: "librime", value: state.librimeVersion)
        }
        SettingsCardDivider(palette: palette)
        infoRow(label: "已安装方案", value: "\(state.schemas.count) 个")
        if !state.currentInputSourceDisplayName.isEmpty {
          SettingsCardDivider(palette: palette)
          infoRow(label: "当前系统输入源", value: state.currentInputSourceDisplayName)
        }
        SettingsCardDivider(palette: palette)
        updateRow
      }
    }
  }

  /// 软件更新 row: a single Sparkle 检查更新 button (mirrors the responsay About pattern, minimal).
  /// Disabled when the updater can't check yet (no feed / in-flight), matching the delegate guard
  /// in `checkForUpdates()`. Off the IMK hot path — settings UI only.
  private var updateRow: some View {
    HStack(spacing: 10) {
      Text("软件更新")
        .font(.system(size: 14))
        .foregroundStyle(palette.ink)
      Spacer(minLength: 8)
      Button("检查更新") { NSApp.owlAppDelegate.checkForUpdates() }
        .disabled(!NSApp.owlAppDelegate.updateController.updater.canCheckForUpdates)
    }
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private func infoRow(label: String, value: String) -> some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.system(size: 14))
        .foregroundStyle(palette.ink)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.ink2)
        .textSelection(.enabled)
    }
    .padding(.vertical, 8)
  }

  /// "1.0 (42)" from Info.plist, or "未知" if the keys are missing (never crashes).
  private var appVersionDisplay: String {
    Self.versionDisplay(info: Bundle.main.infoDictionary)
  }

  private var appBuildIdentityDisplay: String {
    Self.buildIdentityDisplay(bundleIdentifier: Bundle.main.bundleIdentifier)
  }

  static func versionDisplay(info: [String: Any]?) -> String {
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    switch (short, build) {
    case let (.some(s), .some(b)): return "\(s) (\(b))"
    case let (.some(s), .none): return s
    case let (.none, .some(b)): return b
    default: return "未知"
    }
  }

  static func buildIdentityDisplay(bundleIdentifier: String?) -> String {
    bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "未知"
  }

  // MARK: Credits

  private var creditsCard: some View {
    SettingsCard(
      title: "致谢与开源许可",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(alignment: .leading, spacing: 8) {
        creditLine(name: "Squirrel（鼠须管）", license: "GPLv3")
        creditLine(name: "librime（中州韵输入法引擎）", license: "BSD-3-Clause")
        creditLine(name: "雾凇拼音 rime-ice（iDvel）", license: "GPLv3 · 拼音底座")
        creditLine(name: "极点五笔86（KyleBing）", license: "Apache-2.0 · 五笔全套")
        creditLine(name: "rime-octagram-data（lotem）", license: "八股文语法模型")
      }
    }
  }

  @ViewBuilder
  private func creditLine(name: String, license: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(name)
        .font(.system(size: 13))
        .foregroundStyle(palette.ink2)
      Spacer(minLength: 8)
      Text(license)
        .font(.system(size: 11))
        .foregroundStyle(palette.ink3)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - 诊断 (Diagnostics)

/// Read-only activation-diagnostics page: renders `OwlTISDiagnostics.buildReport()`
/// (six TIS layers + OWL-* codes + actionable text + install/data identity) and exports a
/// redacted support bundle. Lives here rather than a new file to stay off the pbxproj — the
/// only cross-session merge-conflict point. Off the IMK hot path; settings UI only.
struct OwlDiagnosticsPage: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  @State private var report: OwlTISReport = OwlTISDiagnostics.buildReport()
  @State private var makeDefaultStatus: String = OwlDiagnosticsPage.makeDefaultStatusText(nil)

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        summaryCard
        layersCard
        identityCard
        actionsCard
      }
      .padding(20)
    }
  }

  // MARK: Summary

  private var summaryCard: some View {
    SettingsCard(title: "诊断概要", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 8) {
        line(label: "结论", value: report.summary.code ?? "全部可判定 TIS 层健康")
        if let message = report.summary.userMessage {
          line(label: "说明", value: message)
        }
        Text(report.summary.actionable)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink2)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: Six layers

  private var layersCard: some View {
    SettingsCard(title: "六层激活诊断", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(report.layers.enumerated()), id: \.offset) { index, layer in
          if index > 0 { SettingsCardDivider(palette: palette) }
          layerRow(layer)
        }
      }
    }
  }

  @ViewBuilder
  private func layerRow(_ layer: LayerResult) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(Self.glyph(layer.ok))
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(Self.color(layer.ok, palette: palette))
        Text(Self.layerName(layer.layer))
          .font(.system(size: 14))
          .foregroundStyle(palette.ink)
        if let code = layer.code {
          Spacer(minLength: 8)
          Text(code)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.ink3)
        }
      }
      Text(layer.detail)
        .font(.system(size: 12))
        .foregroundStyle(palette.ink2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Identity / data root

  private var identityCard: some View {
    SettingsCard(title: "安装与数据", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 0) {
        line(label: "已安装", value: report.identity.installed ? "是" : "否")
        SettingsCardDivider(palette: palette)
        line(label: "Bundle ID 匹配", value: report.identity.bundleIDMatches ? "是" : "否")
        SettingsCardDivider(palette: palette)
        line(label: "安装路径", value: report.identity.installPath)
        SettingsCardDivider(palette: palette)
        line(label: "当前系统输入源", value: report.currentSourceID ?? "无")
        SettingsCardDivider(palette: palette)
        makeDefaultRow
        SettingsCardDivider(palette: palette)
        line(label: "数据目录", value: report.dataRoot.path)
        SettingsCardDivider(palette: palette)
        line(label: "数据目录存在", value: report.dataRoot.exists ? "是" : "否")
      }
    }
  }

  /// 「设为系统默认输入法」= enable + select（docs/default-input-method-plan.md §4）：系统随即把猫头鹰
  /// 写进 `AppleSelectedInputSources`，下次登录自动恢复猫头鹰。这个按钮是全仓唯一允许调用
  /// `makeDefault()` 的地方 —— 用户显式点击才动当前输入源，安装 / 更新 / 启动路径一律不得复用。
  private var makeDefaultRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button("设为系统默认输入法") {
          makeDefaultStatus = Self.makeDefaultStatusText(OwlInstaller().makeDefault())
          report = OwlTISDiagnostics.buildReport()
        }
        Spacer(minLength: 8)
      }
      Text(makeDefaultStatus)
        .font(.system(size: 12))
        .foregroundStyle(palette.ink2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 三态结果文案（`nil` = 还没点，给一句说明按钮到底做什么）。纯函数，覆盖在 ActivationPolicyTests。
  static func makeDefaultStatusText(_ result: OwlInstaller.MakeDefaultResult?) -> String {
    switch result {
    case .none:
      return "把猫头鹰切成当前输入源，系统会记住它：下次登录自动恢复猫头鹰。（macOS 没有「默认输入法」开关，这就是「默认」的全部含义。）"
    case .alreadyDefault(let mode):
      return "\(mode.displayName)已经是当前系统输入源，下次登录会自动恢复它。"
    case .madeDefault(let mode):
      return "已设为默认：\(mode.displayName)。下次登录会自动恢复它。"
    case .failed(let reason):
      return "未能设为默认：\(reason)"
    }
  }

  // MARK: Actions

  private var actionsCard: some View {
    SettingsCard(title: "支持", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      HStack(spacing: 10) {
        Button("刷新") { report = OwlTISDiagnostics.buildReport() }
        Button("导出诊断包") { exportSupportBundle() }
        Spacer()
      }
    }
  }

  @ViewBuilder
  private func line(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .font(.system(size: 14))
        .foregroundStyle(palette.ink)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.ink2)
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Presentation helpers (pure)

  static func glyph(_ ok: Bool?) -> String {
    switch ok {
    case .some(true): return "✓"
    case .some(false): return "✗"
    case .none: return "—"
    }
  }

  static func color(_ ok: Bool?, palette: OwlCandidatePalette) -> Color {
    switch ok {
    case .some(true): return palette.accent
    case .some(false): return .red
    case .none: return palette.ink3
    }
  }

  static func layerName(_ layer: ActivationLayer) -> String {
    switch layer {
    case .register: return "注册 register"
    case .enumerate: return "枚举 enumerate"
    case .enable: return "启用 enable"
    case .select: return "选中 select"
    case .menuVisible: return "菜单可见 menuVisible"
    case .clientAttach: return "客户端连接 clientAttach"
    }
  }

  // MARK: Support bundle export

  private func exportSupportBundle() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "owl-diagnostics.txt"
    panel.title = "导出猫头鹰诊断支持包"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let text = Self.supportBundleText(report: report)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Assemble the redacted support bundle: version/OS header + report JSON + recent unified logs.
  static func supportBundleText(report: OwlTISReport) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let json = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let version = OwlAboutPage.versionDisplay(info: Bundle.main.infoDictionary)
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let raw = """
    # 猫头鹰诊断支持包
    版本: \(version)
    系统: \(os)

    ## TIS 六层诊断 (JSON)
    \(json)

    ## 最近日志（子系统 im.owltype.inputmethod.Owltype，近 30 分钟）
    \(recentUnifiedLogs())

    \(OwlLogoutDiagnostics.supportBundleSection())
    """
    return redact(raw)
  }

  /// 脱敏：把用户主目录路径（含用户名）收敛成 ~。ponytail: 主目录是唯一 PII 面——
  /// 报告本身只含 TIS/身份/路径、无密钥；日志将来若带更多敏感字段再扩。
  static func redact(_ text: String) -> String {
    text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  /// Owltype 用统一日志（无文件日志）。窄子系统谓词 + 近 30 分钟 compact，够快、有界。
  /// 先读到 EOF 再 waitUntilExit（避免 launchctl 式管道满死锁）；输出 64KB 上界；
  /// 失败/空则给「控制台」App 指引。
  static func recentUnifiedLogs() -> String {
    let hint = "（近 30 分钟无子系统日志。如需更多，请在「控制台」App 按子系统 im.owltype.inputmethod.Owltype 过滤导出。）"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show", "--last", "30m", "--style", "compact",
      "--predicate", "subsystem == \"im.owltype.inputmethod.Owltype\"",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      // Read to EOF *before* waiting — a full pipe buffer would otherwise deadlock the child.
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return hint }
      return String(text.suffix(64 * 1024))
    } catch {
      return "（无法读取统一日志：\(error.localizedDescription)。请在「控制台」App 按子系统 im.owltype.inputmethod.Owltype 过滤。）"
    }
  }
}
