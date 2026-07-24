//
//  FamoInputController+RimeUpdate.swift
//  Famo
//
//  Single responsibility: pull librime's commit/status/composition state and push it to
//  IMK marked text and the candidate panel (the preedit/candidate byte→UTF-16 index math).
//  Moved verbatim out of FamoInputController.swift (god-object shrink, 2026-06-20) — the
//  index math is intricate and was moved byte-for-byte; no logic edits.
//

import ApplicationServices
import InputMethodKit

extension FamoInputController {

  func rimeConsumeCommittedText() {
    guard let text = rime?.takeCommit() else { return }
    // 提示词提交拦截 (task 06-30-famo-prompt-management-panel). This is the UNIVERSAL commit
    // chokepoint (keyboard space/digit AND panel click both funnel here), so a 提示词 candidate
    // selected ANY way is caught. Recover the originating code from the PRIOR composition snapshot —
    // librime has already cleared `rime.input()` by commit time, but `snapshots.current` still holds
    // the composition that showed the prompt candidate. The decision is a pure function over the
    // injected `promptStore` port (fakeable, no librime); only a 📝-marked title even reaches the
    // store lookup, so ordinary pinyin commits pass straight through. Mirrors the slash-key
    // precedent (commit out-of-band + cancel the normal commit).
    let action: FamoPromptCommitAction = MainActor.assumeIsolated {
      let code = NSApp.famoAppDelegate.snapshots.current?.rawInput
      return resolvePromptCommit(code: code, committedTitle: text, store: NSApp.famoAppDelegate.promptStore)
    }
    switch action {
    case .passThrough:
      commit(string: text)
    case .insert(let body):
      insertPromptBody(body)
    case .fillIn(let entry):
      presentPromptFillSheet(for: entry)
    }
  }

  /// 命中提示词、无变量：取消正常候选提交，把 `body` **逐字节**插入光标处（直接走 `apply`，绕过
  /// 中英空格 transform，正文带换行原样落字）。其余收尾镜像 `commit(string:)`。
  private func insertPromptBody(_ body: String) {
    guard let client else { return }
    apply(.insertText(body), client: client)
    preedit = ""
    hidePalettes()
    MainActor.assumeIsolated { NSApp.famoAppDelegate.snapshotEmitter.noteCommit() }
  }

  /// 命中提示词、含 `{{变量}}`：先取消正常候选提交（合成已被 librime 清空，这里收尾面板 / preedit），
  /// 捕获当前 `client`，弹**非激活**填空 sheet；用户确认（[插入]/Enter）→ 用 `substitute` 替换好的
  /// 正文 `insertText` 到原宿主；取消（Esc/[取消]）→ 什么都不插。焦点交还宿主后才插字。
  private func presentPromptFillSheet(for entry: FamoPromptEntry) {
    preedit = ""
    hidePalettes()
    MainActor.assumeIsolated { NSApp.famoAppDelegate.snapshotEmitter.noteCommit() }
    let client = self.client
    MainActor.assumeIsolated {
      FamoPromptFillSheet.shared.present(entry: entry) { [weak self] filledBody in
        guard let self, let filledBody, let client else { return }
        self.apply(.insertText(filledBody), client: client)
      }
    }
  }

  /// Insert a 提示词 picked from the quick-phrase PANEL (task 07-01), NOT the 📝 candidate chokepoint.
  /// The panel captured the client up-front and restored host focus before calling this, so we insert
  /// through the passed `capturedClient` — NEVER `self.client`, which the key panel may have nil'd
  /// (same reason `showFamoQuickSend` captures the client for the 短语 path). No variables → insert
  /// `body` directly; has variables → the same non-activating fill sheet, its filled body inserted
  /// through the same captured client on confirm. No composition to clean up (panel-summoned, so
  /// there is no pending preedit/candidate state — unlike the commit chokepoint).
  func insertPickedPrompt(_ entry: FamoPromptEntry, capturedClient: IMKTextInput?) {
    guard let capturedClient else { return }
    if entry.variables.isEmpty {
      apply(.insertText(entry.body), client: capturedClient)
    } else {
      MainActor.assumeIsolated {
        FamoPromptFillSheet.shared.present(entry: entry) { [weak self] filledBody in
          guard let self, let filledBody else { return }
          self.apply(.insertText(filledBody), client: capturedClient)
        }
      }
    }
  }

  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    guard let rime else { return }
    let updateTrace = FamoLatencyTrace.begin("composition.update")
    defer { FamoLatencyTrace.end("composition.update", updateTrace) }
    // Same librime call order as before, only the call SITE moved behind the seam:
    //   takeCommit (get_commit/free_commit) → status (get_status/free_status) →
    //   [no_inline/inline/soft_cursor option calls] → composition (get_context/free_context)
    //   → input (get_input). The Live adapter does the C-struct alloc→read→free internally,
    //   so the only ordering nuance is that `free_status` now happens inside `status()`
    //   (i.e. before the option reads); freeing the status struct is independent of those
    //   option queries, so the behaviour is identical.
    rimeConsumeCommittedText()

    if let status = rime.status() {
      // enable schema specific ui style. The value type maps a null `schema_id` C pointer
      // to "" (librime never reports a non-null empty schema_id during composition), so a
      // non-empty `schemaId` here matches the old `if let schema_id = status.schema_id`.
      if !status.schemaId.isEmpty, schemaId == "" || schemaId != status.schemaId {
        schemaId = status.schemaId
        MainActor.assumeIsolated { NSApp.famoAppDelegate.snapshotEmitter.noteSchemaChange() }
        NSApp.famoAppDelegate.loadSettings(for: schemaId)
      }
      // inline 旗标每轮重算（2026-07-12 B3 破闩锁）：原先只在上面 schema 变化分支里算一次——
      // delegate styleFlags 若在毒化后恢复（见 loadSettings 的先验后换契约），老控制器永远陷在
      // 占位模式。get_option 是进程内 librime 调用（零 IPC 往返），每键重算可承受；styleFlags
      // 读 delegate 缓存值不重开 config。soft_cursor 只在首轮或值变化时下发，避免每键 set_option。
      let styleFlags = NSApp.famoAppDelegate.styleFlags
      let resolved = FamoStyleFlags.sessionInline(
        style: styleFlags, noInline: rime.option(.noInline), inlineForced: rime.option(.inline))
      if !styleFlagsSynced || resolved.preedit != inlinePreedit || resolved.candidate != inlineCandidate {
        debugLiveInputTrace(
          "flags sync inlinePreedit=\(inlinePreedit)->\(resolved.preedit) inlineCandidate=\(inlineCandidate)->\(resolved.candidate)"
            + " styleInline=\(styleFlags.inlinePreedit) firstSync=\(!styleFlagsSynced)")
        styleFlagsSynced = true
        inlinePreedit = resolved.preedit
        inlineCandidate = resolved.candidate
        // The candidate panel now draws its OWN structured caret at cursor_pos (a SwiftUI bar
        // between the 已输入/待输入 preedit runs — see FamoCandidatePanelView.header), so librime's
        // soft_cursor ‸ symbol must stay OUT of the preedit string in BOTH modes. Inline preedit
        // already had it off; forcing false here also drops the stray ‸ the self-drawn panel used
        // to render at the real cursor. cursor_pos itself is unaffected by this option.
        rime.setOption(.softCursor, false)
      }
    }

    if let composition = rime.composition() {
      // Byte→UTF-16 index math + inline-preview assembly now live in the pure
      // RimeCompositionRenderer (C3): it returns the marked-text to show, plus the
      // raw-preedit caret (UTF-16) that the composition Snapshot records.
      let marked = RimeCompositionRenderer.markedText(
        composition: composition, inlinePreedit: inlinePreedit, inlineCandidate: inlineCandidate)
      show(preedit: marked.preedit, selRange: marked.selRange, caretPos: marked.caretPos)

      // update candidates. The value type already decoded the C arrays (null comment → nil,
      // labels resolved with the same select_keys/select_labels precedence as before); the
      // controller keeps its old `[String]` shape (null comment → "") for the panel API.
      let candidates = composition.candidates.map { $0.text }
      let comments = composition.candidates.map { $0.comment ?? "" }
      let labels = composition.labels
      let page = composition.pageNo
      let lastPage = composition.isLastPage

      // The panel always receives the RAW preedit + caret, in BOTH inline modes: whether the
      // 输入串+光标 header shows is owned by the「候选窗显示输入串」toggle alone
      // (FamoPanelShowPreedit → state.showPreedit → FamoCandidatePanelView.showsHeader).
      // Blanking it under inline_preedit made that toggle unreachable — the factory config
      // ships inline_preedit=true, so the header could never appear.
      showPanel(preedit: composition.preedit,
                cursor: marked.preeditCaretUTF16,
                selStart: marked.preeditSelStartUTF16,
                selEnd: marked.preeditSelEndUTF16,
                candidates: candidates, comments: comments, labels: labels, highlighted: composition.highlightedIndex,
                page: page, lastPage: lastPage)
      let snapCount = min(candidates.count, FamoCompositionSnapshot.defaultTopN)
      let snaps = (0..<snapCount).map { i in
        RimeCandidateSnapshot(index: i, text: candidates[i], comment: comments[i].isEmpty ? nil : comments[i], quality: nil)
      }
      let rawInput = rime.input() ?? ""
      MainActor.assumeIsolated {
        NSApp.famoAppDelegate.snapshotEmitter.emitComposing(
          sessionID: rime.sessionID, schemaID: schemaId, rawInput: rawInput,
          preedit: composition.preedit, cursor: marked.preeditCaretUTF16, pageNo: page, candidates: snaps)
      }
    } else {
      hidePalettes()
      MainActor.assumeIsolated { NSApp.famoAppDelegate.snapshotEmitter.emitCleared() }
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
    // well-defined (transform identity on pair chars is locked by FamoAutoPairTests).
    let transformed = FamoCommitTransform.apply(to: string, previous: lastCommittedCharacter)
    if FamoKeyboardPreferences.autoPairBrackets {
      commitApplyingAutoPair(transformed, client: client)
    } else {
      // Switch OFF: byte-identical to the pre-07-02 commit path.
      apply(.insertText(transformed), client: client)
      lastCommittedCharacter = transformed.last
    }
    preedit = ""
    hidePalettes()
    MainActor.assumeIsolated { NSApp.famoAppDelegate.snapshotEmitter.noteCommit() }
  }

  // MARK: - 自动配对括号 execution (task 07-02; decision layer = FamoAutoPair, pure + unit-tested)

  /// Insert one transformed commit applying the `FamoAutoPair` decision. Hard constraint from the
  /// PRD: content is NEVER damaged — in any app the worst outcomes are "caret after the closer"
  /// (pair degrade) or "duplicate closer" (skip-over degrade, = today's behavior).
  private func commitApplyingAutoPair(_ transformed: String, client: IMKTextInput) {
    let policy = clientCapabilityDecisions(for: client)
    // 写路径（自替换开括号 / 覆写重复闭括号）比读路径更严：insertText(replacementRange:) 的
    // 「替换」语义只在已知友好的 AppKit 宿主上可信——07-21 真机实锤 claudefordesktop（Electron，
    // 未入任何拒绝清单）只认 range 位置、不删除内容，把「内容中性的自替换」变成凭空插入
    // （`<` 菜单选 ASCII `<` → `<<>`）。探针只能验读、验不了写语义，故这里不吃 allowedDefault：
    // 只信 allowedAppKitClient（allowlist，语义与设置页「标准文本应用」文案一致）+ 用户显式
    // 强制放行。其余宿主降级：配对=光标在闭括号后；跳过=普通插入（与旧行为相同），内容永不损坏。
    let replaceSemanticsTrusted =
      policy.replacementRange.allowed
      && (policy.replacementRange.reason == .allowedAppKitClient
        || policy.replacementRange.reason == .userForcedAllow)
    // The right-neighbor read is an IPC round-trip: do it ONLY when the commit is exactly one
    // pair-table closer AND no composition is on screen. `preedit.isEmpty` gates out commits
    // confirmed from a live marked-text session (e.g. the `>` punctuator candidate menu), where
    // `selectedRange()` reflects pre-commit geometry — those degrade to today's plain insert.
    var caret: Int?
    var rightNeighbor: Character?
    if preedit.isEmpty, FamoAutoPair.singleCloser(in: transformed) != nil,
       policy.selectedRange.allowed, policy.surroundingText.allowed,
       let read = autoPairCaretAndRightNeighbor(client: client) {
      caret = read.caret
      rightNeighbor = read.neighbor
    } else if preedit.isEmpty, FamoAutoPair.singleCloser(in: transformed) != nil {
      debugLiveInputTrace(
        "policy deny autoPairRightNeighbor selectedRange=\(policy.selectedRange.diagnosticReason) surroundingText=\(policy.surroundingText.diagnosticReason)"
      )
    }
    let action = FamoAutoPair.decision(
      enabled: true,
      commitText: transformed,
      rightNeighbor: rightNeighbor,
      caretMoveAllowed: replaceSemanticsTrusted
    )
    // 观测：len + 判定 case + 写语义信任位（不记文本）。07-21 备忘录居中谜题的最后拼图——
    // 配对分支零日志只可能是提交文本非单开括号（.plain）或根本没走到这，此行让两者可分辨。
    debugLiveInputTrace(
      "commit autopair len=\(transformed.count) preeditEmpty=\(preedit.isEmpty) trusted=\(replaceSemanticsTrusted) action=\(actionLabel(action))")
    switch action {
    case .plain:
      apply(.insertText(transformed), client: client)
      lastCommittedCharacter = transformed.last

    case let .pair(open, close, caretMove):
      // 1. Content first — ONE insert of the full pair is correct in every app (a client that
      //    ignores replacementRange can never see wrong content; worst case the caret stays
      //    after the closer). This also ends any marked-text session exactly like a plain commit.
      apply(.insertText(open + close), client: client)
      // 2. Best-effort caret centering, allowlist apps only: self-replace the open bracket via
      //    replacementRange — content unchanged, caret lands right after it (= between the pair).
      //    The probe read verifies the target range really holds the open bracket, so even a
      //    host reporting stale geometry can only make us SKIP the move, never damage content.
      if caretMove {
        guard policy.selectedRange.allowed, policy.replacementRange.allowed, policy.surroundingText.allowed else {
          debugLiveInputTrace(
            "policy deny autoPairCaretMove selectedRange=\(policy.selectedRange.diagnosticReason) replacementRange=\(policy.replacementRange.diagnosticReason) surroundingText=\(policy.surroundingText.diagnosticReason)"
          )
          lastCommittedCharacter = open.last
          return
        }
        // 菜单确认的提交（`<` 符号选单等，此刻 self.preedit 仍是提交前的 marked 文本）：同步读
        // `selectedRange()` 拿到的是提交前几何（同 skip-over 闸门注释），探针必失配 → 居中被
        // 静默跳过（07-21 备忘录真机现象）。修法照 scheduleDelayedCandidateReposition 的范式：
        // 推迟一个 runloop tick 等宿主落定再探针+自替换；直接上屏（无 marked 会话）保持同步原路。
        if preedit.isEmpty {
          autoPairCenterCaret(open: open, close: close, client: client, origin: "sync")
        } else {
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 身份守卫从「必须同一实例」放宽为「有新 client 且不同才放弃」（对齐
            // scheduleDelayedCandidateReposition 的判法）：IMK 的 client 代理对象不保证
            // 跨回合同一，严格同一性会把居中永远闸死（07-21 备忘录真机现象的头号嫌疑）。
            if let current = self.client, (current as AnyObject) !== (client as AnyObject) {
              debugLiveInputTrace("autoPair centerCaret drop: client changed")
              return
            }
            self.autoPairCenterCaret(open: open, close: close, client: client, origin: "deferred")
          }
        }
      }
      // The char left of the caret is the OPEN bracket now (cross-commit spacing seed).
      lastCommittedCharacter = open.last

    case let .skipOver(close):
      // Overwrite the verified identical closer right of the caret — replacing `close` with
      // `close` is content-neutral ONLY when the host honors replace semantics（见上：一个
      // 只插入不删除的宿主会把它变成双写闭括号），so this too gates on replaceSemanticsTrusted.
      // `caret` is always set when the decision is `.skipOver` (the neighbor came from that read).
      if let caret, replaceSemanticsTrusted {
        apply(.insertTextInRange(close, replacementRange: NSRange(location: caret, length: close.utf16.count)), client: client)
      } else {
        apply(.insertText(close), client: client)
      }
      lastCommittedCharacter = close.last
    }
  }

  /// trace 用的判定标签（不含任何用户文本）。
  private func actionLabel(_ action: FamoAutoPairAction) -> String {
    switch action {
    case .plain: return "plain"
    case .pair(_, _, let caretMove): return "pair(move=\(caretMove))"
    case .skipOver: return "skipOver"
    }
  }

  /// 自动配对的光标居中：探针验证 caret-2 处确是刚插的开括号，再用内容中性的自替换把光标挪到
  /// 括号对中间。同步（直接上屏）与延迟一 tick（菜单确认，等几何落定）两条路共用本函数；任何
  /// 一步失配就静默跳过（光标留在闭括号后，内容不损坏）。
  /// 观测（#118 教训：静默失败出厂即隐身）：每个跳过分支都落 trace——只记几何数字与布尔，
  /// 绝不记文本（backend/logging-guidelines.md）。
  ///
  /// 07-21 备忘录实锤（`<>a`）：`insertText(replacementRange:)` 的「光标落在替换文本后」副作用
  /// 会被部分 AppKit 宿主忽略——内容换了、光标不动，trace 里 "moved" 却肉眼不居中。唯一各宿主
  /// 一致的落点控制是合成一次 ← 方向键（商业输入法同款）：内容零接触，误伤上限=光标左移一格，
  /// 且探针已验证光标紧跟在刚插入的完整括号对之后（挡住用户快打竞态）。需要辅助功能权限；
  /// 未授权时退回自替换（在部分宿主仍有效）。
  private func autoPairCenterCaret(open: String, close: String, client: IMKTextInput, origin: String) {
    let sel = client.selectedRange()
    guard sel.location != NSNotFound, sel.length == 0 else {
      debugLiveInputTrace("autoPair centerCaret[\(origin)] skip: sel loc=\(sel.location == NSNotFound ? -1 : sel.location) len=\(sel.length)")
      return
    }
    let openLength = open.utf16.count
    let pairLength = openLength + close.utf16.count
    let location = sel.location - pairLength
    guard location >= 0 else {
      debugLiveInputTrace("autoPair centerCaret[\(origin)] skip: location<0 sel=\(sel.location)")
      return
    }
    // 探针升级为验完整括号对（此前只验开括号）：←键比范围替换多一分动作性，验证就多一分。
    guard let probe = client.attributedSubstring(from: NSRange(location: location, length: pairLength)),
          probe.string == open + close else {
      debugLiveInputTrace("autoPair centerCaret[\(origin)] skip: probe miss at \(location)")
      return
    }
    if AXIsProcessTrusted() {
      postLeftArrowKeyEvent()
      debugLiveInputTrace("autoPair centerCaret[\(origin)] arrow at \(location)")
    } else {
      apply(.insertTextInRange(open, replacementRange: NSRange(location: location, length: openLength)), client: client)
      debugLiveInputTrace("autoPair centerCaret[\(origin)] replace-fallback at \(location)")
    }
  }

  /// 合成一次 ←（kVK_LeftArrow=123）到会话事件流。回流进 handle() 时无合成会话、原样放行给
  /// 宿主移动光标；仅在 AXIsProcessTrusted 时调用（未授权时 post 会被系统静默丢弃）。
  private func postLeftArrowKeyEvent() {
    let key = CGKeyCode(123)  // kVK_LeftArrow
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
  }

  /// Zero-permission caret + right-neighbor read (`selectedRange` + `attributedSubstring(from:)`,
  /// the IMK APIs — no Accessibility, no CGEvent). `nil` when there is a live selection, no valid
  /// caret, or the client can't serve the read — the decision then stays `.plain` (no damage).
  private func autoPairCaretAndRightNeighbor(client: IMKTextInput) -> (caret: Int, neighbor: Character)? {
    let sel = client.selectedRange()
    guard sel.location != NSNotFound, sel.length == 0 else { return nil }
    guard let attr = client.attributedSubstring(from: NSRange(location: sel.location, length: 1)),
          attr.string.count == 1, let neighbor = attr.string.first else { return nil }
    return (sel.location, neighbor)
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    // #89（spec #88 §3，spike #87 绿灯）：这里曾有「内容相同即跳过」的去重守卫（Squirrel
    // show() 同款），是 Chromium omnibox 退格全退的根因——合成期静默回合的按键被宿主重派
    // 为原始键。现行契约 = 每个被 rime 消费的按键都同步重发 setMarkedText；唯一短路 =
    // 空→空（闲置轮，维持零 IPC 现状）。决策与依据见 FamoMarkedTextResendPolicy。
    guard FamoMarkedTextResendPolicy.shouldSend(previous: self.preedit, next: preedit) else {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // #90（G2）：把每次真落地的 setMarkedText 计量成可判读 trace——只记长度 + keep-alive 布尔
    // （#88 §4 隐私，绝不记文本）。判读：合成期 `markedText send` 行数 = 每键重发计数；ESC/删空后
    // 末条应 `len=0`（客户端 marked text 被清 = 无 zws 残留）；`len=1 keepAlive=true` = zws 兜底
    // 回合。区别于下方 apply() 里 `FamoLatencyTrace("markedText.apply")` 那个 #34 IPC 计量 signpost。
    debugLiveInputTrace("markedText send len=\(preedit.utf16.count) keepAlive=\(preedit == RimeCompositionRenderer.compositionKeepAlive) sel=\(selRange.length)")

    // Side-effect convergence (task 06-22): the ONLY setMarkedText call goes through apply().
    // apply() reconstructs the highlight attributes exactly as this method used to inline.
    apply(.setMarkedText(preedit: preedit, selRange: selRange, caretPos: caretPos), client: client)
  }

  func showPanel(preedit: String, cursor: Int, selStart: Int, selEnd: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    let policy = clientCapabilityDecisions(for: client)

    // ponytail: Chromium/Electron deadlock guard. showPanel runs for every composition, but with
    // zero candidates there is nothing to anchor — and the caret query below
    // (client.attributes(forCharacterIndex:)) is a SYNCHRONOUS round-trip that can deadlock the IME
    // when a host holds a lock (Chrome's JS compiler). No candidates → hide the panel and bail
    // BEFORE any client round-trip. azooKey guards identically (0 visible rows → return early).
    guard FamoCandidateAnchor.shouldQueryCaret(candidateCount: candidates.count) else {
      hidePalettes()
      return
    }

    // Anchor the candidate panel at character 0 of the marked text — exactly what stock
    // Squirrel does, and what Famo did before commit c8f67ac ("B4 — anchor at caret end").
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
    // `lastCaretAnchor` → a safe on-screen rect, so the panel/HUD never fly to the screen origin
    // and we never store junk as `lastCaretAnchor`. caret-end and head are both "this
    // composition"; the head rect preserves the pre-B4 char-0 behavior as the fallback. For a
    // single-line / short preedit the two rects are on the same line → positioning is unchanged.
    let resolvedAnchor = FamoCandidateAnchor.resolve(
      candidates: [headRect],
      previous: NSApp.famoAppDelegate.lastCaretAnchor,
      screens: NSScreen.screens.map(\.frame)
    ) ?? Self.safeFallbackAnchor()
    let inputPos = resolvedAnchor

    // SwiftUI is the sole candidate renderer. Record the caret anchor + active controller
    // on the delegate so the status HUD can position near the caret and `finalizeStranded
    // Composition` can reach the controller (was `panel.position` / `panel.inputController`).
    NSApp.famoAppDelegate.lastCaretAnchor = inputPos
    NSApp.famoAppDelegate.activeInputController = self
    NSApp.famoAppDelegate.registerLiveController(self)

    // The inline AI candidate lane was removed: the candidate panel shows ONLY authoritative Rime
    // rows now, so there is no async store-driven merge/refresh. Build the Rime view models and push
    // them straight to the panel here (was the `lastRimePanel` cache + `renderPanel` merge step).
    let rimeModels: [CandidateViewModel] = candidates.indices.map { i in
      let text = candidates[i]
      let rawComment = i < comments.count ? comments[i] : nil
      // Law-citation candidates (from law_citation.lua) render as 《…》第…条… — surface
      // them with the 「法」 badge + a source line (the design's citation form) instead of
      // an inline note. Conservative shape match: won't fire on ordinary 《书名》 candidates.
      // NEEDS REAL-MACHINE VERIFICATION: the law layer isn't deployed on the dev box yet.
      let isCitation = text.hasPrefix("《") && text.contains("》第") && text.contains("条")
      // G3 provenance: the only signal available at this seam is the law-citation shape
      // (→ 规则; version unknown here so never 已核验). Ordinary Rime pinyin → nil (no label).
      let provenance = EnhancedCandidate.provenance(source: .rime, lane: .main, isLawObject: isCitation)
      return CandidateViewModel(
        id: i,
        label: i < labels.count ? labels[i] : "",
        text: text,
        comment: isCitation ? nil : rawComment,
        badge: isCitation,
        source: isCitation ? (rawComment?.isEmpty == false ? rawComment : nil) : nil,
        provenance: provenance
      )
    }

    let isVertical = rime?.option(.vertical) ?? false
    let famo = NSApp.famoAppDelegate.ensureFamoPanel()
    famo.onSelect = { [weak self] index in self?.selectPanelIndex(index) }
    famo.onPage = { [weak self] up in _ = self?.page(up: up) }
    let content = FamoPanelContent(
      preedit: preedit,
      cursor: cursor,
      selStart: selStart,
      selEnd: selEnd,
      candidates: rimeModels,
      highlightedIndex: highlighted,
      page: page,
      hasPrevPage: page > 0,
      hasNextPage: !lastPage,
      isVertical: isVertical,
      schemaID: schemaId,
      anchor: inputPos
    )
    let panelTrace = FamoLatencyTrace.begin("candidatePanel.update")
    let becameVisible = famo.update(content, prefs: .current())
    FamoLatencyTrace.end("candidatePanel.update", panelTrace)
    if becameVisible, policy.delayedCandidatePositioning.allowed {
      scheduleDelayedCandidateReposition(client: client, panel: famo, candidateCount: candidates.count)
    }
  }

  /// Selection routing for a clicked / selected panel `index`. Every panel row is now an
  /// authoritative Rime candidate, so this is a direct `selectCandidate(index)` — the inline AI
  /// candidate lane that used to append extra rows and route them through the broker was removed.
  func selectPanelIndex(_ index: Int) {
    _ = selectCandidate(index)
  }

  /// A safe on-screen anchor when neither the fresh nor the last-good caret rect is usable
  /// (B3 cascade tail). A small rect near the top-center of the main screen — keeps the panel
  /// on a real display instead of the origin. Off the hot-path math; only fires on junk anchors.
  static func safeFallbackAnchor() -> NSRect {
    FamoCandidateAnchor.safeFallbackAnchor(screens: NSScreen.screens.map(\.frame))
  }

  private func clientCapabilityDecisions(for client: IMKTextInput) -> FamoClientCapabilities {
    let bundleID = client.bundleIdentifier() ?? (currentApp.isEmpty ? nil : currentApp)
    return NSApp.famoAppDelegate.clientCapabilityPolicy.evaluate(
      FamoClientCapabilityInput(
        host: FamoClientHostIdentity(bundleID: bundleID),
        privacy: .current(),
        workarounds: NSApp.famoAppDelegate.clientWorkarounds
      )
    )
  }

  private func scheduleDelayedCandidateReposition(
    client: IMKTextInput,
    panel: FamoSwiftUICandidatePanel,
    candidateCount: Int
  ) {
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let self, let panel, panel.isVisible,
            FamoCandidateAnchor.shouldQueryCaret(candidateCount: candidateCount) else { return }
      if let current = self.client, (current as AnyObject) !== (client as AnyObject) {
        return
      }
      let policy = self.clientCapabilityDecisions(for: client)
      guard policy.caretAttributes.allowed else { return }

      let repositionTrace = FamoLatencyTrace.begin("candidatePanel.delayedReposition")
      defer { FamoLatencyTrace.end("candidatePanel.delayedReposition", repositionTrace) }

      var delayedHead = NSRect()
      client.attributes(forCharacterIndex: 0, lineHeightRectangle: &delayedHead)
      let screens = NSScreen.screens.map(\.frame)
      guard let anchor = FamoCandidateAnchor.resolve(
        candidates: [delayedHead],
        previous: NSApp.famoAppDelegate.lastCaretAnchor,
        screens: screens
      ) else { return }
      NSApp.famoAppDelegate.lastCaretAnchor = anchor
      panel.reposition(anchor: anchor)
    }
  }
}
