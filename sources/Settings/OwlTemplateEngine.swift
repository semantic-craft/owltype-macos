import Foundation

/// Native DTO and Foundation service adapter for the Rust template engine.
enum OwlTemplateEngine {
  enum Severity: String, Codable, Equatable { case warning, error }
  struct Diagnostic: Codable, Equatable {
    let severity: Severity
    let range: NSRange
    let message: String
    func location(in body: String) -> String {
      (try? OwlAppCore.call(["operation": "template_location", "body": body,
                            "location": range.location])) ?? "位置无法读取"
    }
  }
  enum Requirement: String, Codable, Hashable { case clipboard, temporal }
  enum Clipboard: Equatable { case notRequested, text(String), empty, nonText }
  struct Temporal {
    let date: Date
    let timeZone: TimeZone
    let locale: Locale
    let calendar: Calendar
    let defaultPatterns: [TemporalKind: String]

    init(date: Date, timeZone: TimeZone, locale: Locale, calendar: Calendar) {
      self.date = date
      self.timeZone = timeZone
      self.locale = locale
      var frozenCalendar = calendar
      let firstWeekday = calendar.firstWeekday
      let minimumDays = calendar.minimumDaysInFirstWeek
      frozenCalendar.locale = locale
      frozenCalendar.timeZone = timeZone
      frozenCalendar.firstWeekday = firstWeekday
      frozenCalendar.minimumDaysInFirstWeek = minimumDays
      self.calendar = frozenCalendar
      // Resolve locale styles once, including the user's current hour-cycle preferences.
      var patterns: [TemporalKind: String] = [:]
      for kind in TemporalKind.allCases {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = frozenCalendar
        formatter.timeZone = timeZone
        formatter.dateStyle = kind == .time ? .none : .medium
        formatter.timeStyle = kind == .date ? .none : .short
        patterns[kind] = formatter.dateFormat
      }
      defaultPatterns = patterns
    }
  }
  enum TemporalKind: String, Codable, CaseIterable { case date, time, datetime }
  struct TemporalOffset: Codable, Equatable {
    let component: Calendar.Component
    let value: Int
  }
  struct TemporalField: Codable, Equatable {
    let kind: TemporalKind
    let format: String?
    let offsets: [TemporalOffset]
  }
  /// Captured by the invocation, never by parse/render. #166/#167 supply concrete providers.
  struct FrozenContext {
    var clipboard: Clipboard = .notRequested
    var temporal: Temporal?
  }
  struct Decisions { var allowEmptyClipboard = false }
  enum Kind: Codable, Equatable {
    case literal
    case parameter(String)
    case clipboard
    case temporal(TemporalField)
    case cursor
  }
  struct Token: Codable, Equatable {
    let raw: String
    let range: NSRange
    let kind: Kind
  }
  struct Parameter: Codable, Identifiable, Equatable {
    let key: String
    var name: String
    var isRequired: Bool
    var defaultValue: String?
    var options: [String]
    var legacy: Bool
    var ranges: [NSRange]
    var id: String { key }
  }
  struct Parsed: Codable {
    var tokens: [Token] = []
    var parameters: [Parameter] = []
    var diagnostics: [Diagnostic] = []
    var contextRequirements: Set<Requirement> = []
    var initialValues: [String: String] = [:]
  }

  struct Evaluation: Codable {
    let previewText: String
    let diagnostics: [Diagnostic]
    let missingKeys: [String]
    var needsEmptyClipboardDecision = false
    var cursorOffset: Int? = nil
    var readyText: String? {
      let ready: Bool = (try? OwlAppCore.call(["operation": "template_ready", "evaluation": OwlAppCore.payload(self)])) ?? false
      return ready ? previewText : nil
    }
  }

  // User-authored payloads can exceed the bounded ABI. Surface a blocked domain result;
  // never use required(), whose precondition is reserved for internal ABI invariants.
  private static let transportMessage = "模板数据超出处理范围或无法读取，请缩短内容后重试。"
  private static func failure(_ range: NSRange = .init(location: 0, length: 0)) -> Diagnostic {
    .init(severity: .error, range: range, message: transportMessage)
  }
  static func parse(_ entry: OwlTemplateEntry) -> Parsed {
    parse(body: entry.body, bodyType: entry.bodyType, syntax: entry.syntax,
          definitions: entry.parameters, pending: entry.isPendingReview)
  }
  static func parse(body: String, bodyType: OwlTemplateEntry.BodyType = .template,
                    syntax: OwlTemplateEntry.Syntax = .standard,
                    definitions: [OwlTemplateParameter] = []) -> Parsed {
    parse(body: body, bodyType: bodyType, syntax: syntax, definitions: definitions, pending: false)
  }
  private static func parse(body: String, bodyType: OwlTemplateEntry.BodyType,
                            syntax: OwlTemplateEntry.Syntax, definitions: [OwlTemplateParameter], pending: Bool) -> Parsed {
    do {
      return try OwlAppCore.call(["operation": "template_parse", "body": body,
        "plain": bodyType != .template, "legacy": syntax == .legacyDoubleBraces, "pending": pending,
        "definitions": OwlAppCore.payload(definitions)])
    } catch {
      let range = NSRange(location: 0, length: body.utf16.count)
      return Parsed(tokens: [.init(raw: body, range: range, kind: .literal)], diagnostics: [failure(range)])
    }
  }
  static func render(_ parsed: Parsed, values: [String: String], context: FrozenContext = .init(),
                     decisions: Decisions = .init()) -> Evaluation {
    var facts: [String: Any] = [:]
    if let temporal = context.temporal {
      for (index, token) in parsed.tokens.enumerated() {
        if case .temporal(let field) = token.kind {
          do { facts[String(index)] = try nativeDate(field, context: temporal) }
          catch { facts[String(index)] = ["error": transportMessage] }
        }
      }
    }
    let clipboard: String
    var clipboardText: String?
    switch context.clipboard {
    case .notRequested: clipboard = "notRequested"
    case .empty: clipboard = "empty"
    case .nonText: clipboard = "nonText"
    case .text(let text): clipboard = "text"; clipboardText = text
    }
    do {
      return try OwlAppCore.call(["operation": "template_render", "parsed": OwlAppCore.payload(parsed),
        "values": values, "clipboard": clipboard, "clipboard_text": clipboardText as Any? ?? NSNull(),
        "allow_empty": decisions.allowEmptyClipboard, "temporal": facts])
    } catch {
      return Evaluation(previewText: parsed.tokens.map(\.raw).joined(),
        diagnostics: parsed.diagnostics + [failure()], missingKeys: [])
    }
  }
  static func quoted(_ value: String) -> String {
    // Quoting cannot fail for input size: use the same Rust escaping operation in bounded chunks.
    // A string literal is escaped scalarly, so chunks do not alter its grammar.
    var result = "\""
    var chunk = ""
    func appendChunk() {
      let quoted: String = OwlAppCore.required(["operation": "template_quoted", "value": chunk])
      result += String(String.UnicodeScalarView(quoted.unicodeScalars.dropFirst().dropLast()))
      chunk = ""
    }
    for scalar in value.unicodeScalars {
      chunk.unicodeScalars.append(scalar)
      if chunk.utf8.count >= 65536 { appendChunk() }
    }
    if !chunk.isEmpty { appendChunk() }
    return result + "\""
  }

  private struct DatePart: Decodable { let symbol: String?; let count: Int }
  private struct DatePlan: Decodable {
    let error: String?
    let pattern: String?
    let parts: [DatePart]
  }
  private struct OffsetResult: Decodable { let error: String? }
  private static func number(_ date: Date?) -> Any {
    guard let value = date?.timeIntervalSinceReferenceDate, value.isFinite else { return NSNull() }
    return value
  }
  /// Execute explicit arithmetic/formatting requests against the frozen native services.
  /// Rust validates dates, selects/validates patterns, and constructs the final week pattern.
  private static func nativeDate(_ field: TemporalField, context: Temporal) throws -> [String: String] {
    let plan: DatePlan = try OwlAppCore.call(["operation": "template_date_plan", "field": OwlAppCore.payload(field),
      "default_pattern": context.defaultPatterns[field.kind] as Any? ?? NSNull(), "date": number(context.date)])
    if let error = plan.error { return ["error": error] }
    var date = context.date
    for offset in field.offsets {
      let next = context.calendar.date(byAdding: offset.component, value: offset.value, to: date, wrappingComponents: false)
      let result: OffsetResult = try OwlAppCore.call(["operation": "template_date_offset", "current": number(date),
        "next": number(next), "value": offset.value])
      if let error = result.error { return ["error": error] }
      guard let next else { throw OwlAppCore.Failure(code: "missing_calendar_fact") }
      date = next
    }
    var weekValues: [String] = []
    for part in plan.parts {
      let format: Date.FormatString
      switch part.symbol {
      case "Y": format = "\(yearForWeekOfYear: part.count == 2 ? .twoDigits : .padded(part.count))"
      case "w": format = "\(week: part.count == 2 ? .twoDigits : .defaultDigits)"
      case "W": format = "\(week: .weekOfMonth)"
      case "e": format = "\(weekday: part.count == 2 ? .twoDigits : .oneDigit)"
      case "c": format = "\(standaloneWeekday: .oneDigit)"
      default: throw OwlAppCore.Failure(code: "invalid_calendar_request")
      }
      weekValues.append(Date.VerbatimFormatStyle(format: format, locale: context.locale,
        timeZone: context.timeZone, calendar: context.calendar).format(date))
    }
    let final: DatePlan = try OwlAppCore.call(["operation": "template_date_pattern", "pattern": plan.pattern ?? "", "values": weekValues])
    if let error = final.error { return ["error": error] }
    let formatter = DateFormatter()
    formatter.locale = context.locale
    formatter.calendar = context.calendar
    formatter.timeZone = context.timeZone
    formatter.dateFormat = final.pattern
    return ["text": formatter.string(from: date)]
  }
}

extension OwlTemplateEngine.TemporalOffset {
  private enum CodingKeys: String, CodingKey { case component, value }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(String.self, forKey: .component)
    guard let component = Self.components[name] else { throw OwlAppCore.Failure(code: "invalid_calendar_component") }
    self.component = component
    value = try container.decode(Int.self, forKey: .value)
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.components.first { $0.value == component }?.key, forKey: .component)
    try container.encode(value, forKey: .value)
  }
  private static let components: [String: Calendar.Component] = ["minute": .minute, "hour": .hour, "day": .day, "month": .month, "year": .year]
}

extension OwlTemplateEngine.Kind {
  private enum CodingKeys: String, CodingKey { case type, value }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "literal": self = .literal
    case "parameter": self = .parameter(try container.decode(String.self, forKey: .value))
    case "clipboard": self = .clipboard
    case "temporal": self = .temporal(try container.decode(OwlTemplateEngine.TemporalField.self, forKey: .value))
    case "cursor": self = .cursor
    default: throw OwlAppCore.Failure(code: "invalid_template_token")
    }
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let type: String
    switch self {
    case .literal: type = "literal"
    case .parameter(let value): type = "parameter"; try container.encode(value, forKey: .value)
    case .clipboard: type = "clipboard"
    case .temporal(let value): type = "temporal"; try container.encode(value, forKey: .value)
    case .cursor: type = "cursor"
    }
    try container.encode(type, forKey: .type)
  }
}
