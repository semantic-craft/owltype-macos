import AppKit
import SwiftUI

/// Proof is scoped to the practice field. Pasting and edits from other sources cannot pass.
struct OwlPracticeProof {
  static let target = "你好，猫头鹰"
  private(set) var hasOwlCommit = false
  private(set) var hasOtherSource = false

  mutating func inserted(fromOwl: Bool, hadComposition: Bool) {
    hasOtherSource = hasOtherSource || !fromOwl
    hasOwlCommit = hasOwlCommit || (fromOwl && hadComposition)
  }

  func isComplete(text: String, hasMarkedText: Bool) -> Bool {
    OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "onboarding_practice_is_complete",
      "args": [
        "target": Self.target,
        "text": text,
        "has_owl_commit": hasOwlCommit,
        "has_other_source": hasOtherSource,
        "has_marked_text": hasMarkedText
      ]
    ])
  }
}

/// NSTextView supplies actual marked-text/commit evidence; SwiftUI TextField cannot distinguish paste.
struct OwlPracticeField: NSViewRepresentable {
  var onChange: (String, Bool, String?) -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    let text = OwlPracticeTextView()
    text.onChange = onChange
    text.isRichText = false
    text.font = .systemFont(ofSize: 17)
    text.textContainerInset = NSSize(width: 10, height: 10)
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.allowsUndo = false
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityIdentifier("onboarding.practice.input")
    scroll.documentView = text
    text.unregisterDraggedTypes()
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    (nsView.documentView as? OwlPracticeTextView)?.onChange = onChange
  }
}

final class OwlPracticeTextView: NSTextView {
  var onChange: ((String, Bool, String?) -> Void)?
  var sourceIsOwl: () -> Bool = {
    OwlInstaller.InputMode(rawValue: OwlInstaller.currentInputSourceID() ?? "") != nil
  }
  private var proof = OwlPracticeProof()
  private var pendingOwlComposition = false

  override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
    pendingOwlComposition = sourceIsOwl()
    super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange)
    publish()
  }

  override func insertText(_ value: Any, replacementRange: NSRange) {
    proof.inserted(fromOwl: sourceIsOwl(), hadComposition: pendingOwlComposition || hasMarkedText())
    pendingOwlComposition = false
    super.insertText(value, replacementRange: replacementRange)
    publish()
  }

  override func didChangeText() {
    super.didChangeText()
    if string.isEmpty && !hasMarkedText() {
      proof = OwlPracticeProof()
      pendingOwlComposition = false
    }
    publish()
  }

  override func paste(_ sender: Any?) {
    onChange?(string, false, "请手动输入；粘贴不计入试打。")
  }

  override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
  override func pasteAsRichText(_ sender: Any?) { paste(sender) }

  private func publish() {
    let hint: String? = OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "onboarding_practice_hint",
      "args": [
        "has_other_source": proof.hasOtherSource
      ]
    ])
    onChange?(string, proof.isComplete(text: string, hasMarkedText: hasMarkedText()), hint)
  }
}
