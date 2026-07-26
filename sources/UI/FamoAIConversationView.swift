//
//  FamoAIConversationView.swift
//  法墨输入法 (Famo) — AI conversation window SwiftUI view (roadmap B10, v1)
//
//  The chat surface hosted by `FamoAIWindow`. First screen IS the usable chat UI (not settings /
//  marketing): a captured-context quote, a provider-route seal, the conversation flow, a composer,
//  and copy / regenerate / stop / close controls. It renders the view model's `state` and forwards
//  user intents back to it; the window owns copy + close (copy-only — no auto-insert).
//
//  Look (方案 C · 书卷编辑式): leans into Famo's 法律/学术 identity — warm paper ground
//  (`palette.card`), 衬线正文 (`Font.famoSerif`), an accent hairline rule, the captured context as a
//  pull-quote, and a wax-seal route chip. Colors come from the active skin's 8-token
//  `FamoCandidatePalette` (skin- and light/dark-aware), same source the candidate panel / 划词菜单 use.
//
//  Conversation layout: the user's questions are right-aligned bubbles, answers are serif body with
//  an accent lead line — the two roles are visually distinct and the flow reads like a chat. The
//  composer is a bordered multi-line card (1–6 growing lines) with an optional task chip on top
//  (`FamoAIComposerTask`): 划词脚手架不再把指令句预填进输入框，指令藏在卡里，用户只填自己的部分。
//
//  Boundary: no Rime / hot-path involvement — UI only.
//

import SwiftUI

/// A task chip mounted on the composer. 划词技能的脚手架（参考风格对齐 / 提示词优化澄清 / 结构化
/// 澄清）改由它承载：指令前缀藏进 `scaffold`（不再预填进输入框），澄清问题逐条显示在卡上，用户
/// 只输入自己要补的内容；送出时发给模型的是 `scaffold + 输入`，气泡里展示的是「任务名：输入」。
/// 点 × 可摘掉任务，退回普通提问。
struct FamoAIComposerTask: Equatable {
  /// 任务签标题；也用作提问气泡的前缀，让历史可读。
  let label: String
  /// 逐条显示在任务卡上的澄清问题（空 = 无问题区）。
  let clarifications: [String]
  /// 输入框占位文案，提示该补什么。
  let placeholder: String
  /// 隐藏的指令前缀；`scaffold + 用户输入` 才是真正提交的问题（与 FamoSkillsLiveTests 的拼法一致）。
  let scaffold: String
}

struct FamoAIConversationView: View {
  let model: FamoAIConversationModel
  let initialQuestion: String
  /// 展示用短署名（如「辅助检索」）：autoSubmit 技能的完整指令 prompt 不适合整段出现在提问气泡里。
  let initialDisplayQuestion: String?
  let autoSubmit: Bool
  /// 划词脚手架任务卡（nil = 普通提问窗口）。
  let initialTask: FamoAIComposerTask?
  /// Window-owned copy (copy-only; never auto-inserts into the target app).
  let onCopy: (String) -> Void
  /// Window-owned close.
  let onClose: () -> Void

  @State private var question: String = ""
  @State private var task: FamoAIComposerTask?
  @State private var state: FamoAIConversationState = .idle
  /// 已完成的历史轮镜像（issue #137）。轮次只在 state 变化时增减，故与 state 同步刷新即可。
  @State private var turns: [FamoConversationTurn] = []
  @State private var didApplyInitialQuestion = false
  @FocusState private var inputFocused: Bool
  @Environment(\.colorScheme) private var colorScheme

  /// The active skin's resolved palette (荔园红 by default), light/dark-aware — the whole window is
  /// themed through it, not ad-hoc colors.
  private var palette: FamoCandidatePalette {
    FamoSkinPreferences.skin.theme.palette(for: colorScheme)
  }

  var body: some View {
    ZStack(alignment: .top) {
      palette.card.ignoresSafeArea()
      VStack(alignment: .leading, spacing: 12) {
        header
        contextQuote
        conversationFlow
        composer
        controlRow
      }
      // top inset clears the transparent titlebar's traffic lights.
      .padding(.top, 28)
      .padding(.horizontal, 22)
      .padding(.bottom, 16)
    }
    .frame(minWidth: 420, minHeight: 360)
    .onAppear {
      // Mirror the model's state into the view, and seed from the current state.
      state = model.state
      turns = model.turns
      model.onStateChange = { newState in
        DispatchQueue.main.async {
          state = newState
          turns = model.turns
        }
      }
      applyInitialQuestionIfNeeded()
      // 划词召唤的核心动线是「选中 → 出框 → 直接打指令」，焦点必须已经落在输入框里；
      // 异步一拍等窗口成 key 后再落焦（同步设在 makeKeyAndOrderFront 之前会被吞掉）。
      DispatchQueue.main.async { inputFocused = true }
    }
  }

  // MARK: - Header (kicker + serif title + route seal + accent rule)

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(NSLocalizedString("法墨", comment: "AI window kicker"))
            .font(.system(size: 10, weight: .bold))
            .tracking(3)
            .foregroundColor(palette.ink3)
          Text(NSLocalizedString("AI 对话", comment: "AI window title"))
            .font(Font.famoSerif(size: 20, weight: .bold))
            .foregroundColor(palette.accent)
        }
        Spacer()
        routeSeal
      }
      RoundedRectangle(cornerRadius: 1)
        .fill(palette.accent)
        .frame(width: 40, height: 2)
    }
  }

  /// Editorial route chip — a bordered "seal" rather than a filled badge. Once an answer has been
  /// routed through 联网搜索 it names the 联网模型 that answered (「联网 · 通义千问」), so the user can
  /// tell a live-searched answer from a training-cutoff one.
  private var routeSeal: some View {
    let (label, color): (String, Color)
    if let attribution = model.searchAttribution {
      label = String(
        format: NSLocalizedString("联网 · %@", comment: "web-search route badge with provider name"),
        attribution)
      color = palette.accent
    } else {
      switch model.currentReadiness() {
      case .ready:
        label = NSLocalizedString("云端", comment: "cloud route badge")
        color = palette.accent
      case .missingKey:
        label = NSLocalizedString("缺少密钥", comment: "missing key badge")
        color = .orange
      case .unconfigured:
        label = NSLocalizedString("未配置", comment: "unconfigured badge")
        color = palette.ink3
      }
    }
    return Text(label)
      .font(.system(size: 10, weight: .semibold))
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .foregroundColor(color)
      .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
  }

  // MARK: - Captured context (pull-quote)

  @ViewBuilder private var contextQuote: some View {
    if !model.capturedContextSummary.isEmpty {
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1)
          .fill(palette.accent)
          .frame(width: 3)
        Text(model.capturedContextSummary)
          .font(Font.famoSerif(size: 11))
          .italic()
          .foregroundColor(palette.ink2)
          .lineLimit(2)
          .truncationMode(.middle)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Conversation flow (question bubbles ↔ typeset serif answers)

  private var conversationFlow: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
            questionBubble(turn.displayText)
            answerBlock(turn.answer)
          }
          switch state {
          case .idle:
            // 已经聊过就别再劝人开口——空白提示只在真正空白时出现。带选区时教「下指令」用法。
            if turns.isEmpty {
              placeholder(hasSelection
                ? NSLocalizedString("对选中文本下指令：改写、排版、翻译、拟回复…也可以直接提问。", comment: "idle placeholder with selection")
                : NSLocalizedString("问点什么？答案会带上你此刻的上下文。", comment: "idle placeholder"))
            }
          case let .streaming(partial):
            questionBubble(model.lastDisplayQuestion ?? model.lastQuestion)
            answerBlock(partial.isEmpty ? NSLocalizedString("正在生成…", comment: "streaming") : partial)
          case .done:
            // 完成的这一轮已经在上面的历史里了，再渲染一次就是重影。
            EmptyView()
          case let .failed(message):
            placeholder(message, isError: true)
          case .unconfigured:
            placeholder(NSLocalizedString("尚未配置 AI 供应商，请在设置中添加。", comment: "unconfigured body"), isError: true)
          }
          Color.clear.frame(height: 1).id("famo-ai-bottom")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
      }
      .frame(maxHeight: .infinity)
      .onChange(of: state) {
        proxy.scrollTo("famo-ai-bottom", anchor: .bottom)
      }
    }
  }

  /// 用户的提问：右对齐小气泡（card2 底 + 细描边），和左侧的衬线答案在形态上一眼可分。
  @ViewBuilder private func questionBubble(_ text: String) -> some View {
    if !text.isEmpty {
      HStack {
        Spacer(minLength: 48)
        Text(text)
          .font(.system(size: 12.5))
          .foregroundColor(palette.ink)
          .textSelection(.enabled)
          .padding(.horizontal, 11)
          .padding(.vertical, 7)
          .background(RoundedRectangle(cornerRadius: 10).fill(palette.card2))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.ink3.opacity(0.2), lineWidth: 1))
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  /// 答案正文：衬线排版 + 主题色引线，与提问气泡、composer 卡都区隔开。
  private func answerBlock(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: 1)
        .fill(palette.accent.opacity(0.55))
        .frame(width: 2)
      Text(text)
        .font(Font.famoSerif(size: 14, weight: .regular))
        .lineSpacing(6)
        .foregroundColor(palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func placeholder(_ text: String, isError: Bool = false) -> some View {
    Text(text)
      .font(Font.famoSerif(size: 13, weight: .regular))
      .foregroundColor(isError ? .red : palette.ink3)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Composer (bordered card: optional task chip + growing multi-line field + send row)

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let task {
        taskHeader(task)
      }
      TextField(
        task?.placeholder
          ?? (hasSelection
            ? NSLocalizedString("对选中文本下指令，或提问…", comment: "question field placeholder with selection")
            : NSLocalizedString("向 AI 提问…", comment: "question field placeholder")),
        text: $question,
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .lineLimit(1...6)
      .font(Font.famoSerif(size: 14))
      .foregroundColor(palette.ink)
      .focused($inputFocused)
      .onSubmit(submit)
      HStack {
        Text(NSLocalizedString("⌥⏎ 换行", comment: "newline hint"))
          .font(.system(size: 10))
          .foregroundColor(palette.ink3.opacity(0.8))
        Spacer()
        Button(action: submit) {
          HStack(spacing: 4) {
            Text(NSLocalizedString("送出", comment: "send button"))
            Image(systemName: "return")
          }
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(canSend ? palette.accent : palette.ink3.opacity(0.6))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10).fill(palette.card2.opacity(0.6)))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          inputFocused ? palette.accent.opacity(0.9) : palette.ink3.opacity(0.35),
          lineWidth: inputFocused ? 1.5 : 1)
    )
  }

  /// 任务签：标题 + 逐条澄清问题 + 摘除钮。摘掉即退回普通提问（脚手架随之丢弃）。
  private func taskHeader(_ task: FamoAIComposerTask) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(task.label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(palette.accent)
        Spacer()
        Button {
          self.task = nil
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(palette.ink3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("移除任务", comment: "remove composer task"))
      }
      ForEach(task.clarifications, id: \.self) { clarification in
        Text("· \(clarification)")
          .font(.system(size: 11))
          .foregroundColor(palette.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Rectangle()
        .fill(palette.ink3.opacity(0.2))
        .frame(height: 1)
        .padding(.top, 2)
    }
  }

  private var controlRow: some View {
    HStack(spacing: 16) {
      quietButton(NSLocalizedString("复制", comment: "copy button"), enabled: currentAnswer != nil) {
        if let answer = currentAnswer { onCopy(answer) }
      }
      // 「复制粘贴回去」的一键动线：复制结果 + 关窗（关窗自动把焦点还给原 App），回去 ⌘V 即贴。
      quietButton(NSLocalizedString("复制并关闭", comment: "copy and close button"),
                  enabled: currentAnswer != nil) {
        guard let answer = currentAnswer else { return }
        onCopy(answer)
        onClose()
      }
      quietButton(NSLocalizedString("重新生成", comment: "regenerate button"),
                  enabled: !model.lastQuestion.isEmpty && !isStreaming) {
        model.regenerate()
      }
      quietButton(NSLocalizedString("停止", comment: "stop button"), enabled: isStreaming) {
        model.stop()
      }
      quietButton(NSLocalizedString("新对话", comment: "new conversation button"),
                  enabled: !turns.isEmpty && !isStreaming) {
        model.newConversation()
        state = model.state
        turns = model.turns
        question = ""
      }
      Spacer()
      quietButton(NSLocalizedString("关闭", comment: "close button"), enabled: true, action: onClose)
        .keyboardShortcut(.cancelAction)
    }
  }

  /// Quiet text button (editorial): no bordered chrome, just ink2 text that dims when disabled.
  private func quietButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 12, weight: .medium))
    }
    .buttonStyle(.plain)
    .foregroundColor(enabled ? palette.ink2 : palette.ink3.opacity(0.5))
    .disabled(!enabled)
  }

  // MARK: - Helpers

  /// 窗口是否由划词入口带着明确选区打开（决定占位文案教不教「下指令」用法）。
  private var hasSelection: Bool {
    !model.capturedContextSummary.isEmpty
  }

  private var isStreaming: Bool {
    if case .streaming = state { return true }
    return false
  }

  private var canSend: Bool {
    !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
  }

  /// The answer currently available to copy (a finished answer, or a non-empty partial mid-stream).
  private var currentAnswer: String? {
    switch state {
    case let .done(answer): return answer.isEmpty ? nil : answer
    case let .streaming(partial): return partial.isEmpty ? nil : partial
    default: return nil
    }
  }

  private func applyInitialQuestionIfNeeded() {
    guard !didApplyInitialQuestion else { return }
    didApplyInitialQuestion = true
    task = initialTask
    let initial = initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !initial.isEmpty else { return }
    if autoSubmit {
      // autoSubmit 技能的完整指令不进输入框（也不该在送出后留在框里）；气泡用短署名。
      model.submit(question: initial, displayQuestion: initialDisplayQuestion)
    } else {
      question = initial
    }
  }

  private func submit() {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let task {
      // 任务卡：真正提交的是 scaffold + 用户补充；气泡展示「任务名：补充」。任务是一次性的，
      // 送出即摘（后续追问不再重复携带脚手架）。
      model.submit(
        question: task.scaffold + trimmed,
        displayQuestion: "\(task.label)：\(trimmed)")
      self.task = nil
    } else {
      model.submit(question: trimmed)
    }
    question = ""
  }
}
