import AppKit

/// Explicit invocation context only. No history, polling, normalization or persistence.
/// The caller freezes this value for all previews and the eventual insertion.
enum OwlTemplateContextCapture {
  static func capture(
    _ requirements: Set<OwlTemplateEngine.Requirement>,
    readClipboard: () -> String? = { NSPasteboard.general.string(forType: .string) },
    now: () -> Date = { Date() },
    timeZone: () -> TimeZone = { .current },
    locale: () -> Locale = { .current },
    calendar: () -> Calendar = { .current }
  ) -> OwlTemplateEngine.FrozenContext {
    var context = OwlTemplateEngine.FrozenContext()
    if requirements.contains(.clipboard) {
      if let text = readClipboard() {
        context.clipboard = text.isEmpty ? .empty : .text(text)
      } else {
        // Includes an empty pasteboard or one without an available plain-text representation.
        context.clipboard = .nonText
      }
    }
    if requirements.contains(.temporal) {
      context.temporal = .init(date: now(), timeZone: timeZone(), locale: locale(), calendar: calendar())
    }
    return context
  }
}
