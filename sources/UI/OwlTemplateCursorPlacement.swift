import Foundation

/// UTF-16 geometry only. No host reads, text writes, or assumptions about a client's identity.
enum OwlTemplateCursorPlacement {
  static func valid(_ range: NSRange) -> Bool {
    range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
      range.length != NSNotFound && !range.location.addingReportingOverflow(range.length).overflow
  }

  static func equalText(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
  }

  static func isBoundary(_ offset: Int, in text: String) -> Bool {
    guard offset >= 0, offset <= text.utf16.count else { return false }
    if offset == 0 || offset == text.utf16.count { return true }
    var count = 0
    for character in text {
      count += String(character).utf16.count
      if count == offset { return true }
      if count > offset { return false }
    }
    return false
  }

  /// A bounded host window is only useful if its truncated prefix cannot carry hidden
  /// grapheme state (for example an emoji followed by many variation selectors and ZWJ).
  static func isHostBoundary(_ offset: Int, in text: String, startsAtDocumentStart: Bool) -> Bool {
    if !startsAtDocumentStart, let first = text.unicodeScalars.first {
      switch first.properties.generalCategory {
      case .nonspacingMark, .spacingMark, .enclosingMark, .format, .modifierLetter, .modifierSymbol: return false
      default: break
      }
      if first.value == 0xFFFD || first.value == 0x200D || (0x1F1E6...0x1F1FF).contains(first.value) ||
        (0x1F3FB...0x1F3FF).contains(first.value) { return false }
    }
    return isBoundary(offset, in: text)
  }

  static func selectionIsAtEnd(_ selection: NSRange?, inserted: NSRange) -> Bool {
    valid(inserted) && selection == NSRange(location: NSMaxRange(inserted), length: 0)
  }

  static func positionDescription(text: String, offset: Int) -> String {
    guard isBoundary(offset, in: text) else { return "光标位置需调整。" }
    let prefix = (text as NSString).substring(to: offset)
    let lines = prefix.components(separatedBy: "\n")
    return "光标将位于第 \(lines.count) 行、第 \((lines.last ?? "").count + 1) 列。"
  }

  static func insertedRange(text: String, base: Int) -> NSRange? {
    let range = NSRange(location: base, length: text.utf16.count)
    return valid(range) ? range : nil
  }

  static func target(text: String, offset: Int, base: Int, selection: NSRange, readback: String) -> NSRange? {
    guard isBoundary(offset, in: text), let inserted = insertedRange(text: text, base: base),
          valid(selection), selection == NSRange(location: NSMaxRange(inserted), length: 0),
          equalText(text, readback) else { return nil }
    return NSRange(location: base + offset, length: 0)
  }
}
