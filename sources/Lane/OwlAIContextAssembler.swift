//
//  OwlAIContextAssembler.swift
//  法墨输入法 (Owltype) — AI conversation request assembler
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

  static func selectionSummary(_ selectedText: String?) -> String {
    OwlAIBusinessCore.call("selectionSummary", ["text": selectedText as Any? ?? NSNull()])
  }

}

/// Native JSON transport only; Rust owns prompts, admission, limits and state transitions.
enum OwlAIBusinessCore {
  static func call<T: Decodable>(_ rule: String, _ args: [String: Any] = [:]) -> T {
    OwlAppCore.required(["operation": "ai_rule", "rule": rule, "args": args])
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
    session.call(event, args)
  }
}
