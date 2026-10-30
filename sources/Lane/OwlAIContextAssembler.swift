//
//  OwlAIContextAssembler.swift
//  猫头鹰输入法 (Owltype) — AI conversation request assembler
//
//  Privacy boundary: this pure assembler can receive only text the user explicitly submitted:
//  the current question, an explicit selection, and prior conversation turns. Composition state,
//  candidates, surrounding text, window metadata, and screen contents are deliberately absent
//  from the API, so callers cannot accidentally attach them to a cloud request.
//

import Foundation

/// 一轮已完成的问答，喂回后续请求作对话历史（issue #137）。
struct OwlConversationTurn: Codable, Equatable, Sendable {
  let question: String
  let answer: String
  /// 气泡展示用的短文本（任务卡藏起 scaffold 时是「任务名：用户补充」）。nil = 展示 `question`
  /// 全文。历史回喂模型时永远用 `question`——此字段只影响窗口里的显示。
  var displayQuestion: String? = nil

  /// 窗口气泡实际显示的文本。
  var displayText: String { displayQuestion ?? question }
}

/// Builds the chat messages for one AI-window turn from explicit user content only.
enum OwlAIContextAssembler {

  struct Submission: Decodable {
    let accepted: Bool
    let question: String
    let displayQuestion: String?
  }
  static func submission(_ text: String, scaffold: String? = nil, label: String? = nil) -> Submission {
    OwlAIBusinessCore.call("composer", ["text": text, "scaffold": scaffold as Any? ?? NSNull(),
      "label": label as Any? ?? NSNull()])
  }

  /// Explicit selections are bounded before being added to a chat request. 与划词入口的选区闸
  /// （`isAllowedSelection` ≤ `OwlSelectionPolish.maxSelectionLength`）对齐：旧值 400 会把菜单
  /// 放行的长选区静默截残，「对选中文本下指令加工」（排版/改引号/扩写）就会只改到前 400 字。
  static let selectedTextCharCap = OwlSelectionPolish.maxSelectionLength

  static let systemPrompt: String = OwlAIBusinessCore.call("prompt", ["id": "context"])

  /// Assemble `[system, (explicit selection), history..., user]`.
  static func assemble(
    selectedText: String? = nil,
    history: [OwlConversationTurn] = [],
    question: String
  ) -> [OwlDeepSeekMessage] {
    OwlAIBusinessCore.call("context", ["selectedText": selectedText as Any? ?? NSNull(),
      "history": OwlAIBusinessCore.json(history), "question": question])
  }

  static func selectionSummary(_ selectedText: String?) -> String {
    OwlAIBusinessCore.call("selectionSummary", ["text": selectedText as Any? ?? NSNull()])
  }

  /// 选中文本的加工出口规则。跟着选区走（拼在选区 system 消息里、置于不可信文本之后），无选区的
  /// 纯提问完全不受影响。核心约定：凡是「对选中文本加工」的指令（替换/改写/润色/扩写/排版/翻译/
  /// 拟回复…），只输出加工结果本身——窗口的「复制」抓的是整段回答，多一句解释就没法直接粘贴回去。
  static let selectionProcessingRule: String = OwlAIBusinessCore.call("prompt", ["id": "selectionProcessing"])

}

/// Native JSON transport only; Rust owns prompts, admission, limits and state transitions.
enum OwlAIBusinessCore {
  static func call<T: Decodable>(_ rule: String, _ args: [String: Any] = [:]) -> T {
    let snapshot = try! OwlAppSession("aiRule", args: ["rule": rule, "args": args])
    return snapshot.call("evaluate")
  }
  static func json<T: Encodable>(_ value: T) -> Any {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }
}

/// User/model text is an owned snapshot, like template library snapshots. A small event borrows
/// it for one synchronous transition; the common 4 MiB control-event bound is not a text limit.
final class OwlAITextSession {
  private let session: OwlAppSession
  init(_ kind: String, args: Any = NSNull()) throws { session = try OwlAppSession(kind, args: args) }
  func call<T: Decodable>(_ event: String, _ args: [String: Any] = [:]) -> T {
    let packet = try! OwlAppSession("aiText", args: ["event": event, "args": args])
    return session.call("ai_text_event", index: packet)
  }
}
