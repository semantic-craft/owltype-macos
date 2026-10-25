//
//  OwlOnboardingView.swift
//  猫头鹰输入法 (Owltype) — SwiftUI onboarding / welcome window
//
//  Visual spec: the Claude Design "Owltype Onboarding" handoff (claude.ai/design) — the
//  default two-column layout (accent illustration left, content right) with a numbered
//  top stepper + step-name label, and per-step content: welcome chips → enable
//  breadcrumb + real enabled status → selectable scheme cards + apply progress → tips.
//  The primary button is a small state machine (开始 / 去启用→继续 /
//  应用配置→应用中→下一步 / 开始使用).
//
//  Owltype's steps are 完整词库 + 启用输入法 + 选方案/应用配置 + 小贴士 — NOT microphone /
//  voice. The enabled status comes from a real `isOwltypeEnabled` query (TIS); 应用配置 calls
//  the real `onSelectSchema` (which selects + deploys, routed through the same
//  pref-write + patch + fast-apply pipeline the 键盘输入 settings page uses — see
//  `OwlApplicationDelegate.applyOnboardingScheme`).
//
//  The 词库 step comes SECOND, and that ordering is load-bearing rather than cosmetic:
//    - it is this flow's INFORMED-CONSENT surface. Since the 知情同意 change the dict pack
//      is never fetched silently (`OwlDictPackPreferences.autoFetch` defaults false); the
//      step carries the same copyright rationale as `OwlDictPackPrompt.presentAlert` and
//      writes the same `promptShown` flag, and `promptOrFetchIfNeeded` stands down while
//      onboarding is pending so the user is asked exactly once, inline, with no modal
//      stealing focus.
//    - consenting here starts the ~90 MB download BEFORE the two slowest steps (the trip to
//      System Settings to enable, then picking a scheme), so those steps mask it. By the
//      final step it is usually done.
//    - 选方案 offers 五笔/双拼, whose schema files SHIP IN THE DICT PACK. Asking afterwards
//      would mean picking 五笔 lands on the absent-schema path (a second consent alert).
//  Live state comes from `OwlDictPackCenter` (@Observable). No Rime / disk IO in the view.
//
//  The final step verifies real Owltype composition in a local NSTextView; skipping remains available.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the onboarding UI layer only.
//

import SwiftUI
import Combine

/// 引导窗尺寸的唯一出处 —— 视图的固定 frame 与 `OwlOnboardingWindow` 的 contentRect 必须
/// 同一个数，否则窗口比内容大就露底色、比内容小就裁掉底部按钮。
enum OwlOnboardingMetrics {
  static let width: CGFloat = 880
  static let height: CGFloat = 580
  static let illustrationWidth: CGFloat = 340
}

/// The schemes offered on the 选方案 step (id is the real Rime `schema_id` passed to
/// `onSelectSchema`; not-installed ids no-op gracefully, like the settings switcher).
private enum OnboardingScheme: String, CaseIterable, Identifiable {
  case pinyin, wubi, shuangpin
  var id: String { rawValue }
  var glyph: String { self == .pinyin ? "拼" : self == .wubi ? "五" : "双" }
  var name: String { self == .pinyin ? "拼音" : self == .wubi ? "五笔" : "双拼" }
  var code: String { self == .pinyin ? "rime_ice" : self == .wubi ? "wubi86_jidian" : "double_pinyin" }
  var recommended: Bool { self == .pinyin }
}

struct OwlOnboardingView: View {
  /// 去启用 → delegate opens the input-sources pane.
  let onOpenSystemSettings: () -> Void
  /// 应用配置 → delegate `selectSchema(_:)` (selects the schema AND deploys).
  let onSelectSchema: (String) -> Void
  /// 在设置中管理方案 → delegate `showSettings()` (键盘输入 / 输入方案 page).
  let onOpenInputSettings: () -> Void
  /// 开始使用 → delegate sets the done-flag and closes the window.
  let onFinish: () -> Void
  /// Real enabled query (TIS) for the 启用 step status. Defaults to false for previews.
  var isOwltypeEnabled: () -> Bool = { false }
  /// Seeds the wizard's step. Production always starts at 0; tests/previews pass a step so a
  /// snapshot can render one directly — the fixed 720×480 window does not scroll, so every
  /// step's content must be checked for overflow, and `step` is otherwise private @State.
  var initialStep = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  @State private var practiceComplete = false
  @State private var practiceHint: String?
  @State private var practiceSourceIsOwl = false
  @State private var practiceGeneration = 0
  @State private var step = 0
  @State private var owlEnabled = false
  @State private var scheme: OnboardingScheme = .pinyin
  @State private var deploying = false
  @State private var deployed = false
  @State private var deployProgress: CGFloat = 0
  @State private var doneCheckTrim: CGFloat = 0
  /// 用户是否已在词库步骤作出过选择（同意 / 以后再说）—— 决定这一步还问不问。
  @State private var dictDecided = OwlDictPackPreferences.promptShown

  private let stepCount = 5
  private let stepNames = ["欢迎", "词库", "启用", "选方案", "试打"]

  /// 深大红 theme (shared with the candidate panel + settings).
  private let theme: OwlCandidateTheme = .shenda
  private var palette: OwlCandidatePalette { theme.palette(for: colorScheme) }
  private var accentSoft: Color { palette.accent.opacity(colorScheme == .dark ? 0.20 : 0.12) }

  var body: some View {
    HStack(spacing: 0) {
      illustrationPanel
        .frame(width: OwlOnboardingMetrics.illustrationWidth)
        .frame(maxHeight: .infinity)
      contentColumn
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // Fixed window size — without this the NSHostingView sizes the (non-resizable)
    // window to the content's unbounded fitting height and the panel runs too tall.
    .frame(width: OwlOnboardingMetrics.width, height: OwlOnboardingMetrics.height)
    .background(palette.card.ignoresSafeArea())
    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: step)
    .onAppear {
      owlEnabled = isOwltypeEnabled()
      if initialStep != 0 { step = initialStep }
    }
  }

  // MARK: - Content column (right)

  private var contentColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      topStepper
      stepBody
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      footer
    }
    .padding(.horizontal, 30)
    .padding(.top, 26)
    .padding(.bottom, 24)
  }

  private var topStepper: some View {
    HStack(spacing: 10) {
      HStack(spacing: 7) {
        ForEach(0..<stepCount, id: \.self) { index in
          stepperDot(index)
        }
      }
      Text("第 \(step + 1) / \(stepCount) 步 · \(stepNames[step])")
        .font(.system(size: 12.5))
        .foregroundStyle(palette.ink3)
    }
    .padding(.bottom, 22)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("第 \(step + 1) 步，共 \(stepCount) 步，\(stepNames[step])")
  }

  private func stepperDot(_ index: Int) -> some View {
    let done = index < step
    let current = index == step
    let active = done || current
    return Text(done ? "✓" : "\(index + 1)")
      .font(.system(size: 11.5, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(active ? palette.onAccent : palette.ink2)
      .frame(width: 22, height: 22)
      .background { Circle().fill(active ? palette.accent : palette.card2) }
      .overlay { if current { Circle().strokeBorder(accentSoft, lineWidth: 3) } }
  }

  @ViewBuilder
  private var stepBody: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.owlSerif(size: 23))
          .foregroundStyle(palette.ink)
        Text(desc)
          .font(.system(size: 14))
          .foregroundStyle(palette.ink2)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 470, alignment: .leading)
      }
      switch step {
      case 0: welcomeChips
      case 1: dictContent
      case 2: enableContent
      case 3: schemeContent
      default: doneContent
      }
    }
  }

  private var title: String {
    ["欢迎使用猫头鹰", "完整词库", "启用猫头鹰输入法", "选择输入方案", "试打一下"][step]
  }
  private var desc: String {
    [
      "现代、本地、为简体中文而生的开源输入法 —— 由 RIME / librime 驱动，词库与按键都在你掌心。",
      "猫头鹰只内置自建的清洁室精简词库。五笔、简体拼音、小鹤双拼等方案的词库来自第三方开源项目（雾凇拼音 rime-ice、极点五笔86）—— 为避免版权争议，猫头鹰不随安装包分发它们，也不会在你不知情的情况下替你下载。",
      "打开「系统设置 → 键盘 → 输入法」，在列表中勾选「猫头鹰」即可。点下方按钮可直达设置面板。",
      "挑一个方案先用起来，随时能在设置里增删与切换。推荐从拼音开始。",
      "切换到猫头鹰输入法，在下面打出第一句，确认输入已经正常。"
    ][step]
  }

  // MARK: Step 0 — welcome chips

  private var welcomeChips: some View {
    HStack(spacing: 8) {
      ForEach(["本地运行 · 隐私优先", "RIME 引擎", "为法律与编程优化"], id: \.self) { text in
        HStack(spacing: 6) {
          Circle().fill(palette.accent).frame(width: 5, height: 5)
          Text(text).font(.system(size: 12.5)).foregroundStyle(palette.ink2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.card2) }
      }
    }
  }

  // MARK: Step 1 — enable breadcrumb + real status

  private var enableContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 7) {
        breadcrumb("系统设置", accent: false)
        chevron
        breadcrumb("键盘", accent: false)
        chevron
        breadcrumb("输入法 → 猫头鹰", accent: true)
      }
      .padding(.horizontal, 15)
      .padding(.vertical, 13)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.card2) }

      HStack(spacing: 9) {
        Image(systemName: owlEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(owlEnabled ? Color.green : palette.ink3)
        Text(owlEnabled ? "已启用 —— 猫头鹰已出现在输入法列表" : "未启用 —— 尚未在输入法列表中勾选")
          .font(.system(size: 13))
          .foregroundStyle(owlEnabled ? palette.ink : palette.ink3)
        Spacer(minLength: 8)
        Button("重新检查") { owlEnabled = isOwltypeEnabled() }
          .buttonStyle(.plain)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.accent)
      }
      Text("若 macOS 弹出允许「Owltype」启用「猫头鹰输入法」的确认框，请在该弹窗点 Allow。若右上角已显示猫头鹰但不能打字，请到输入法编辑列表先移除猫头鹰，再重新添加。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func breadcrumb(_ text: String, accent: Bool) -> some View {
    Text(text).font(.system(size: 13)).foregroundStyle(accent ? palette.accent : palette.ink2)
  }
  private var chevron: some View {
    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.ink3)
  }

  // MARK: Step 2 — scheme cards + apply progress

  private var schemeContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ForEach(OnboardingScheme.allCases) { item in schemeCard(item) }
      }
      if deploying || deployed {
        HStack(spacing: 10) {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule().fill(palette.card2)
              Capsule().fill(palette.accent)
                .frame(width: geo.size.width * (deployed ? 1 : deployProgress))
            }
          }
          .frame(height: 5)
          Text(deployed ? "配置已应用" : "应用中…")
            .font(.system(size: 11.5)).monospacedDigit()
            .foregroundStyle(palette.ink3)
        }
      }
      Button(action: onOpenInputSettings) {
        Text("在设置中管理方案 ›")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(palette.ink3)
      }
      .buttonStyle(.plain)
    }
  }

  private func schemeCard(_ item: OnboardingScheme) -> some View {
    let selected = item == scheme
    let locked = deploying || deployed
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(item.glyph)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(selected ? palette.onAccent : palette.ink2)
          .frame(width: 30, height: 30)
          .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? palette.accent : palette.card) }
        Spacer(minLength: 0)
        if item.recommended {
          Text("推荐")
            .font(.system(size: 10))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accentSoft) }
        }
      }
      Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink)
      Text(item.code).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink3)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.card2) }
    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 2) }
    .opacity(locked && !selected ? 0.5 : 1)
    .contentShape(Rectangle())
    .onTapGesture { if !locked { scheme = item } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel("\(item.name) \(item.code)\(item.recommended ? " 推荐" : "")")
  }

  // MARK: Step 1 — 完整词库 / 知情同意 (this flow's consent surface; see the file header for
  // why it sits here. OwlDictPackCenter is @Observable so the body re-renders on progress.)

  private var dictContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      dictStatusRow
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.card2) }
      Text(dictExplanation)
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var dictExplanation: String {
    if OwlDictPackCenter.shared.preparedCandidate != nil {
      return "资源候选已完成版本、摘要、许可证和 SQLite 校验。核对上面的生成统计后点「启用」，新输入会话才会使用它；旧资源代次会保留，可随时回退。整个切换不改写学习库，也不依赖 Rime 部署。"
    }
    if needsDictConsent {
      return "同意后，猫头鹰会从这些项目的官方仓库按固定版本获取（约 90 MB）并逐文件校验，然后生成待确认的 Rust 资源。下载在后台进行，你可以继续下面的步骤。选「以后再说」也不影响使用，之后随时能在「设置 → 键盘输入 → 完整词库」里下载。"
    }
    return "词库按固定版本从上游原仓库（雾凇拼音 / 极点五笔 / 八股文语法模型）下载并逐文件校验，中途退出或注销会自动续传。生成完成后需要你确认才会启用，等待期间可以先看下一步。"
  }

  /// 仍需征求同意：词库没装，且本次没在这一步作出过选择。
  private var needsDictConsent: Bool {
    if case .notInstalled = OwlDictPackCenter.shared.status { return !dictDecided }
    return false
  }

  /// 「同意并下载」——与 `OwlDictPackPrompt.presentAlert` 的 .download 分支等价：先记已处置
  /// 再执行。这里用 `start()` 而非 `acceptAndStart()`，后者会把用户甩进设置窗、打断向导。
  private func acceptDictDownload() {
    dictDecided = true
    OwlDictPackPreferences.promptShown = true
    OwlDictPackCenter.shared.start()
  }

  /// 「以后再说」——等价于弹窗的 .later：同样记已处置（问过了就别再问），不下载。
  private func deferDictDownload() {
    dictDecided = true
    OwlDictPackPreferences.promptShown = true
    step = 2
  }

  @ViewBuilder
  private var dictStatusRow: some View {
    let center = OwlDictPackCenter.shared
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        switch center.status {
        case .notInstalled:
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 16))
            .foregroundStyle(palette.ink3)
          Text(dictDecided
            ? "未启用 —— 当前使用随包精简资源"
            : "当前为精简词库 —— 五笔 / 简体拼音 / 小鹤双拼 等方案需要它才能使用（约 90 MB）")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          if dictDecided {
            // 已问过（含从「关于」页重开引导的回访者）：主按钮不再是同意键，这里补一个入口，
            // 否则这一步只剩一句「未下载」而无从下手。
            Button("现在下载") { acceptDictDownload() }
              .buttonStyle(.plain)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(palette.accent)
          }
        case .downloading(let progress):
          dictProgressBar(progress)
          Text(center.usesRustResources
            ? "下载、校验并生成资源 \(Int(progress * 100))%"
            : "下载中 \(Int(progress * 100))%")
            .font(.system(size: 12.5)).monospacedDigit()
            .foregroundStyle(palette.ink2)
        case .deploying:
          ProgressView()
            .controlSize(.small)
          Text("已下载，正在编译词库…")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink2)
          Spacer(minLength: 8)
        case .prepared(let version):
          Image(systemName: "checkmark.seal")
            .font(.system(size: 16))
            .foregroundStyle(palette.accent)
          Text("候选 v\(version) 已生成，等待启用")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink)
          Spacer(minLength: 8)
          Button("启用") { center.activatePrepared() }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.accent)
        case .activating:
          ProgressView()
            .controlSize(.small)
          Text("正在校验并启用资源…")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink2)
          Spacer(minLength: 8)
        case .rollingBack:
          ProgressView()
            .controlSize(.small)
          Text("正在校验并回退资源…")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink2)
          Spacer(minLength: 8)
        case .installed(let version):
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(Color.green)
          Text(center.isAwaitingLiveSessionRefresh
            ? "完整词库 v\(version) 已启用；当前输入完成后自动生效"
            : "完整词库已就绪")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink)
          Spacer(minLength: 8)
        case .userProvided:
          Image(systemName: "checkmark.circle")
            .font(.system(size: 16))
            .foregroundStyle(Color.green)
          Text("检测到自备完整词库，无需下载")
            .font(.system(size: 13))
            .foregroundStyle(palette.ink)
          Spacer(minLength: 8)
        case .failed(let message):
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 15))
            .foregroundStyle(.orange)
          Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.ink2)
            .lineLimit(2)
          Spacer(minLength: 8)
          Button("重试") { center.retryFailedOperation() }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.accent)
        }
      }
      if let candidate = center.preparedCandidate {
        Text(
          "拼音 \(candidate.pinyinEntries.formatted()) · "
            + "五笔 \(candidate.wubiEntries.formatted()) · "
            + "英文 \(candidate.englishEntries.formatted()) · "
            + "拒绝 \(candidate.rejectedEntries.formatted())"
        )
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(palette.ink3)
        Text("许可证：\(candidate.licenseIdentifiers.joined(separator: "、"))")
          .font(.system(size: 11.5))
          .foregroundStyle(palette.ink3)
      }
    }
  }

  private func dictProgressBar(_ progress: Double) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(palette.card)
        Capsule().fill(palette.accent)
          .frame(width: geo.size.width * progress)
      }
    }
    .frame(height: 5)
  }

  // MARK: Step 4 — actual marked-text and commit verification

  private var doneContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(OwlPracticeProof.target).font(.system(size: 21, weight: .semibold))
      OwlPracticeField { _, complete, hint in
        practiceComplete = complete
        practiceHint = hint
      }
      .id(practiceGeneration)
      .frame(height: 85)
      Label(practiceSourceIsOwl ? "当前已选中猫头鹰" : "请从菜单栏切换到猫头鹰",
            systemImage: practiceSourceIsOwl ? "checkmark.circle.fill" : "keyboard")
        .font(.system(size: 12)).foregroundStyle(palette.ink2)
      Label(practiceComplete ? "试打成功，可以开始使用了" : (practiceHint ?? "等待手动输入完整句子；粘贴不计入"),
            systemImage: practiceComplete ? "checkmark.circle.fill" : "pencil")
        .font(.system(size: 12)).foregroundStyle(palette.ink2)
        .accessibilityIdentifier("onboarding.practice.result")
      Button("清空重试") {
        practiceGeneration += 1
        practiceComplete = false
        practiceHint = nil
      }.buttonStyle(.plain).foregroundStyle(palette.accent)
    }
    .onAppear { refreshPracticeSource() }
    .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in refreshPracticeSource() }
  }

  private func refreshPracticeSource() {
    practiceSourceIsOwl = OwlInstaller.InputMode(rawValue: OwlInstaller.currentInputSourceID() ?? "") != nil
  }

  // MARK: - Footer (primary state machine + back + skip)

  private var footer: some View {
    HStack(spacing: 14) {
      primaryButton
      if step > 0 {
        Button("上一步") { step -= 1 }
          .buttonStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
      }
      if step == 1 && needsDictConsent {
        // 与弹窗的「稍后」等价的那一半：同意二选一必须两个都在场，否则「同意」不成其为选择。
        Button("以后再说") { deferDictDownload() }
          .buttonStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
      }
      Spacer(minLength: 0)
      if step < stepCount - 1 {
        Button("跳过", action: onFinish)
          .buttonStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
      } else if primaryInfo.disabled {
        // 软阻塞的出口：词库还在下载/编译时不扣留用户 —— 下载在 App 级继续，
        // 引导关掉也不中断。
        Button("稍后再试", action: onFinish)
          .buttonStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
      }
    }
    .padding(.top, 18)
  }

  private var primaryButton: some View {
    let info = primaryInfo
    return Button(action: info.action) {
      Text(info.label)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(palette.onAccent)
        // 主按钮恒单行：footer 宽度有限，文案变长时宁可挤别人也不要默默折成两行矮胖块
        // （「同意并下载（约 90 MB）」就这么折过一次）。
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
        .background { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.accent) }
        .shadow(color: palette.accent.opacity(0.32), radius: 8, y: 4)
    }
    .buttonStyle(.plain)
    .disabled(info.disabled)
    .opacity(info.disabled ? 0.55 : 1)
    .accessibilityLabel(info.label)
  }

  /// The per-step / per-state primary button (label + action + disabled).
  private var primaryInfo: (label: String, action: () -> Void, disabled: Bool) {
    switch step {
    case 0:
      return ("开始", { step = 1 }, false)
    case 1:
      // 知情同意：没装且没问过 → 主按钮就是「同意并下载」（配对的「以后再说」在 footer）。
      // 同意后停在本步显示进度作为确认，但不扣留——按钮立刻变「下一步」。
      // 按钮只留动作，体积写在状态行 —— footer 这一行还要容下「上一步 / 以后再说 / 跳过」，
      // 带上「（约 90 MB）」会把主按钮挤成两行（2026-07-27 快照实见）。
      if needsDictConsent {
        return ("同意并下载", { acceptDictDownload() }, false)
      }
      return ("下一步", { step = 2 }, false)
    case 2:
      if owlEnabled { return ("继续", { step = 3 }, false) }
      return ("去启用", { onOpenSystemSettings(); owlEnabled = isOwltypeEnabled() }, false)
    case 3:
      if deployed { return ("下一步", { advanceToDone() }, false) }
      if deploying { return ("应用中…", {}, true) }
      return ("应用配置", { startDeploy() }, false)
    default:
      // 完成页软阻塞：下载/编译期间置灰、按钮标签就是进度；失败或未下载不扣留
      // （出口在 footer 的「暂不等待」/ 状态自然放行）。
      switch OwlDictPackCenter.shared.status {
      case .downloading(let progress):
        return ("词库下载中 \(Int(progress * 100))%…", {}, true)
      case .deploying:
        return ("词库编译中…", {}, true)
      case .prepared:
        return ("启用词库", { OwlDictPackCenter.shared.activatePrepared() }, false)
      case .activating:
        return ("词库启用中…", {}, true)
      case .rollingBack:
        return ("词库回退中…", {}, true)
      default:
        return ("开始使用", onFinish, !practiceComplete)
      }
    }
  }

  private func startDeploy() {
    deploying = true
    deployProgress = 0
    onSelectSchema(scheme.code)   // real select + deploy
    if reduceMotion {
      deployProgress = 1
    } else {
      withAnimation(.linear(duration: 1.0)) { deployProgress = 1 }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
      deploying = false
      deployed = true
    }
  }

  private func advanceToDone() {
    practiceComplete = false
    practiceHint = nil
    practiceGeneration += 1
    step = 4
    doneCheckTrim = 0
    if reduceMotion {
      doneCheckTrim = 1
    } else {
      withAnimation(.easeOut(duration: 0.6).delay(0.12)) { doneCheckTrim = 1 }
    }
  }

  // MARK: - Illustration panel (left)

  private var illustrationPanel: some View {
    ZStack {
      LinearGradient(
        colors: [palette.accentDeep, palette.accent, palette.accentDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
      )
      Circle()
        .fill(palette.onAccent.opacity(0.16))
        .frame(width: 320, height: 320)
        .blur(radius: 40)
        .offset(x: -90, y: 120)
      illustrationGlyph
      VStack {
        Spacer()
        Text("猫头鹰 · OWLTYPE")
          .font(.system(size: 12, weight: .medium))
          .tracking(2)
          .foregroundStyle(palette.onAccent.opacity(0.6))
          .padding(.bottom, 26)
      }
    }
    .clipped()
  }

  @ViewBuilder
  private var illustrationGlyph: some View {
    switch step {
    case 0:
      ZStack {
        Circle().strokeBorder(palette.onAccent.opacity(0.22), lineWidth: 1.5).frame(width: 200, height: 200)
        Circle().strokeBorder(palette.onAccent.opacity(0.16), lineWidth: 1.5).frame(width: 150, height: 150)
        Text("法")
          .font(.system(size: 58, weight: .semibold))
          .foregroundStyle(palette.onAccent)
          .frame(width: 104, height: 104)
          .background { RoundedRectangle(cornerRadius: 26, style: .continuous).fill(palette.onAccent.opacity(0.14)) }
          .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(palette.onAccent.opacity(0.25), lineWidth: 1) }
      }
    case 1:
      ZStack {
        Circle().strokeBorder(palette.onAccent.opacity(0.22), lineWidth: 1.5).frame(width: 200, height: 200)
        Circle().strokeBorder(palette.onAccent.opacity(0.16), lineWidth: 1.5).frame(width: 150, height: 150)
        Image(systemName: "arrow.down.to.line")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(palette.accent)
          .frame(width: 96, height: 96)
          .background { Circle().fill(palette.onAccent) }
          .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
      }
    case 2:
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(palette.onAccent.opacity(0.12))
        .frame(width: 120, height: 120)
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(palette.onAccent.opacity(0.25), lineWidth: 1) }
        .overlay {
          Image(systemName: "checkmark")
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(palette.accent)
            .frame(width: 54, height: 54)
            .background { Circle().fill(palette.onAccent) }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
    case 3:
      ZStack {
        fanCard(rotation: -13, fill: palette.onAccent.opacity(0.10))
        fanCard(rotation: -2, fill: palette.onAccent.opacity(0.14))
        fanCard(rotation: 9, fill: palette.onAccent) {
          Text("拼").font(.system(size: 40, weight: .semibold)).foregroundStyle(palette.accent)
        }
      }
      .frame(width: 200, height: 200)
    default:
      ZStack {
        Circle().strokeBorder(palette.onAccent.opacity(0.2), lineWidth: 1.5).frame(width: 176, height: 176)
        Circle().strokeBorder(palette.onAccent.opacity(0.28), lineWidth: 2).frame(width: 116, height: 116)
        Path { p in
          p.move(to: CGPoint(x: 42, y: 62))
          p.addLine(to: CGPoint(x: 60, y: 82))
          p.addLine(to: CGPoint(x: 98, y: 40))
        }
        .trim(from: 0, to: doneCheckTrim)
        .stroke(palette.onAccent, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
        .frame(width: 140, height: 122)
      }
    }
  }

  private func fanCard<Glyph: View>(rotation: Double, fill: Color, @ViewBuilder glyph: () -> Glyph = { EmptyView() }) -> some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
      .fill(fill)
      .frame(width: 96, height: 116)
      .overlay { glyph() }
      .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.onAccent.opacity(0.18), lineWidth: 1) }
      .rotationEffect(.degrees(rotation))
      .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
  }
}
