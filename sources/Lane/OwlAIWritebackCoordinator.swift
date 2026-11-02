//
//  OwlAIWritebackCoordinator.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M6 / Issue #394)
//

import AppKit
import Foundation
import InputMethodKit

@MainActor
final class OwlAIWritebackCoordinator {
  static let shared = OwlAIWritebackCoordinator()

  enum Outcome: Equatable, Sendable {
    case insertedToClient
    case replacedSelection(OwlInsertStrategy)
    case pastedFallback
    case copiedToClipboard
    case abortedEmpty
    case failed(String)
  }

  init() {}

  /// Executes context-aware writeback.
  /// - Parameters:
  ///   - text: The generated text to be written back.
  ///   - context: The invocation context (.typing, .selection, or .standalone).
  ///   - onDismissWindow: Optional closure called to dismiss the AI window and restore host focus.
  /// - Returns: Outcome of the writeback attempt.
  @discardableResult
  func writeback(
    text: String,
    context: OwlAIInvocationContext,
    onDismissWindow: (() -> Void)? = nil
  ) -> Outcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .abortedEmpty }

    // 1. Dismiss window first to return focus to host application cleanly without NSAlert.runModal()
    onDismissWindow?()

    // 2. Dispatch according to invocation mode
    switch context {
    case let .typing(client, _, frontApp, _):
      return executeTypingWriteback(text: text, client: client, frontApp: frontApp)

    case let .selection(snapshot):
      return executeSelectionWriteback(text: text, snapshot: snapshot)

    case .standalone:
      OwlPasteInserter.copyOnly(text)
      return .copiedToClipboard
    }
  }

  private func executeTypingWriteback(
    text: String,
    client: IMKTextInput?,
    frontApp: NSRunningApplication?
  ) -> Outcome {
    // Tier 1: Direct IMK client insertion
    if let client {
      client.insertText(text, replacementRange: .empty)
      return .insertedToClient
    }

    // Tier 2: Fallback to simulated ⌘V paste ladder
    if let app = frontApp, !app.isActive {
      app.activate()
    }
    let pasted = OwlPasteInserter.paste(text)
    if pasted {
      return .pastedFallback
    }

    // Tier 3: Clipboard copy-only fallback
    OwlPasteInserter.copyOnly(text)
    return .copiedToClipboard
  }

  private func executeSelectionWriteback(
    text: String,
    snapshot: OwlSelectionMenuSnapshot
  ) -> Outcome {
    let outcome = OwlSelectionReplacementFlow.write(
      text,
      target: snapshot.replacementTarget,
      bundleID: snapshot.bundleID
    )
    switch outcome {
    case let .inserted(strategy):
      return .replacedSelection(strategy)
    case .copiedToClipboard:
      return .copiedToClipboard
    case let .failed(message):
      return .failed(message)
    }
  }
}
