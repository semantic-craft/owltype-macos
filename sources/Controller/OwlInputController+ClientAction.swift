//
//  OwlInputController+ClientAction.swift
//  Owltype
//
//  The SINGLE side-effect point of the pure input pipeline (task 06-22-pure-input-pipeline-refactor).
//
//  Pipeline:  NSEvent → OwlUserAction (PURE classify) → feed librime (processKey, stateful)
//             → OwlClientAction[] → apply(client) (single side-effect point).
//
//  `OwlClientAction` is a PURE value enum of the two IMK text mutations the controller performs.
//  After this refactor, `apply(_:client:)` is the ONLY place that calls `client.insertText` /
//  `client.setMarkedText` — the two former call sites (`commit` / `show` in +RimeUpdate.swift)
//  now build a `OwlClientAction` and route it through `apply`. Behaviour is byte-for-byte
//  identical: `apply` performs exactly the same `insertText` / `setMarkedText` call the old code
//  did, with the same arguments.
//
//  This is NOT a state machine — it carries no conversion state; it is a 1:1 description of the
//  side effect to perform. librime still owns all conversion state (`RimeContext` via `RimeSeam`).
//

import InputMethodKit

/// A pure description of a client (IMK) text side-effect. Built off librime's composition state by
/// `commit` / `show`, then dispatched once through `apply(_:client:)`.
enum OwlClientAction: Equatable {
  /// Insert committed text at the cursor (replacing the empty range). The string is already
  /// transformed (`OwlCommitTransform.apply` happens at build time, matching the old `commit`).
  case insertText(String)

  /// Insert text replacing an EXPLICIT client range (自动配对括号, task 07-02): the caret-move
  /// self-replacement of the open bracket and the skip-over overwrite of a duplicate closer.
  /// Same single side-effect point — only the replacementRange differs from `.insertText`.
  case insertTextInRange(String, replacementRange: NSRange)

  /// Replace the marked (preedit) text. `selectionRange` / the attribute styling are reconstructed
  /// in `apply` exactly as the old `show` built them, so this carries only the value inputs.
  case setMarkedText(preedit: String, selRange: NSRange, caretPos: Int)
}

extension OwlInputController {

  /// The SINGLE place that mutates the IMK client. Every `client.insertText` / `client.setMarkedText`
  /// call in the controller goes through here (grep verifies side-effect convergence). Pure
  /// dispatch — same calls, same arguments as the old inline code.
  func apply(_ action: OwlClientAction, client: IMKTextInput) {
    finishAutomaticExpansionBeforeClientAction()
    switch action {
    case let .insertText(string):
      OwlLatencyTrace.event("commitText.apply")
      client.insertText(string, replacementRange: .empty)

    case let .insertTextInRange(string, replacementRange):
      OwlLatencyTrace.event("replacementRange.apply")
      client.insertText(string, replacementRange: replacementRange)

    case let .setMarkedText(preedit, selRange, caretPos):
      let markedTrace = OwlLatencyTrace.begin("markedText.apply")
      defer { OwlLatencyTrace.end("markedText.apply", markedTrace) }
      // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
      let start = selRange.location
      let attrString = NSMutableAttributedString(string: preedit)
      if start > 0 {
        let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
        attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
      }
      let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
      let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: remainingRange)
      client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
    }
  }
}
