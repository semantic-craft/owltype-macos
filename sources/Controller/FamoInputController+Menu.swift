//
//  FamoInputController+Menu.swift
//  Famo
//
//  Single responsibility: the status-menu builder (`menu()`) and all the `@objc`
//  action handlers it (and the notification observers) targets — toggles, show*
//  windows, the explicit AI cloud/local lanes, and the open*/deploy/sync items.
//  Moved verbatim out of FamoInputController.swift (god-object shrink, 2026-06-20);
//  no logic edits.
//

import InputMethodKit

extension FamoInputController {

  override func menu() -> NSMenu! {
    let flags = currentRimeStatusFlags()
    let cjkInput = NSMenuItem(title: FamoInputMenuTitles.cjkInput(asciiMode: flags.asciiMode), action: #selector(toggleASCIIModeFromMenu), keyEquivalent: "")
    cjkInput.target = self
    let traditionalInput = NSMenuItem(title: FamoInputMenuTitles.traditionalInput(traditional: flags.traditional), action: #selector(toggleTraditionalInputFromMenu), keyEquivalent: "")
    traditionalInput.target = self
    let asciiPunctuation = NSMenuItem(title: FamoInputMenuTitles.asciiPunctuation(asciiPunct: flags.asciiPunct), action: #selector(toggleASCIIPunctuationFromMenu), keyEquivalent: "")
    asciiPunctuation.target = self
    let fullShape = NSMenuItem(title: FamoInputMenuTitles.fullShape(fullShape: flags.fullShape), action: #selector(toggleFullShapeFromMenu), keyEquivalent: "h")
    fullShape.target = self
    fullShape.keyEquivalentModifierMask = [.option, .shift]
    // v0.2: open the SwiftUI settings window (additive UI; not on the key-event hot path).
    let famoSettings = NSMenuItem(title: FamoInputMenuTitles.settings, action: #selector(showFamoSettings), keyEquivalent: "")
    famoSettings.target = self
    // 快捷短语… / 剪贴板… — open the matching settings sub-page. Handlers + titles already
    // existed (showFamoQuickSend / showFamoClipboard) but were never added to the menu.
    let famoQuickSend = NSMenuItem(title: FamoInputMenuTitles.quickSend, action: #selector(showFamoQuickSend), keyEquivalent: "")
    famoQuickSend.target = self
    let famoClipboard = NSMenuItem(title: FamoInputMenuTitles.clipboard, action: #selector(showFamoClipboard), keyEquivalent: "")
    famoClipboard.target = self
    // module 7: open the 表情/符号 panel. target=self so picking inserts into THIS session's
    // live client via commit(string:). Additive UI; not on the key-event hot path.
    let famoEmoji = NSMenuItem(title: FamoInputMenuTitles.emoji, action: #selector(showFamoEmojiPanel), keyEquivalent: "")
    famoEmoji.target = self
    // 「任意提问」的状态栏入口已删除（产品决策 2026-07-26）：改造成划词技能兜底后它必须带着选区
    // 进（对选区下指令），而状态栏那一下永远是空选区，开出来的窗什么也加工不了。入口只剩划词菜单
    // (FamoSelectionMenuAction.ask)——自动弹出或热键召唤，两条都带选区。
    // 润色 moved into the 划词菜单 (FamoSelectionMenuAction.polish); no status-menu entry.
    // 「启用划词工具箱」总开关同样不进菜单栏（产品决策 2026-07-21）：默认关闭、只在设置→技能平台
    // 开启，不提供随手打开的快捷入口；热键召唤是平行开关，不受总开关约束。
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self
    // #111 问3 B：补注销入口。「注销并重新登录…」放在「检查更新」前的独立分组；与更新提示【立即注销】
    // 共用 FamoLogoutAction.requestLogout（发请求 + 两类 fallback），不复制分流逻辑。
    let logoutRelogin = NSMenuItem(title: FamoInputMenuTitles.logoutRelogin, action: #selector(requestLogoutAndRelogin), keyEquivalent: "")
    logoutRelogin.target = self

    let menu = NSMenu()
    menu.addItem(cjkInput)
    menu.addItem(traditionalInput)
    menu.addItem(asciiPunctuation)
    menu.addItem(fullShape)
    menu.addItem(.separator())
    menu.addItem(famoSettings)
    menu.addItem(famoQuickSend)
    menu.addItem(famoClipboard)
    // 表情/符号 entry is always present — the panel is summoned from here. The old 启用 toggle
    // was removed (hiding the only entry point made the panel unreachable from anywhere).
    menu.addItem(famoEmoji)
    menu.addItem(.separator())
    menu.addItem(logoutRelogin)
    menu.addItem(.separator())
    menu.addItem(update)

    debugLiveInputTrace("menu called items=\(menu.items.count) schema=\(schemaId) ascii=\(flags.asciiMode)")
    return menu
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
    // 全套简繁 option 一并切换（全拼/双拼走 `transcription`，五笔走 `zh_trad`），保证「简入繁出」
    // 对所有方案统一生效。同时记忆到 pref，让设置页的「简入繁出」开关保持同步。
    setTraditionalOutputOptions(traditional)
    FamoKeyboardPreferences.traditionalOutput = traditional
    rimeUpdate()
  }

  @objc func toggleASCIIPunctuationFromMenu() {
    let asciiPunct = !currentRimeStatusFlags().asciiPunct
    setRimeOption(.asciiPunct, asciiPunct)
    // 记忆到 pref，让设置页「中文下使用英文标点」开关 + 重启后状态保持同步（对标 toggleTraditionalInputFromMenu）。
    FamoKeyboardPreferences.cjkPunctToggle = asciiPunct
    rimeUpdate()
  }

  @objc func toggleFullShapeFromMenu() {
    toggleRimeOption(.fullShape)
  }

  // v0.2: forward to the delegate's SwiftUI settings window. Additive UI only;
  // this is the status-menu builder, not the key-event hot path.
  @objc func showFamoSettings() {
    FamoLatencyTrace.event("button.open.settings")
    NSApp.famoAppDelegate.showSettings()
  }

  @objc func showFamoClipboard() {
    FamoLatencyTrace.event("button.open.clipboard")
    NSApp.famoAppDelegate.showSettings(selectedPage: .clipboard)
  }

  // Global-hotkey matcher (#118): called from `handle()` for every keyDown while 法墨 is the
  // active IME — the ONLY hotkey path (Carbon registration is banned; it consumes the combo
  // system-wide without ever delivering in this IMK process). Consumes and triggers when the
  // event equals the 快捷短语面板 / 划词菜单 / 提示词助手 combo.
  func handleGlobalHotKeyViaIMK(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags
    if let combo = FamoHotKeySlot.quickSendPanel.current?.carbonCombo,
       FamoHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: flags) {
      FamoHotKeyMatcher.log.notice("imk-path fired: quickSend")
      showFamoQuickSend()
      return true
    }
    if let combo = FamoHotKeySlot.selectionMenu.current?.carbonCombo,
       FamoHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: flags) {
      FamoHotKeyMatcher.log.notice("imk-path fired: selectionMenu")
      NSApp.famoAppDelegate.selectionMenuCoordinator?.summonForCurrentSelection()
      return true
    }
    if let combo = FamoHotKeySlot.promptAssistant.current?.carbonCombo,
       FamoHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: flags) {
      FamoHotKeyMatcher.log.notice("imk-path fired: promptAssistant")
      showFamoPromptPicker(initialSegment: .prompt)
      return true
    }
    return false
  }

  // 快捷短语… opens the runtime picker panel (mirrors showFamoEmojiPanel), not the settings page.
  // PR2 gives the panel a typed search field, so it becomes key (becomesKeyOnlyIfNeeded) while the
  // user types — which can deactivate the host IME session and nil `self.client`. So CAPTURE the
  // client up-front (mirroring presentPromptFillSheet); the panel reactivates the captured host
  // before invoking this handler, so inserting through the CAPTURED client reference lands the
  // phrase back in the original field. If there was no live client at summon time, fall back to
  // copying so the pick isn't lost. IRON RULE: never NSApp.activate here (that nils `client` — the
  // reason FamoAIWindow is copy-only). This ADDS a caller of the existing apply(.insertText:client:)
  // seam; the hot-path methods themselves are untouched.
  @objc func showFamoQuickSend() {
    showFamoPromptPicker(initialSegment: .phrase)
  }

  /// 提示词助手热键（FamoHotKeySlot.promptAssistant）传 .prompt 直达提示词页；状态菜单 / 旧
  /// 热键仍落在短语页。两处共用同一面板与同一 capture→restore 插入链路。
  func showFamoPromptPicker(initialSegment: FamoPickerSegment) {
    FamoLatencyTrace.event("button.open.quickSend")
    let client = self.client
    NSApp.famoAppDelegate.showQuickSendPanel(
      onPickPhrase: { [weak self] phrase in
        guard let self else { return }
        if let client {
          self.apply(.insertText(phrase), client: client)
        } else {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(phrase, forType: .string)
        }
      },
      onPickPrompt: { [weak self] entry in
        // 提示词: insert body (or fill sheet when it has {{变量}}) through the SAME captured client —
        // never self.client (the key panel may have nil'd it). See insertPickedPrompt.
        self?.insertPickedPrompt(entry, capturedClient: client)
      },
      initialSegment: initialSegment
    )
  }

  // v0.3.3: forward to the delegate's SwiftUI onboarding window. Additive UI only;
  // this is the status-menu builder, not the key-event hot path.
  @objc func showFamoOnboarding() {
    FamoLatencyTrace.event("button.open.onboarding")
    NSApp.famoAppDelegate.showOnboarding()
  }

  // module 7: open the 表情/符号 panel wired to insert at the cursor. The panel is
  // non-activating, so the host document keeps focus and this controller's `client` stays
  // alive; a pick routes to the EXISTING commit(string:) (a new caller — the hot-path
  // methods themselves are untouched). If by pick time there is no live client (rare: the
  // document went away while the panel floated), fall back to copying so the pick isn't lost.
  @objc func showFamoEmojiPanel() {
    FamoLatencyTrace.event("button.open.emoji")
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
    FamoLatencyTrace.event("button.open.logFolder")
    NSApp.famoAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    FamoLatencyTrace.event("button.open.rimeFolder")
    NSApp.famoAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    FamoLatencyTrace.event("button.open.checkUpdates")
    NSApp.famoAppDelegate.checkForUpdates()
  }

  // #111 问3 B：输入菜单「注销并重新登录…」的处理器，与更新提示【立即注销】共用 FamoLogoutAction。
  @objc func requestLogoutAndRelogin() {
    FamoLatencyTrace.event("button.logout")
    FamoLogoutAction.requestLogout()
  }

  @objc func openWiki() {
    FamoLatencyTrace.event("button.open.wiki")
    NSApp.famoAppDelegate.openWiki()
  }
}
