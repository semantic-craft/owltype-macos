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
    struct Step: Decodable {
      let action: String
      let generation: UInt64
      let text: String
      let task: OwlAIComposerTask?
      let message: String?
      let noun: String
    }
    let core = try! OwlAITextSession("selectionRewrite", args: ["action": action.rawValue])
    var step: Step = core.call("next")
    while true {
      if let message = step.message { notify(message) }
      do {
        try Task.checkCancellation()
        switch step.action {
        case "generate":
          let result = try await generate(action, text)
          try Task.checkCancellation()
          var args: [String: Any] = ["generation": step.generation]
          switch result {
          case .empty: args["kind"] = "empty"
          case let .ready(value): args["kind"] = "ready"; args["text"] = value
          case let .clarification(task): args["kind"] = "clarification"; args["task"] = OwlAIBusinessCore.json(task)
          }
          step = core.call("generated", args)
        case "confirm": step = core.call("confirmed", ["generation": step.generation, "confirmed": confirm(step.text, step.noun)])
        case "deliver":
          var args: [String: Any] = ["generation": step.generation]
          switch deliver(step.text) {
          case .inserted: args["kind"] = "inserted"
          case .copiedToClipboard: args["kind"] = "copied"
          case let .failed(message): args["kind"] = "failure"; args["message"] = message
          }
          step = core.call("delivered", args)
        case "clarify": clarify(text, step.task!); return
        default: return
        }
      } catch {
        if OwlLaneCancellation.isCancellation(error) { let _: Step = core.call("cancel"); return }
        step = core.call("failure", ["generation": step.generation, "message": Self.message(for: error, action: action)])
      }
    }
  }

  static func generate(_ action: OwlSelectionMenuAction, text: String) async throws -> Generation {
    switch action {
    case .polish:
      let rewrites = try await NSApp.owlAppDelegate.selectionPolish.polishSelection(text)
      struct Reply: Decodable { let text: String? }
      let reply: Reply = OwlAIBusinessCore.call("firstRewrite", ["values": rewrites])
      return reply.text.map(Generation.ready) ?? .empty
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

}
