//
//  OwlInputController+EngineUpdate.swift
//  Owltype
//
//  Single responsibility: pull the engine's commit/status/composition state and push it to
//  IMK marked text and the candidate panel (the preedit/candidate byte→UTF-16 index math).
//  Moved verbatim out of OwlInputController.swift (god-object shrink, 2026-06-20) — the
//  index math is intricate and was moved byte-for-byte; no logic edits.
//

import ApplicationServices
import InputMethodKit

/// Commit policy at the universal Rime chokepoint. Only the standalone ASCII dollar from the
/// Shift+4 currency menu changes the following input mode; RMB and text containing `$` keep it.
func applyCommitModeTransition(after committedText: String, to engineSession: OwlRustSession) {
  guard committedText == "$" else { return }
  engineSession.setOption(.asciiMode, true)
}

extension OwlInputController {

  func consumeCommittedText() {
    guard let text = engineSession?.takeCommit() else { return }
    // ID-marked unified candidates bypass normal input formatting. Ordinary commits do no IO.
    if text.hasPrefix(OwlTemplateStore.candidatePrefix) {
      let code = MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshots.current?.rawInput }
        ?? engineSession?.lastCommittedInput()
      let entry = OwlTemplateStore.resolveCandidate(code: code, text: text) {
        try OwlTemplateStore.load()
      }
      let capturedClient = client
      clearHostComposition()
      hidePalettes()
      MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.noteCommit() }
      // A stale/deleted/renamed record must never leak its marker or insert a different body.
      guard let entry else { return }
      let broker = OwlPanelInsertionBroker()
      broker.capture()
      invokeTemplate(.template(entry), broker: broker, capturedClient: capturedClient)
      return
    }
    commit(string: text)
    if let engineSession {
      applyCommitModeTransition(after: text, to: engineSession)
    }
  }

  /// The candidate's code is still marked text in the host. Clear it before a window can take
  /// focus: a host that loses focus with marked text commits the raw code. Assigning `preedit`
  /// alone sends nothing, and the next empty update is skipped as empty-to-empty.
  func clearHostComposition() {
    show(preedit: "", selRange: NSRange(location: 0, length: 0), caretPos: 0)
    preedit = ""
  }

  /// Every route delivers the same Result, including a literal trailing delimiter. A later
  /// panel callback may not borrow the active-session exception of this synchronous call.
  func invokeTemplate(_ content: OwlTemplateInvocation.Content,
                      broker: OwlPanelInsertionBroker, capturedClient: IMKTextInput?,
                      trailingText: String = "", intent: OwlTemplateInvocation.Intent = .insert,
                      target: OwlTemplateHostDelivery? = nil,
                      automaticSource: OwlTemplateHostDelivery.AutomaticSource? = nil) {
    let delivery = target ?? OwlTemplateHostDelivery(controller: self, client: capturedClient, automaticSource: automaticSource)
    let invocation = OwlTemplateInvocation(content: content, broker: broker, delivery: delivery,
      trailingText: trailingText, intent: intent, prepareAutomaticSource: automaticSource != nil)
    let begin = {
      MainActor.assumeIsolated { OwlPromptFillSheet.shared.begin(invocation: invocation) }
      delivery.endImmediateDelivery()
    }
    if isHandlingKeyEvent { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: begin) } else { begin() }
  }

  func engineUpdate() {
    // print("[DEBUG] engineUpdate")
    guard let engineSession else { return }
    defer { MainActor.assumeIsolated { OwlInputStatusPanel.shared.refresh(self) } }
    let updateTrace = OwlLatencyTrace.begin("composition.update")
    defer { OwlLatencyTrace.end("composition.update", updateTrace) }
    // Same engine call order as before, only the call SITE moved behind the seam:
    //   takeCommit (get_commit/free_commit) → status (get_status/free_status) →
    //   [no_inline/inline/soft_cursor option calls] → composition (get_context/free_context)
    //   → input (get_input). The Live adapter does the C-struct alloc→read→free internally,
    //   so the only ordering nuance is that `free_status` now happens inside `status()`
    //   (i.e. before the option reads); freeing the status struct is independent of those
    //   option queries, so the behaviour is identical.
    defer { punctuationKeyInFlight = nil }
    consumeCommittedText()
    rememberAppInputMode()

    if let status = engineSession.status() {
      // enable schema specific ui style. The value type maps a null `schema_id` C pointer
      // to "" (the engine never reports a non-null empty schema_id during composition), so a
      // non-empty `schemaId` here matches the old `if let schema_id = status.schema_id`.
      if !status.schemaId.isEmpty, schemaId == "" || schemaId != status.schemaId {
        schemaId = status.schemaId
        pinnedWordsRevision = nil
        syncPinnedWords()
        MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.noteSchemaChange() }
        engineRuntime.loadSettings(for: schemaId)
      }
      // inline 旗标每轮重算（2026-07-12 B3 破闩锁）：原先只在上面 schema 变化分支里算一次——
      // delegate styleFlags 若在毒化后恢复（见 loadSettings 的先验后换契约），老控制器永远陷在
      // 占位模式。get_option 是进程内 引擎调用（零 IPC 往返），每键重算可承受；styleFlags
      // 读 delegate 缓存值不重开 config。soft_cursor 只在首轮或值变化时下发，避免每键 set_option。
      let styleFlags = engineRuntime.styleFlags
      let resolved = OwlStyleFlags.sessionInline(
        style: styleFlags, noInline: engineSession.option(.noInline), inlineForced: engineSession.option(.inline))
      if !styleFlagsSynced || resolved.preedit != inlinePreedit || resolved.candidate != inlineCandidate {
        debugLiveInputTrace(
          "flags sync inlinePreedit=\(inlinePreedit)->\(resolved.preedit) inlineCandidate=\(inlineCandidate)->\(resolved.candidate)"
            + " styleInline=\(styleFlags.inlinePreedit) firstSync=\(!styleFlagsSynced)")
        styleFlagsSynced = true
        inlinePreedit = resolved.preedit
        inlineCandidate = resolved.candidate
        // The candidate panel now draws its OWN structured caret at cursor_pos (a SwiftUI bar
        // between the 已输入/待输入 preedit runs — see OwlCandidatePanelView.header), so the engine's
        // soft_cursor ‸ symbol must stay OUT of the preedit string in BOTH modes. Inline preedit
        // already had it off; forcing false here also drops the stray ‸ the self-drawn panel used
        // to render at the real cursor. cursor_pos itself is unaffected by this option.
        engineSession.setOption(.softCursor, false)
      }
    }

    if let composition = engineSession.composition() {
      // Byte→UTF-16 index math + inline-preview assembly now live in the pure
      // EngineCompositionRenderer (C3): it returns the marked-text to show, plus the
      // raw-preedit caret (UTF-16) that the composition Snapshot records.
      let marked = EngineCompositionRenderer.markedText(
        composition: composition, inlinePreedit: inlinePreedit, inlineCandidate: inlineCandidate)
      show(preedit: marked.preedit + (pendingPairedClosing ?? ""), selRange: marked.selRange, caretPos: marked.caretPos)

      // update candidates. The value type already decoded the C arrays (null comment → nil,
      // labels resolved with the same select_keys/select_labels precedence as before); the
      // controller keeps its old `[String]` shape (null comment → "") for the panel API.
      let candidates = composition.candidates.map { OwlTemplateStore.candidateDisplay($0.text) }
      let comments = composition.candidates.map { $0.comment ?? "" }
      let labels = composition.labels
      let page = composition.pageNo
      let lastPage = composition.isLastPage

      // The panel always receives the RAW preedit + caret, in BOTH inline modes: whether the
      // 输入串+光标 header shows is owned by the「候选窗显示输入串」toggle
      // (OwlPanelShowPreedit → state.showPreedit → OwlCandidatePanelView.showsHeader)，
      // 且竖排下恒隐藏（07-26：铺满形态，见 showsHeader 注释）。
      // Blanking it under inline_preedit made that toggle unreachable — the factory config
      // ships inline_preedit=true, so the header could never appear.
      showPanel(preedit: composition.preedit,
                cursor: marked.preeditCaretUTF16,
                selStart: marked.preeditSelStartUTF16,
                selEnd: marked.preeditSelEndUTF16,
                candidates: candidates, comments: comments, labels: labels, highlighted: composition.highlightedIndex,
                page: page, lastPage: lastPage, pageSize: composition.pageSize)
      let snapCount = min(candidates.count, OwlCompositionSnapshot.defaultTopN)
      let snaps = (0..<snapCount).map { i in
        EngineCandidateSnapshot(index: i, text: candidates[i], comment: comments[i].isEmpty ? nil : comments[i], quality: nil)
      }
      let rawInput = engineSession.input() ?? ""
      MainActor.assumeIsolated {
        NSApp.owlAppDelegate.snapshotEmitter.emitComposing(
          sessionID: engineSession.sessionID, schemaID: schemaId, rawInput: rawInput,
          preedit: composition.preedit, cursor: marked.preeditCaretUTF16, pageNo: page, candidates: snaps)
      }
    } else {
      hidePalettes()
      resetAICandidateRuntime()
      MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.emitCleared() }
    }
    // This is the normal idle boundary after a key or candidate selection. The delegate is a
    // no-op unless a resource-generation switch is queued.
    MainActor.assumeIsolated {
      engineRuntime.applyPendingLiveSessionRefreshIfIdle()
    }
  }

  func commit(string: String) {
    guard let client = client else {
      // client==nil here means the text is silently DROPPED (forced finalize racing a client
      // detach). Zero observability made exactly this class of loss hard to diagnose (07-07);
      // trace the DECISION only — length, never the text (backend/logging-guidelines.md).
      debugLiveInputTrace("commit dropped client=nil len=\(string.count)")
      return
    }
    // print("[DEBUG] commitString: \(string)")
    // Side-effect convergence (task 06-22): the ONLY insertText call goes through apply().
    // `lastCommittedCharacter` seeds cross-commit spacing (中文|英文 across two commits); update it
    // to the trailing char actually inserted so the NEXT commit can space against this one.
    // Order (task 07-02): spacing transform FIRST, auto-pair decision on the TRANSFORMED text.
    // Pair-table chars are neither CJK nor Latin/digit for the spacing boundary, so the transform
    // is identity on them — the order is inert in practice, fixed here so the decision input is
    // well-defined (transform identity on pair chars is locked by OwlAutoPairTests).
    let transformed = OwlCommitTransform.apply(to: string, previous: lastCommittedCharacter)
    if usesNativePairedPunctuation {
      commitNativePairedPunctuation(transformed, client: client)
    } else if pendingPairedClosing != nil {
      // A live settings change must still close the pair already owned by this host.
      let closing = pendingPairedClosing ?? ""
      pendingPairedClosing = nil
      apply(.insertText(transformed + closing), client: client)
      lastCommittedCharacter = (transformed + closing).last
    } else {
      // Switch OFF: byte-identical to the pre-07-02 commit path.
      apply(.insertText(transformed), client: client)
      lastCommittedCharacter = transformed.last
    }
    noteSmartPunctuationCommit(transformed)
    preedit = ""
    hidePalettes()
    MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.noteCommit() }
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    // #89（spec #88 §3，spike #87 绿灯）：这里曾有「内容相同即跳过」的去重守卫（Squirrel
    // show() 同款），是 Chromium omnibox 退格全退的根因——合成期静默回合的按键被宿主重派
    // 为原始键。现行契约 = 每个被引擎消费的按键都同步重发 setMarkedText；唯一短路 =
    // 空→空（闲置轮，维持零 IPC 现状）。决策与依据见 OwlMarkedTextResendPolicy。
    guard OwlMarkedTextResendPolicy.shouldSend(previous: self.preedit, next: preedit) else {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // #90（G2）：把每次真落地的 setMarkedText 计量成可判读 trace——只记长度 + keep-alive 布尔
    // （#88 §4 隐私，绝不记文本）。判读：合成期 `markedText send` 行数 = 每键重发计数；ESC/删空后
    // 末条应 `len=0`（客户端 marked text 被清 = 无 zws 残留）；`len=1 keepAlive=true` = zws 兜底
    // 回合。区别于下方 apply() 里 `OwlLatencyTrace("markedText.apply")` 那个 #34 IPC 计量 signpost。
    debugLiveInputTrace("markedText send len=\(preedit.utf16.count) keepAlive=\(preedit == EngineCompositionRenderer.compositionKeepAlive) sel=\(selRange.length)")

    // Side-effect convergence (task 06-22): the ONLY setMarkedText call goes through apply().
    // apply() reconstructs the highlight attributes exactly as this method used to inline.
    apply(.setMarkedText(preedit: preedit, selRange: selRange, caretPos: caretPos), client: client)
  }

  func showPanel(preedit: String, cursor: Int, selStart: Int, selEnd: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool, pageSize: Int) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    // 多行「翻页才展开」旗标：page > 0 = 本次组字翻过页 → 置位。置位后组字期内保持
    // （翻回第一页、追打字母都不收起）；复位在 hidePalettes()——commit、失焦、空 menu
    // 的收尾都汇聚到那里。放在 client guard 之前，别让 client 缺席漏记一次翻页。
    if page > 0, !candidates.isEmpty {
      scrollDidPage = true
    }
    guard let client = client else { return }
    let policy = clientCapabilityDecisions(for: client)

    // ponytail: Chromium/Electron deadlock guard. showPanel runs for every composition, but with
    // zero candidates there is nothing to anchor — and the caret query below
    // (client.attributes(forCharacterIndex:)) is a SYNCHRONOUS round-trip that can deadlock the IME
    // when a host holds a lock (Chrome's JS compiler). No candidates → hide the panel and bail
    // BEFORE any client round-trip. azooKey guards identically (0 visible rows → return early).
    guard OwlCandidateAnchor.shouldQueryCaret(candidateCount: candidates.count) else {
      hidePalettes()
      return
    }

    // Anchor the candidate panel at character 0 of the marked text — exactly what stock
    // Squirrel does, and what Owltype did before commit c8f67ac ("B4 — anchor at caret end").
    //
    // B4 added a SECOND query at the caret end (`attributes(forCharacterIndex: caretIndex)`,
    // a non-zero index) so a long wrapped preedit would anchor on the caret's line instead of
    // a line too high. But a NON-ZERO-index `attributes(forCharacterIndex:)` re-enters the
    // host's text layout, and in clients that run macOS inline predictions over a rich
    // NSTextView it DEADLOCKS — input freezes entirely (confirmed live in TextEdit: every key
    // is swallowed, nothing commits; Apple FB13789916 — bogus marked-text range during Pinyin
    // composition). Index 0 is always a valid anchor and never triggers this, which is why
    // stock Squirrel composes fine in those same clients. We match Squirrel: query only
    // index 0. `caretRect` stays empty, so the B3 resolve cascade below falls straight through
    // to the char-0 `headRect`.
    //
    // Re-introducing caret-line anchoring for wrapped preedits must NOT use a non-zero-index
    // client round-trip — it needs a query-free method (e.g. deriving the caret line from the
    // char-0 rect + line metrics). Until then, char-0 is correct and safe everywhere.
    var headRect = NSRect()
    if policy.caretAttributes.allowed {
      client.attributes(forCharacterIndex: 0, lineHeightRectangle: &headRect)
    } else {
      debugLiveInputTrace("policy deny caretAttributes reason=\(policy.caretAttributes.diagnosticReason)")
    }

    // B3 — anchor validation cascade. The IMK client can hand back a junk caret rect
    // (.zero / infinite / NaN coord / zero-height / off-screen — Electron/WebKit/terminals,
    // or right after a focus change). Resolve first-usable caret-end → char-0 head → last-good
    // anchor → a safe on-screen rect, so the panel/HUD never fly to the screen origin and we
    // never store junk as the last-good anchor. caret-end and head are both "this
    // composition"; the head rect preserves the pre-B4 char-0 behavior as the fallback. For a
    // single-line / short preedit the two rects are on the same line → positioning is unchanged.
    //
    // The last-good anchor is scoped to THIS host (`OwlHostCaretAnchorMemory`): it used to be one
    // process-wide rect, so a host whose rect is always rejected (WeChat) inherited the previous
    // app's anchor and — on a multi-display setup — opened its candidate bar on that app's screen.
    // A different host now reads `nil` here and falls through to `safeFallbackAnchor()`.
    let host = hostIdentity(for: client)
    let resolvedAnchor = OwlCandidateAnchor.resolve(
      candidates: [headRect],
      previous: NSApp.owlAppDelegate.lastCaretAnchor(forHost: host),
      screens: NSScreen.screens.map(\.frame)
    ) ?? Self.safeFallbackAnchor()
    let inputPos = resolvedAnchor

    // SwiftUI is the sole candidate renderer. Record the caret anchor + active controller
    // on the delegate so the status HUD can position near the caret and `finalizeStranded
    // Composition` can reach the controller (was `panel.position` / `panel.inputController`).
    NSApp.owlAppDelegate.recordCaretAnchor(inputPos, host: host)
    engineRuntime.activeInputController = self
    engineRuntime.registerLiveController(self)

    let isVertical = engineSession?.option(.vertical) ?? false
    let candidatePanelSettings = OwlCandidatePanelSettings.live.snapshot()
    let currentSessionID = engineSession?.sessionID ?? 0

    // 多行（翻页才展开，2026-07-28）：本次组字翻过页后，预取紧邻的前 1 页 + 有界上限 4 个后页。
    // 面板按 runtime snapshot 的 scrollRows 限制可见后页，因此设置从 1 调到 4 时无需再次触碰
    // Rime 就能即时揭示已经预取的行；默认仍是 4，取数上限没有扩大。
    // 没翻过页时保持单行——展开是翻页动作换来的。取数走 `peekCandidates`（the engine
    // candidate_list_from_index 只读迭代器）——不真翻页、不动 menu 页游标、无 IMK 客户端
    // 往返，故不在 Chromium 死锁禁区内。页宽用 引擎的 page_size：末页 candidates.count
    // 不满页，拿它当页宽会把前页的绝对下标全算错。
    var prevPeeked: [EngineCandidate]?
    var nextPeeked: [EngineCandidate]?
    if let engineSession, pageSize > 0 {
      if OwlScrollRowsPlan.wantsPrevRow(
        settings: candidatePanelSettings, didPage: scrollDidPage, page: page,
        candidateCount: candidates.count,
        engineVertical: isVertical, schemaID: schemaId
      ) {
        prevPeeked = engineSession.peekCandidates(from: (page - 1) * pageSize, count: pageSize)
      }
      if OwlScrollRowsPlan.wantsRows(
        settings: candidatePanelSettings, didPage: scrollDidPage, lastPage: lastPage,
        candidateCount: candidates.count,
        engineVertical: isVertical, schemaID: schemaId
      ) {
        nextPeeked = engineSession.peekCandidates(from: (page + 1) * pageSize,
                                         count: OwlCandidatePanelSettings.maximumScrollRows * pageSize)
      }
    }

    let currentGen = engineSession?.generation ?? 0
    var scrollRows: [OwlScrollRow] = []
    if let prevPeeked {
      scrollRows += OwlScrollRowsPlan.rows(
        from: prevPeeked, pageSize: pageSize, startPage: page - 1,
        sessionID: currentSessionID, generation: currentGen
      )
    }
    if let nextPeeked {
      scrollRows += OwlScrollRowsPlan.rows(
        from: nextPeeked, pageSize: pageSize, startPage: page + 1,
        sessionID: currentSessionID, generation: currentGen
      )
    }

    currentHighlightedCandidateIndex = highlighted
    lastPanelComposition = OwlPanelCompositionParams(
      preedit: preedit,
      cursor: cursor,
      selStart: selStart,
      selEnd: selEnd,
      candidates: candidates,
      comments: comments,
      labels: labels,
      highlighted: highlighted,
      page: page,
      lastPage: lastPage,
      pageSize: pageSize
    )

    var engineModels: [CandidateViewModel] = candidates.indices.map { i in
      let text = candidates[i]
      let rawComment = i < comments.count ? comments[i] : nil
      return CandidateViewModel(
        id: i,
        label: i < labels.count ? labels[i] : "",
        text: text,
        comment: rawComment,
        token: OwlCandidateToken(
          sessionID: currentSessionID,
          generation: currentGen,
          candidateID: i,
          isAbsolute: false
        )
      )
    }

    OwlAICandidateLayout.applyJevRerank(
      into: &engineModels,
      elevatedIndex: activeJevRerankIndex,
      ticket: activeJevRerankTicket,
      currentSessionID: currentSessionID,
      currentGen: currentGen,
      rawInput: engineSession?.input() ?? "",
      page: page,
      labels: labels,
      allLocalCandidates: activeJevLocalCandidates
    )

    activeAICandidateSlot = OwlAICandidateLayout.applyAICandidate(
      into: &engineModels,
      activeAICandidates: activeAICandidates,
      activeAICandidateTicket: activeAICandidateTicket,
      currentSessionID: currentSessionID,
      currentGen: currentGen,
      rawInput: engineSession?.input() ?? "",
      page: page,
      pageSize: pageSize,
      labels: labels
    )
    lastComposedCandidates = engineModels

    let owlPanel = NSApp.owlAppDelegate.ensureOwltypePanel()
    let pinInput = engineSession?.input() ?? ""
    let pinSession = engineSession?.sessionID ?? 0
    owlPanel.canPin = { [weak self] text in self?.pinnedTarget(text: text) != nil }
    owlPanel.onPin = { [weak self] text in
      guard let self, self.engineSession?.sessionID == pinSession, self.engineSession?.input() == pinInput else { return }
      self.togglePinnedWord(text: text)
    }
    owlPanel.onRemove = { [weak self] token in _ = self?.removeCandidate(token) }
    owlPanel.onSelect = { [weak self] index in self?.selectPanelIndex(index) }
    owlPanel.onPage = { [weak self] up in _ = self?.page(up: up) }
    owlPanel.onSelectAbsolute = { [weak self] index in _ = self?.selectCandidateAbsolute(index) }
    owlPanel.onSelectToken = { [weak self] token in
      if token.candidateID == 999_999, let aiText = self?.activeAICandidates.first {
        self?.commitAICandidate(text: aiText)
        return
      }
      _ = self?.selectCandidate(token)
    }
    let content = OwlPanelContent(
      preedit: preedit,
      cursor: cursor,
      selStart: selStart,
      selEnd: selEnd,
      candidates: engineModels,
      highlightedIndex: highlighted,
      page: page,
      hasPrevPage: page > 0,
      hasNextPage: !lastPage,
      isVertical: isVertical,
      schemaID: schemaId,
      anchor: inputPos,
      scrollRows: scrollRows
    )
    let panelTrace = OwlLatencyTrace.begin("candidatePanel.update")
    _ = owlPanel.update(content, settings: candidatePanelSettings)
    OwlLatencyTrace.end("candidatePanel.update", panelTrace)
    if OwlCandidateAnchor.shouldScheduleDelayedReposition(
      policyAllows: policy.delayedCandidatePositioning.allowed,
      panelIsVisible: owlPanel.isVisible,
      candidateCount: candidates.count
    ) {
      scheduleDelayedCandidateReposition(client: client, panel: owlPanel, candidateCount: candidates.count)
    }
  }

  /// Selection routing for a clicked / selected panel `index`.
  func selectPanelIndex(_ index: Int) {
    if activeAICandidateSlot == index, let aiText = activeAICandidates.first {
      commitAICandidate(text: aiText)
      return
    }
    if index >= 0, index < lastComposedCandidates.count {
      let token = lastComposedCandidates[index].token
      if token.candidateID != 999_999 {
        _ = selectCandidate(token)
        return
      }
    }
    _ = selectCandidate(index)
  }

  /// A safe on-screen anchor when neither the fresh nor the last-good caret rect is usable
  /// (B3 cascade tail). A small rect near the top-center of the main screen — keeps the panel
  /// on a real display instead of the origin. Off the hot-path math; only fires on junk anchors.
  static func safeFallbackAnchor() -> NSRect {
    OwlCandidateAnchor.safeFallbackAnchor(screens: NSScreen.screens.map(\.frame))
  }

  /// The host app identity used to scope per-app state — the client-capability policy and the
  /// last-good caret anchor. `bundleIdentifier()`, with the session's `currentApp` standing in for
  /// clients that report none; `nil` when neither is known.
  private func hostIdentity(for client: IMKTextInput) -> String? {
    client.bundleIdentifier() ?? (currentApp.isEmpty ? nil : currentApp)
  }

  func clientCapabilityDecisions(for client: IMKTextInput) -> OwlClientCapabilities {
    let bundleID = hostIdentity(for: client)
    return NSApp.owlAppDelegate.clientCapabilityPolicy.evaluate(
      OwlClientCapabilityInput(
        host: OwlClientHostIdentity(
          bundleID: bundleID,
          // 08-17（Cursor 候选窗不跟随）：Electron 宿主不再靠名单认——探测宿主包里是否真带
          // Electron Framework。探测按 bundleID 全程缓存，热路径上是一次字典查找。
          linksElectronFramework: OwlElectronHostDetector.shared.linksElectron(bundleID: bundleID)
        ),
        privacy: .current(),
        workarounds: NSApp.owlAppDelegate.clientWorkarounds
      )
    )
  }

  private func scheduleDelayedCandidateReposition(
    client: IMKTextInput,
    panel: OwlSwiftUICandidatePanel,
    candidateCount: Int
  ) {
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let self, let panel, panel.isVisible,
            OwlCandidateAnchor.shouldQueryCaret(candidateCount: candidateCount) else { return }
      if let current = self.client, (current as AnyObject) !== (client as AnyObject) {
        return
      }
      let policy = self.clientCapabilityDecisions(for: client)
      guard policy.caretAttributes.allowed else { return }

      let repositionTrace = OwlLatencyTrace.begin("candidatePanel.delayedReposition")
      defer { OwlLatencyTrace.end("candidatePanel.delayedReposition", repositionTrace) }

      var delayedHead = NSRect()
      client.attributes(forCharacterIndex: 0, lineHeightRectangle: &delayedHead)
      let screens = NSScreen.screens.map(\.frame)
      let host = self.hostIdentity(for: client)
      guard let anchor = OwlCandidateAnchor.resolve(
        candidates: [delayedHead],
        previous: NSApp.owlAppDelegate.lastCaretAnchor(forHost: host),
        screens: screens
      ) else { return }
      NSApp.owlAppDelegate.recordCaretAnchor(anchor, host: host)
      panel.reposition(anchor: anchor)
    }
  }
}
