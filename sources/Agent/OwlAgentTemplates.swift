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
    library.entries.filter { $0.isExposedToAgents && !$0.isPendingReview && $0.executionIssue == nil }
  }

  static func find(_ id: String, in library: OwlTemplateLibrary) -> OwlTemplateEntry? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return exposed(library).first { $0.id == uuid }
  }

  static func summary(_ entry: OwlTemplateEntry) -> Wire.TemplateSummary {
    let parsed = OwlTemplateEngine.parse(entry)
    return .init(id: entry.id.uuidString, title: entry.title, parameters: parameters(parsed), requirements: requirements(parsed))
  }

  static func detail(_ entry: OwlTemplateEntry) -> Wire.Template {
    let parsed = OwlTemplateEngine.parse(entry)
    return .init(id: entry.id.uuidString, title: entry.title, body: entry.body,
                 parameters: parameters(parsed), requirements: requirements(parsed))
  }

  /// A preview; unknown argument keys are refused so a typo is not silently ignored.
  static func render(_ entry: OwlTemplateEntry, arguments: [String: String], now: Date = Date()) -> Result<Wire.Render, Wire.ErrorObject> {
    let parsed = OwlTemplateEngine.parse(entry)
    let known = Set(parsed.parameters.map(\.key))
    if let unknown = arguments.keys.sorted().first(where: { !known.contains($0) }) {
      return .failure(.init(code: .invalidParams, message: "Unknown template argument \(unknown)", data: .init(field: "arguments")))
    }
    let context = OwlTemplateContextCapture.capture(parsed.contextRequirements, readClipboard: { "" }, now: { now })
    let values = parsed.initialValues.merging(arguments) { _, argument in argument }
    let evaluation = OwlTemplateEngine.render(parsed, values: values, context: context,
                                              decisions: .init(allowEmptyClipboard: true))
    var diagnostics = evaluation.diagnostics.map {
      Wire.Diagnostic(severity: $0.severity == .error ? .error : .warning, message: $0.message)
    }
    if parsed.contextRequirements.contains(.clipboard) {
      diagnostics.append(.init(severity: .warning, message: "剪贴板内容不会提供给 Agent，预览中留空。"))
    }
    return .success(.init(previewText: evaluation.previewText, cursorOffset: evaluation.cursorOffset,
                          missingKeys: evaluation.missingKeys, diagnostics: diagnostics))
  }

  private static func parameters(_ parsed: OwlTemplateEngine.Parsed) -> [Wire.Parameter] {
    parsed.parameters.map {
      .init(key: $0.key, name: $0.name, isRequired: $0.isRequired, defaultValue: $0.defaultValue, options: $0.options)
    }
  }

  private static func requirements(_ parsed: OwlTemplateEngine.Parsed) -> [Wire.Requirement] {
    var result: [Wire.Requirement] = []
    if parsed.contextRequirements.contains(.clipboard) { result.append(.clipboard) }
    if parsed.contextRequirements.contains(.temporal) { result.append(.date) }
    return result
  }
}
