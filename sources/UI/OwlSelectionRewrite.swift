import AppKit

/// One selected-text rewrite, from generation through the user's decision to delivery.
/// UI and model adapters vary; the confirmation/clarification/delivery rules do not.
@MainActor
struct OwlSelectionRewrite {
  enum Generation {
    case ready(String)
    case clarification(OwlAIComposerTask)
    case empty
  }

  let generate: (OwlSelectionMenuAction, String) async throws -> Generation
  let confirm: (String, String) -> Bool
  let deliver: (String) -> OwlInsertOutcome
  let clarify: (String, OwlAIComposerTask) -> Void
  let notify: (String) -> Void

  func run(_ action: OwlSelectionMenuAction, text: String) async {
    let copy = Self.copy(for: action)
    notify(copy.progress)
    do {
      try Task.checkCancellation()
      let generation = try await generate(action, text)
      try Task.checkCancellation()
      switch generation {
      case .empty:
        notify("未生成改写")
      case .clarification(let task):
        clarify(text, task)
      case .ready(let replacement):
        guard confirm(replacement, copy.noun) else {
          notify("已取消替换。")
          return
        }
        try Task.checkCancellation()
        switch deliver(replacement) {
        case .inserted: notify(copy.inserted)
        case .copiedToClipboard: notify(copy.copied)
        case .failed(let message): notify(message)
        }
      }
    } catch {
      if OwlLaneCancellation.isCancellation(error) { return }
      notify(Self.message(for: error, action: action))
    }
  }

  static func generate(_ action: OwlSelectionMenuAction, text: String) async throws -> Generation {
    switch action {
    case .polish:
      let rewrites = try await NSApp.owlAppDelegate.selectionPolish.polishSelection(text)
      return rewrites.first.map(Generation.ready) ?? .empty
    case .promptOptimize:
      switch try await OwlPromptOptimizeService.shared.optimize(text) {
      case .ready(let prompt): return .ready(prompt)
      case .needsClarification(let questions):
        return .clarification(OwlAIComposerTask(
          label: "提示词优化 — 补充信息", clarifications: questions,
          placeholder: "逐条补答，多条用 / 分隔",
          scaffold: OwlSelectionSkillPrompts.promptOptimizeClarificationScaffold(questions)))
      }
    case .goalBrief:
      switch try await OwlGoalBriefService.shared.compose(text) {
      case .ready(let brief): return .ready(brief)
      case .needsClarification(let questions):
        return .clarification(OwlAIComposerTask(
          label: "任务书 — 补充信息", clarifications: questions,
          placeholder: "逐条补答，多条用 / 分隔",
          scaffold: OwlSelectionSkillPrompts.goalBriefClarificationScaffold(questions)))
      }
    case .publishFormatting:
      return .ready(try await OwlSelectionPublishFormatter().generateReplacement(for: text))
    default:
      preconditionFailure("Only selected-text rewrite actions belong to this module")
    }
  }

  private static func message(for error: Error, action: OwlSelectionMenuAction) -> String {
    if let error = error as? OwlSelectionPolishError { return error.userMessage }
    if let error = error as? OwlPromptOptimizeError { return error.userMessage }
    if let error = error as? OwlGoalBriefError { return error.userMessage }
    if action == .publishFormatting { return OwlSelectionPublishFormatter.message(for: error) }
    return OwlCloudPreferences.message(for: error)
  }

  private struct Copy {
    let noun: String
    let progress: String
    let inserted: String
    let copied: String
  }

  private static func copy(for action: OwlSelectionMenuAction) -> Copy {
    switch action {
    case .polish:
      return Copy(noun: "润色", progress: "正在润色…", inserted: "已替换选中文本。", copied: "已复制改写，⌘V 替换")
    case .promptOptimize:
      return Copy(noun: "提示词优化", progress: "正在优化提示词…", inserted: "已替换为优化后的提示词。", copied: "已复制优化结果，⌘V 替换")
    case .goalBrief:
      return Copy(noun: "任务书", progress: "正在整理任务书…", inserted: "已替换为整理后的任务书。", copied: "已复制任务书，⌘V 替换")
    case .publishFormatting:
      return Copy(noun: "规范排版", progress: "正在规范排版…", inserted: "已替换选中文本。", copied: "已复制排版，⌘V 替换")
    default:
      preconditionFailure("Only selected-text rewrite actions belong to this module")
    }
  }
}
