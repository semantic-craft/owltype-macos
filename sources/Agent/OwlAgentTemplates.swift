//
//  OwlAgentTemplates.swift
//  Owltype
//
//  What agents see of the template library (#208): only entries the user exposed, ready to use
//  (no pending review, no parse error). Rendering never reads the pasteboard: a clipboard field
//  previews empty, with a warning, and a date field uses the time of the call.
//

import Foundation

enum OwlAgentTemplates {
  typealias Wire = OwlAgentBridgeProtocol

  static func exposed(_ library: OwlTemplateLibrary) -> [OwlTemplateEntry] {
    let entriesPayload: [[String: Any]] = library.entries.map { entry in
      [
        "id": entry.id.uuidString,
        "is_exposed": entry.isExposedToAgents,
        "is_pending_review": entry.isPendingReview,
        "execution_issue": entry.executionIssue != nil ? "\(entry.executionIssue!)" : NSNull()
      ]
    }
    let exposedIDs: [String] = OwlAppCore.required([
      "operation": "agent_rule",
      "rule": "templates_filter_exposed",
      "args": ["entries": entriesPayload]
    ])
    let idSet = Set(exposedIDs.compactMap(UUID.init(uuidString:)))
    return library.entries.filter { idSet.contains($0.id) }
  }

  static func find(_ id: String, in library: OwlTemplateLibrary) -> OwlTemplateEntry? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return exposed(library).first { $0.id == uuid }
  }

  static func summary(_ entry: OwlTemplateEntry) -> Wire.TemplateSummary {
    OwlAppCore.required([
      "operation": "agent_rule",
      "rule": "template_summary",
      "args": [
        "id": entry.id.uuidString,
        "title": entry.title,
        "body": entry.body
      ]
    ])
  }

  static func detail(_ entry: OwlTemplateEntry) -> Wire.Template {
    OwlAppCore.required([
      "operation": "agent_rule",
      "rule": "template_detail",
      "args": [
        "id": entry.id.uuidString,
        "title": entry.title,
        "body": entry.body
      ]
    ])
  }

  /// A preview; unknown argument keys are refused so a typo is not silently ignored.
  static func render(_ entry: OwlTemplateEntry, arguments: [String: String], now: Date = Date()) -> Result<Wire.Render, Wire.ErrorObject> {
    let parsed = OwlTemplateEngine.parse(entry)
    let context = OwlTemplateContextCapture.capture(parsed.contextRequirements, readClipboard: { "" }, now: { now })
    let facts = OwlTemplateEngine.contextFacts(parsed, context: context)
    let args: [String: Any] = [
      "entry": [
        "id": entry.id.uuidString,
        "title": entry.title,
        "body": entry.body
      ],
      "arguments": arguments,
      "temporal": facts["temporal"] as Any? ?? [:]
    ]
    do {
      let render: Wire.Render = try OwlAppCore.call([
        "operation": "agent_rule",
        "rule": "template_render",
        "args": args
      ])
      return .success(render)
    } catch let failure as OwlAppCore.Failure {
      if failure.code.hasPrefix("unknown_argument:") {
        let arg = String(failure.code.dropFirst("unknown_argument:".count))
        return .failure(Wire.ErrorObject(code: .invalidParams, message: "Unknown template argument \(arg)", data: .init(field: "arguments")))
      }
      return .failure(Wire.ErrorObject(code: .invalidParams, message: failure.code, data: .init(field: "arguments")))
    } catch {
      return .failure(Wire.ErrorObject(code: .internalError, message: "The template could not be rendered"))
    }
  }
}
