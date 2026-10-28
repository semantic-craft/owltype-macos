//
//  OwlInputController+Lifecycle.swift
//  Owltype
//
//  Single responsibility: IMK input-session lifecycle overrides (recognizedEvents /
//  activate / deactivate / hidePalettes / commitComposition) and the ASCII-mode
//  notification handlers the init's observers fan out to.
//  Moved verbatim out of OwlInputController.swift (god-object shrink, 2026-06-20);
//  no logic edits.
//

import InputMethodKit

extension OwlInputController {

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    debugLiveInputTrace("recognizedEvents hasSender=\(sender != nil)")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    templateHostGeneration &+= 1
    automaticEpoch &+= 1
    discardAutomaticExpansion()
    finishPairBeforeChangingClient(to: sender as? IMKTextInput)
    self.client ?= sender as? IMKTextInput
    pendingTemplateDelivery?.hostDidActivate()
    // print("[DEBUG] activateServer:")
    debugLiveInputTrace("activateServer hasSender=\(sender != nil)")
    var keyboardLayout = engineRuntime.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    if rime?.isValid == true {
      currentApp = client?.bundleIdentifier() ?? currentApp
      updateAppOptions()
    }
    preedit = ""
    if rime?.isValid != true { createSession() }
    MainActor.assumeIsolated { OwlInputStatusPanel.shared.activate(self) }
  }

  override func deactivateServer(_ sender: Any!) {
    smartPunctuation.reset()
    MainActor.assumeIsolated { OwlInputStatusPanel.shared.deactivate(self) }
    rememberAppInputMode()
    invalidateSettledRerankForAction()
    pendingTemplateDelivery?.hostWillDeactivate()
    templateHostGeneration &+= 1
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    debugLiveInputTrace("deactivateServer hasSender=\(sender != nil)")
    // B8: this input session is ending — cancel any in-flight AI lane requests it spawned so they
    // don't run to completion against a session that's gone (wasted tokens).
    aiTasks.cancelAll()
    hidePalettes()
    commitComposition(sender)
    pairedClosings.removeAll()
    // Focus is leaving this field — drop the cross-commit spacing seed so the next field's first
    // commit doesn't inherit a stale boundary char.
    lastCommittedCharacter = nil
    client = nil
  }

  override func hidePalettes() {
    NSApp.owlAppDelegate.owlPanel?.hidePanel()
    // 多行「翻页才展开」旗标的唯一复位点：commit、失焦、空 menu 的收尾全汇聚到这里，
    // 下一次组字从单行重新开始（置位在 showPanel，见 OwlInputController+RimeUpdate）。
    scrollDidPage = false
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    invalidateSettledRerankForAction()
    if let incoming = sender as? IMKTextInput, let previous = client, incoming !== previous {
      discardAutomaticExpansion()
    }
    finishAutomaticExpansion(replaySemicolon: true)
    finishPairBeforeChangingClient(to: sender as? IMKTextInput)
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    // Native finish performs the selection and learning, preserving focus-loss local-mode rules.
    // A missing session or a refused native action retains the converted-preview/raw fallback.
    // Every path clears the snapshot registry, even when no composition remains (#37).
    let live: RimeSession? = (rime?.isValid == true) ? rime : nil
    if let live, live.finishNativeComposition(onFocusLoss: true) {
      if let text = live.takeCommit(), !text.isEmpty { commit(string: text) }
      MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.emitCleared() }
      flushPendingPairedClosing()
      return
    }
    OwlForcedFinalize.finalize(
      input: live?.input(),
      preview: { live?.composition()?.commitTextPreview },
      commit: { self.commit(string: $0) },
      clearComposition: { live?.clearComposition() },
      emitCleared: { MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.emitCleared() } },
      trace: { self.debugLiveInputTrace($0) }
    )
    flushPendingPairedClosing()
  }

  // seam: was private; internal so OwlInputController.swift's init observer closure can reach it across files.
  // Deliberately NOT gated on `client != nil` (audited 2026-07-07, task input-controller-hygiene):
  // this is the CLI global-set path (`--ascii/--nascii` → distributed OwlToggleASCIIMode →
  // OwlSetASCIIMode), inherited verbatim from upstream Squirrel #1070 where set is broadcast but
  // report (below) is active-only. Every LIVE controller must flip, or switching back to a
  // backgrounded app would resurrect the old mode. Menu/settings 中英 does NOT come through here —
  // it uses applyDefaultAsciiModeToLiveSession (active controller only).
  func handleASCIIModeToggle(_ notification: Notification) {
    guard let enableASCII = notification.object as? Bool else { return }
    pendingTemplateDelivery?.invalidate()
    finishAutomaticExpansion(replaySemicolon: true)
    setRimeOption(.asciiMode, enableASCII)
    OwlAppInputMemory.shared.remember(app: currentApp, ascii: enableASCII)
    rimeUpdate()
  }

  // seam: was private; internal so OwlInputController.swift's init observer closure can reach it across files.
  func reportASCIIMode(_: Notification) {
    // Only active input controller should respond
    guard client != nil else { return }
    guard let rime, rime.isValid else { return }

    let isASCIIMode = rime.option(.asciiMode)
    let status = isASCIIMode ? "ascii" : "nascii"

    // Directly respond with the status
    DistributedNotificationCenter.default().postNotificationName(
      .init("OwlASCIIModeResponse"),
      object: status
    )
  }
}
