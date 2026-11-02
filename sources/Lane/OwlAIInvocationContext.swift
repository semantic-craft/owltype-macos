//
//  OwlAIInvocationContext.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M6 / Issue #394)
//

import AppKit
import Foundation
import InputMethodKit

/// The invocation context capturing host state when OwlAIWindow is opened.
/// Enables context-aware writeback actions ("上屏 (↩)" vs "替换选区 (↩)" vs "复制 (↩)").
enum OwlAIInvocationContext: Equatable, @unchecked Sendable {
  /// Invoked during active typing composition (/ai command or Shift+K while composing).
  case typing(
    client: IMKTextInput?,
    preedit: String,
    frontmostApp: NSRunningApplication? = nil,
    bundleID: String? = nil
  )

  /// Invoked on selected text in host application.
  case selection(snapshot: OwlSelectionMenuSnapshot)

  /// Invoked standalone without an active text field or selection (copy-only mode).
  case standalone

  static func == (lhs: OwlAIInvocationContext, rhs: OwlAIInvocationContext) -> Bool {
    switch (lhs, rhs) {
    case let (.typing(c1, p1, a1, b1), .typing(c2, p2, a2, b2)):
      return c1 === c2 && p1 == p2 && a1 == a2 && b1 == b2
    case let (.selection(s1), .selection(s2)):
      return s1 == s2
    case (.standalone, .standalone):
      return true
    default:
      return false
    }
  }

  /// Primary action title for the window action button.
  var primaryActionTitle: String {
    switch self {
    case .typing:
      return "上屏 (↩)"
    case .selection:
      return "替换选区 (↩)"
    case .standalone:
      return "复制 (↩)"
    }
  }
}
