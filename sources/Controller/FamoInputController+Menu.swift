//
//  FamoInputController+Menu.swift
//  Famotype local input core
//

import InputMethodKit

extension FamoInputController {
  override func menu() -> NSMenu! {
    let flags = currentRimeStatusFlags()
    let cjkInput = menuItem(
      title: FamoInputMenuTitles.cjkInput(asciiMode: flags.asciiMode),
      action: #selector(toggleASCIIModeFromMenu)
    )
    let traditionalInput = menuItem(
      title: FamoInputMenuTitles.traditionalInput(traditional: flags.traditional),
      action: #selector(toggleTraditionalInputFromMenu)
    )
    let asciiPunctuation = menuItem(
      title: FamoInputMenuTitles.asciiPunctuation(asciiPunct: flags.asciiPunct),
      action: #selector(toggleASCIIPunctuationFromMenu)
    )
    let fullShape = menuItem(
      title: FamoInputMenuTitles.fullShape(fullShape: flags.fullShape),
      action: #selector(toggleFullShapeFromMenu),
      keyEquivalent: "h"
    )
    fullShape.keyEquivalentModifierMask = [.option, .shift]

    let menu = NSMenu()
    menu.addItem(cjkInput)
    menu.addItem(traditionalInput)
    menu.addItem(asciiPunctuation)
    menu.addItem(fullShape)
    menu.addItem(.separator())
    menu.addItem(menuItem(title: FamoInputMenuTitles.settings, action: #selector(showFamoSettings)))
    menu.addItem(menuItem(title: FamoInputMenuTitles.quickSend, action: #selector(showFamoQuickSend)))
    menu.addItem(menuItem(title: FamoInputMenuTitles.emoji, action: #selector(showFamoEmojiPanel)))
    debugLiveInputTrace(
      "menu called items=\(menu.items.count) schema=\(schemaId) ascii=\(flags.asciiMode)"
    )
    return menu
  }

  private func menuItem(
    title: String,
    action: Selector,
    keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    return item
  }

  @objc func deploy() {
    FamoLatencyTrace.event("button.open.deploy")
    NSApp.famoAppDelegate.deploy()
  }

  @objc func syncUserData() {
    FamoLatencyTrace.event("button.open.sync")
    NSApp.famoAppDelegate.syncUserData()
  }

  @objc func toggleASCIIModeFromMenu() {
    toggleRimeOption(.asciiMode)
  }

  @objc func toggleTraditionalInputFromMenu() {
    let traditional = !currentRimeStatusFlags().traditional
    setTraditionalOutputOptions(traditional)
    FamoKeyboardPreferences.traditionalOutput = traditional
    rimeUpdate()
  }

  @objc func toggleASCIIPunctuationFromMenu() {
    let asciiPunct = !currentRimeStatusFlags().asciiPunct
    setRimeOption(.asciiPunct, asciiPunct)
    FamoKeyboardPreferences.cjkPunctToggle = asciiPunct
    rimeUpdate()
  }

  @objc func toggleFullShapeFromMenu() {
    toggleRimeOption(.fullShape)
  }

  @objc func showFamoSettings() {
    FamoLatencyTrace.event("button.open.settings")
    NSApp.famoAppDelegate.showSettings()
  }

  /// Local-core hotkeys are matched only while the IME is active. There is no
  /// session-wide event tap and no Accessibility permission requirement.
  func handleGlobalHotKeyViaIMK(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags
    if let combo = FamoHotKeySlot.quickSendPanel.current?.carbonCombo,
       FamoHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: flags) {
      showFamoQuickSend()
      return true
    }
    if let combo = FamoHotKeySlot.promptAssistant.current?.carbonCombo,
       FamoHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: flags) {
      showFamoPromptPicker(initialSegment: .prompt)
      return true
    }
    return false
  }

  @objc func showFamoQuickSend() {
    showFamoPromptPicker(initialSegment: .phrase)
  }

  func showFamoPromptPicker(initialSegment: FamoPickerSegment) {
    let capturedClient = client
    NSApp.famoAppDelegate.showQuickSendPanel(
      onPickPhrase: { [weak self] phrase in
        guard let self else { return }
        if let capturedClient {
          self.apply(.insertText(phrase), client: capturedClient)
        } else {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(phrase, forType: .string)
        }
      },
      onPickPrompt: { [weak self] entry in
        self?.insertPickedPrompt(entry, capturedClient: capturedClient)
      },
      initialSegment: initialSegment
    )
  }

  @objc func showFamoOnboarding() {
    NSApp.famoAppDelegate.showOnboarding()
  }

  @objc func showFamoEmojiPanel() {
    NSApp.famoAppDelegate.showEmojiPanel(onPick: { [weak self] glyph in
      guard let self else { return }
      if self.client != nil {
        self.commit(string: glyph)
      } else {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(glyph, forType: .string)
      }
    })
  }

  @objc func openLogFolder() {
    NSApp.famoAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.famoAppDelegate.openRimeFolder()
  }

  @objc func openWiki() {
    NSApp.famoAppDelegate.openWiki()
  }
}
