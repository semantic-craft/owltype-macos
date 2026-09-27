import Foundation

/// One local, pure parser/renderer for both syntax modes. Values are never parsed recursively.
enum OwlTemplateEngine {
  enum Severity: Equatable { case warning, error }
  struct Diagnostic: Equatable {
    let severity: Severity
    let range: NSRange
    let message: String
    func location(in body: String) -> String {
      let source = body as NSString
      let prefix = source.substring(to: min(range.location, source.length))
      let lines = prefix.components(separatedBy: "\n")
      return "第 \(lines.count) 行、第 \((lines.last ?? "").count + 1) 列"
    }
  }
  enum Requirement: Hashable { case clipboard, temporal }
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
  enum TemporalKind: String, CaseIterable { case date, time, datetime }
  struct TemporalOffset: Equatable {
    let component: Calendar.Component
    let value: Int
  }
  struct TemporalField: Equatable {
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
  enum Kind: Equatable {
    case literal
    case parameter(String)
    case clipboard
    case temporal(TemporalField)
    case cursor
  }
  struct Token: Equatable {
    let raw: String
    let range: NSRange
    let kind: Kind
  }
  struct Parameter: Identifiable, Equatable {
    let key: String
    var name: String
    var isRequired: Bool
    var defaultValue: String?
    var options: [String]
    var legacy: Bool
    var ranges: [NSRange]
    var id: String { key }
  }
  struct Parsed {
    var tokens: [Token] = []
    var parameters: [Parameter] = []
    var diagnostics: [Diagnostic] = []
    var contextRequirements: Set<Requirement> = []
    var initialValues: [String: String] {
      var values: [String: String] = [:]
      for p in parameters {
        if let value = p.defaultValue { values[p.key] = value }
        else if p.legacy { values[p.key] = "" }
      }
      return values
    }
  }
  struct Evaluation {
    let previewText: String
    let diagnostics: [Diagnostic]
    let missingKeys: [String]
    var needsEmptyClipboardDecision = false
    var cursorOffset: Int? = nil
    var readyText: String? {
      !needsEmptyClipboardDecision && missingKeys.isEmpty && !diagnostics.contains { $0.severity == .error } ? previewText : nil
    }
  }

  static func parse(_ entry: OwlTemplateEntry) -> Parsed {
    if entry.isPendingReview {
      let range = NSRange(location: 0, length: (entry.body as NSString).length)
      return Parsed(tokens: [.init(raw: entry.body, range: range, kind: .literal)], parameters: [],
                    diagnostics: [.init(severity: .error, range: range, message: "导入条目待处理；请在设置中修正并启用，或明确转为普通文本。")],
                    contextRequirements: [])
    }
    return parse(body: entry.body, bodyType: entry.bodyType, syntax: entry.syntax, definitions: entry.parameters)
  }

  static func parse(body: String, bodyType: OwlTemplateEntry.BodyType = .template,
                    syntax: OwlTemplateEntry.Syntax = .standard,
                    definitions: [OwlTemplateParameter] = []) -> Parsed {
    let source = body as NSString
    var result = Parsed()
    func token(_ range: NSRange, _ kind: Kind) {
      guard range.length > 0 else { return }
      result.tokens.append(Token(raw: source.substring(with: range), range: range, kind: kind))
    }
    func issue(_ range: NSRange, _ message: String, _ severity: Severity = .error) {
      result.diagnostics.append(.init(severity: severity, range: range, message: message))
    }
    guard bodyType == .template else {
      token(NSRange(location: 0, length: source.length), .literal)
      return result
    }
    var anonymous = 0
    func parameter(_ name: String?, _ attributes: [String: String], _ range: NSRange, legacy: Bool) {
      let key: String
      let display: String
      if let name { key = "n:" + name; display = name }
      else { anonymous += 1; key = "a:\(anonymous)"; display = "参数 \(anonymous)" }
      let options = attributes["options"].map { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } } ?? []
      if options.contains("") { issue(range, "选项不能包含空项。") }
      var seen = Set<String>()
      let uniqueOptions = options.filter { seen.insert($0).inserted }
      let p = Parameter(key: key, name: display, isRequired: !legacy, defaultValue: attributes["default"], options: uniqueOptions, legacy: legacy, ranges: [range])
      if let index = result.parameters.firstIndex(where: { $0.key == key }) {
        var existing = result.parameters[index]
        if let value = p.defaultValue {
          if let previous = existing.defaultValue, previous != value { issue(range, "同名参数的默认值不一致。") }
          else { existing.defaultValue = value }
        }
        if !p.options.isEmpty {
          if !existing.options.isEmpty && existing.options != p.options { issue(range, "同名参数的选项不一致。") }
          else { existing.options = p.options }
        }
        if !legacy { existing.legacy = false; existing.isRequired = true }
        existing.ranges.append(range)
        result.parameters[index] = existing
      } else { result.parameters.append(p) }
      token(range, .parameter(key))
    }

    // Preserve the old regex's exact matching behavior, including empty and malformed literals.
    let legacyRE = try! NSRegularExpression(pattern: "\\{\\{(.*?)\\}\\}")
    let matches = legacyRE.matches(in: body, range: NSRange(location: 0, length: source.length))
    let legacyAt = Dictionary(uniqueKeysWithValues: matches.map { ($0.range.location, $0) })
    func parseKnownField(_ head: String, inside: String, range: NSRange) throws {
      let attributes = try readAttributes(String(inside.dropFirst(head.count)))
      let allowed: Set<String> = head == "argument" ? ["name", "default", "options"] : (["clipboard", "cursor"].contains(head) ? [] : ["format", "offset"])
      guard Set(attributes.keys).isSubset(of: allowed) else { throw ParseFailure.invalid("该字段含不支持的参数或修饰器。") }
      if head == "argument" {
        let name = attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "" { throw ParseFailure.invalid("参数名称不能为空；匿名参数请省略 name。") }
        parameter(name, attributes, range, legacy: false)
      } else if head == "cursor" {
        if result.tokens.contains(where: { $0.kind == .cursor }) { issue(range, "每条模板最多一个光标字段。") }
        token(range, .cursor)
      } else if head == "clipboard" {
        result.contextRequirements.insert(.clipboard)
        token(range, .clipboard)
      } else {
        guard let kind = TemporalKind(rawValue: head) else { throw ParseFailure.invalid("日期字段类型无效。") }
        let field = try readTemporal(kind, attributes: attributes)
        result.contextRequirements.insert(.temporal)
        token(range, .temporal(field))
      }
    }
    func scanStandard(_ start: Int, _ end: Int) {
      guard start < end else { return }
      if syntax == .legacyDoubleBraces { token(NSRange(location: start, length: end - start), .literal); return }
      var i = start
      var literalStart = start
      while i < end {
        guard source.character(at: i) == 123 else { i += 1; continue }
        if let match = legacyAt[i] {
          token(NSRange(location: literalStart, length: i - literalStart), .literal)
          let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
          if name.isEmpty { token(match.range, .literal) }
          else { parameter(name, [:], match.range, legacy: true) }
          i = NSMaxRange(match.range)
          literalStart = i
          continue
        }
        let fieldStart = i
        var j = i + 1
        var quoted = false
        var escaped = false
        while j < end {
          let c = source.character(at: j)
          if escaped { escaped = false }
          else if c == 92 && quoted { escaped = true }
          else if c == 34 { quoted.toggle() }
          else if c == 125 && !quoted { break }
          j += 1
        }
        let closed = j < end
        let fieldEnd = closed ? j + 1 : end
        let inside = source.substring(with: NSRange(location: i + 1, length: (closed ? j : end) - i - 1))
        let head = String(inside.prefix { $0.isLetter || $0 == "-" })
        let known = ["argument", "clipboard", "date", "time", "datetime", "cursor"].contains(head)
        token(NSRange(location: literalStart, length: fieldStart - literalStart), .literal)
        let range = NSRange(location: fieldStart, length: fieldEnd - fieldStart)
        if known {
          if !closed { issue(range, "字段缺少闭合花括号或引号。"); token(range, .literal) }
          else {
            do {
              try parseKnownField(head, inside: inside, range: range)
            } catch {
              issue(range, (error as? ParseFailure)?.message ?? "字段格式无效。")
              token(range, .literal)
            }
          }
        } else {
          token(range, .literal)
          // Isolated braces and code blocks stay literal; a field-like token gets a visible warning.
          if !head.isEmpty { issue(range, "未支持的字段将原样插入。", .warning) }
        }
        i = fieldEnd
        literalStart = i
      }
      token(NSRange(location: literalStart, length: end - literalStart), .literal)
    }
    if syntax == .legacyDoubleBraces {
      var cursor = 0
      for match in matches {
        token(NSRange(location: cursor, length: match.range.location - cursor), .literal)
        let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { token(match.range, .literal) }
        else { parameter(name, [:], match.range, legacy: true) }
        cursor = NSMaxRange(match.range)
      }
      token(NSRange(location: cursor, length: source.length - cursor), .literal)
    } else { scanStandard(0, source.length) }
    var defined = Set<String>()
    for definition in definitions {
      let key = definition.key
      guard defined.insert(key).inserted else { issue(NSRange(location: 0, length: 0), "参数定义重复。"); continue }
      guard let index = result.parameters.firstIndex(where: { $0.key == key }) else {
        issue(NSRange(location: 0, length: 0), "参数定义没有对应的正文位置，请删除过期设置。", .warning)
        continue
      }
      var p = result.parameters[index]
      let range = p.ranges[0]
      p.isRequired = definition.isRequired
      if let value = definition.defaultValue {
        if let inline = p.defaultValue, inline != value { issue(range, "正文与参数设置的默认值不一致。") }
        p.defaultValue = value
      }
      if !definition.options.isEmpty {
        if !p.options.isEmpty && p.options != definition.options { issue(range, "正文与参数设置的选项不一致。") }
        p.options = definition.options
      }
      result.parameters[index] = p
    }
    for p in result.parameters {
      if p.options.contains("") { issue(p.ranges[0], "选项不能包含空项。") }
      if let value = p.defaultValue, !p.options.isEmpty, !p.options.contains(value), !(value.isEmpty && !p.isRequired) {
        issue(p.ranges[0], "默认值必须属于预设选项。")
      }
    }
    if result.contextRequirements.isEmpty, result.parameters.isEmpty,
       result.tokens.contains(where: { $0.kind == .cursor }),
       !result.diagnostics.contains(where: { $0.severity == .error }) {
      result.diagnostics = render(result, values: [:]).diagnostics
    }
    return result
  }

  private enum ParseFailure: Error {
    case invalid(String)
    var message: String { switch self { case .invalid(let text): return text } }
  }
  private static func readAttributes(_ text: String) throws -> [String: String] {
    var rest = text[...]
    var attributes: [String: String] = [:]
    while !rest.isEmpty {
      guard rest.first?.isWhitespace == true else { throw ParseFailure.invalid("字段属性之间需要空格。") }
      rest = rest.drop(while: { $0.isWhitespace })
      if rest.isEmpty { break }
      let key = String(rest.prefix { $0.isLetter })
      guard !key.isEmpty else { throw ParseFailure.invalid("字段属性格式无效。") }
      rest = rest.dropFirst(key.count)
      guard rest.first == "=" else { throw ParseFailure.invalid("字段属性缺少等号。") }
      rest = rest.dropFirst()
      var value = ""
      if rest.first == "\"" {
        rest = rest.dropFirst()
        var closed = false
        while let c = rest.first {
          rest = rest.dropFirst()
          if c == "\"" { closed = true; break }
          if c == "\\" {
            guard let escaped = rest.first, escaped == "\\" || escaped == "\"" else { throw ParseFailure.invalid("不支持的字段转义。") }
            value.append(escaped); rest = rest.dropFirst()
          } else { value.append(c) }
        }
        guard closed else { throw ParseFailure.invalid("字段引号未闭合。") }
      } else {
        value = String(rest.prefix { !$0.isWhitespace })
        guard !value.isEmpty, !value.contains(where: { "{}\"\\|".contains($0) }) else { throw ParseFailure.invalid("字段属性值无效。") }
        rest = rest.dropFirst(value.count)
      }
      guard attributes[key] == nil else { throw ParseFailure.invalid("字段属性重复。") }
      attributes[key] = value
    }
    return attributes
  }

  private static func readTemporal(_ kind: TemporalKind, attributes: [String: String]) throws -> TemporalField {
    if let format = attributes["format"] { try validateDatePattern(format) }
    var offsets: [TemporalOffset] = []
    if let source = attributes["offset"] {
      let parts = source.split(whereSeparator: { $0.isWhitespace })
      guard !parts.isEmpty else { throw ParseFailure.invalid("日期偏移不能为空；无偏移请移除 offset。") }
      for part in parts {
        let number = part.dropLast()
        let digits = number.dropFirst()
        guard let sign = number.first, sign == "+" || sign == "-", !digits.isEmpty,
              digits.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(number) else {
          throw ParseFailure.invalid("日期偏移需使用 +2d 或 -30m，组合项之间用空格分隔。")
        }
        // Foundation's ICU backend narrows/clamps calendar amounts to Int32.
        // Reject before that conversion can silently change an authored offset.
        guard Int32(exactly: value) != nil else { throw ParseFailure.invalid("日期偏移数值超出支持范围。") }
        let component: Calendar.Component
        switch part.last {
        case "m": component = .minute
        case "h": component = .hour
        case "d": component = .day
        case "M": component = .month
        case "y": component = .year
        default: throw ParseFailure.invalid("日期偏移单位仅支持 m、h、d、M、y；m 是分钟，M 是月。")
        }
        offsets.append(.init(component: component, value: value))
      }
    }
    return TemporalField(kind: kind, format: attributes["format"], offsets: offsets)
  }

  private enum DatePatternPart {
    case literal(String)
    case field(Unicode.Scalar, Int)
  }

  private static func validateDatePattern(_ pattern: String) throws {
    _ = try datePatternParts(pattern)
  }

  /// One Unicode TR35 pattern scan for validation and week-field formatting.
  /// Literal quotes are decoded here, so inserted week numbers never alter quote boundaries.
  /// https://unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table
  private static func datePatternParts(_ pattern: String) throws -> [DatePatternPart] {
    guard !pattern.isEmpty else { throw ParseFailure.invalid("日期格式不能为空；默认格式请移除 format。") }
    let scalars = Array(pattern.unicodeScalars)
    var parts: [DatePatternPart] = []
    var literal = ""
    var quoted = false
    var i = 0
    while i < scalars.count {
      let scalar = scalars[i]
      if scalar == "'" {
        if i + 1 < scalars.count && scalars[i + 1] == "'" { literal += "'"; i += 2; continue }
        quoted.toggle()
        i += 1
        continue
      }
      guard !quoted, (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else {
        literal += String(scalar); i += 1; continue
      }
      if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
      var end = i + 1
      while end < scalars.count && scalars[end] == scalar { end += 1 }
      let count = end - i
      let valid: Bool
      switch scalar {
      case "y", "Y", "u", "r", "g", "S", "A": valid = true // variable numeric padding
      case "G", "U", "Q", "q", "M", "L", "a", "b", "B", "Z", "X", "x": valid = count <= 5
      case "E", "e", "c": valid = count <= 6
      case "w", "d", "h", "H", "K", "k", "m", "s": valid = count <= 2
      case "D": valid = count <= 3
      case "F", "W", "l": valid = count == 1 // l is deprecated but defined as ignored by TR35
      case "z", "V": valid = count <= 4
      case "O", "v": valid = count == 1 || count == 4
      case "j", "J", "C":
        throw ParseFailure.invalid("format 需要具体日期格式；j、J、C 是本地化格式骨架符号。")
      default:
        throw ParseFailure.invalid("日期格式含未定义字母；字面英文请放在单引号内。")
      }
      guard valid else { throw ParseFailure.invalid("日期格式字段的重复长度不受 Unicode 日期格式支持。") }
      parts.append(.field(scalar, count))
      i = end
    }
    guard !quoted else { throw ParseFailure.invalid("日期格式中的单引号未闭合。") }
    if !literal.isEmpty { parts.append(.literal(literal)) }
    return parts
  }

  /// Darwin DateFormatter keeps Calendar's identifier but formats week fields using locale
  /// defaults, even when calendar.firstWeekday/minimumDaysInFirstWeek read back correctly.
  /// VerbatimFormatStyle carries both week rules into ICU. Use that public Foundation API
  /// for numeric week fields; keep the remaining Unicode pattern and locale preferences.
  private static func patternWithFrozenWeekFields(_ pattern: String, date: Date, context: Temporal) throws -> String {
    let parts = try datePatternParts(pattern)
    guard parts.contains(where: {
      guard case .field(let symbol, let count) = $0 else { return false }
      return symbol == "Y" || symbol == "w" || symbol == "W" || ((symbol == "e" || symbol == "c") && count <= 2)
    }) else { return pattern }
    var result = ""
    var literal = ""
    func flushLiteral() {
      if !literal.isEmpty {
        let escaped = literal.replacingOccurrences(of: "'", with: "''")
        let needsQuotes = literal.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        result += needsQuotes ? "'" + escaped + "'" : escaped
        literal = ""
      }
    }
    for part in parts {
      switch part {
      case .literal(let text): literal += text
      case .field(let symbol, let count):
        let format: Date.FormatString?
        switch symbol {
        case "Y": format = "\(yearForWeekOfYear: count == 2 ? .twoDigits : .padded(count))"
        case "w": format = "\(week: count == 2 ? .twoDigits : .defaultDigits)"
        case "W": format = "\(week: .weekOfMonth)"
        case "e" where count <= 2: format = "\(weekday: count == 2 ? .twoDigits : .oneDigit)"
        case "c" where count <= 2: format = "\(standaloneWeekday: .oneDigit)"
        default: format = nil
        }
        if let format {
          let text = Date.VerbatimFormatStyle(format: format, locale: context.locale,
            timeZone: context.timeZone, calendar: context.calendar).format(date)
          guard !text.isEmpty else { throw ParseFailure.invalid("本次日历周字段无法展开。") }
          literal += text
        } else {
          flushLiteral()
          result += String(repeating: String(symbol), count: count)
        }
      }
    }
    flushLiteral()
    return result
  }

  // Foundation Calendar caps input to this range before arithmetic. Reject instead of
  // rendering a different date after an extreme offset. Date.distantPast/Future are not limits.
  // swift-foundation/Sources/FoundationEssentials/Date.swift: validCalendarRange
  private static let calendarRange: ClosedRange<TimeInterval> = -211845067200...15927175497600

  private static func renderTemporal(_ field: TemporalField, context: Temporal) throws -> String {
    var date = context.date
    guard calendarRange.contains(date.timeIntervalSinceReferenceDate) else { throw ParseFailure.invalid("本次日期无效，请重新调用模板。") }
    for offset in field.offsets {
      guard let next = context.calendar.date(byAdding: offset.component, value: offset.value,
                                              to: date, wrappingComponents: false),
            calendarRange.contains(next.timeIntervalSinceReferenceDate),
            offset.value == 0 || (offset.value > 0 ? next > date : next < date) else {
        throw ParseFailure.invalid("日期偏移无法计算，请调整 offset。")
      }
      date = next
    }
    guard let pattern = field.format ?? context.defaultPatterns[field.kind], !pattern.isEmpty else {
      throw ParseFailure.invalid("本次日期格式不可用，请指定 format 或重新调用模板。")
    }
    let formatter = DateFormatter()
    formatter.locale = context.locale
    formatter.calendar = context.calendar
    formatter.timeZone = context.timeZone
    formatter.dateFormat = try patternWithFrozenWeekFields(pattern, date: date, context: context)
    let text = formatter.string(from: date)
    guard !text.isEmpty else { throw ParseFailure.invalid("日期格式没有产生文本，请调整 format。") }
    return text
  }

  static func render(_ parsed: Parsed, values: [String: String], context: FrozenContext = .init(),
                     decisions: Decisions = .init()) -> Evaluation {
    var diagnostics = parsed.diagnostics
    var missing: [String] = []
    for p in parsed.parameters {
      guard let value = values[p.key] else { missing.append(p.key); continue }
      if p.isRequired && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        missing.append(p.key)
      } else if !p.options.isEmpty && !p.options.contains(value) && !(value.isEmpty && !p.isRequired) {
        missing.append(p.key)
        diagnostics.append(.init(severity: .error, range: p.ranges[0], message: "请选择有效的预设选项。"))
      }
    }
    var text = ""
    var cursorOffset: Int?
    var cursorRange: NSRange?
    var needsEmptyClipboardDecision = false
    for token in parsed.tokens {
      switch token.kind {
      case .cursor:
        if cursorOffset == nil { cursorOffset = text.utf16.count; cursorRange = token.range }
      case .literal: text += token.raw
      case .parameter(let key): text += missing.contains(key) ? token.raw : (values[key] ?? token.raw)
      case .clipboard:
        switch context.clipboard {
        case .text(let value) where !value.isEmpty:
          text += value
        case .empty, .nonText, .text:
          if !decisions.allowEmptyClipboard {
            text += token.raw
            needsEmptyClipboardDecision = true
          }
        case .notRequested:
          text += token.raw
          diagnostics.append(.init(severity: .error, range: token.range, message: "尚未采集本次剪贴板文本，请重新调用模板。"))
        }
      case .temporal(let field):
        do {
          guard let temporal = context.temporal else { throw ParseFailure.invalid("尚未采集本次时间，请重新调用模板。") }
          text += try renderTemporal(field, context: temporal)
        } catch {
          text += token.raw
          diagnostics.append(.init(severity: .error, range: token.range,
                                   message: (error as? ParseFailure)?.message ?? "日期字段无法展开。"))
        }
      }
    }
    if let offset = cursorOffset, missing.isEmpty, !needsEmptyClipboardDecision, !diagnostics.contains(where: { $0.severity == .error }) {
      if text.isEmpty || !OwlTemplateCursorPlacement.isBoundary(offset, in: text) {
        diagnostics.append(.init(severity: .error, range: cursorRange ?? NSRange(location: 0, length: 0),
          message: text.isEmpty ? "展开结果为空，未插入；请在光标字段旁添加正文。" : "光标字段不能位于组合字符或换行序列内部，请调整位置。"))
      }
    }
    return Evaluation(previewText: text, diagnostics: diagnostics, missingKeys: missing,
                      needsEmptyClipboardDecision: needsEmptyClipboardDecision, cursorOffset: cursorOffset)
  }

  static func quoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
