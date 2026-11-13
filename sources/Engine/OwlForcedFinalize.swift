//
//  OwlForcedFinalize.swift
//  法墨输入法 (Owltype) — 宿主强制 finalize 落字决策 (task 07-07-pinyin-backspace-delete-all)
//
//  When a host (notably Chromium omnibox — Chrome/Edge) unilaterally ends the composition,
//  macOS calls `commitComposition`. Stock Squirrel commits the RAW input (`engineSession.input()`),
//  which for pinyin dumps the raw letter stream (`zhonghuarenmin…`) into the field — then the
//  host's follow-up backspaces eat it character by character ("退格全退"). This pure decision
//  picks the ALREADY-CONVERTED preview (`commit_text_preview`, = what the user would get on
//  space) instead, so the forced finalize lands usable 中文 rather than raw pinyin.
//
//  Safety invariant (the "空回退"): when no preview is available (nil / empty — e.g. an invalid
//  code or a transient engine state), fall back to the raw `input` so a forced finalize NEVER
//  loses what the user typed. The caller gates on `!input.isEmpty`, so the both-empty branch is
//  unreachable in production; it returns `input` (empty) rather than trap.
//
//  This file is PURE value logic plus the closure-injected finalize SEQUENCE (#37) — no IMK,
//  no engine handle, no client read, no UserDefaults; every side effect stays behind a caller
//  closure. The impure shell (reading `engineSession.input()` / `composition().commitTextPreview`,
//  the `commit(string:)` insertText, `clearComposition`, the snapshot-registry clear) stays at
//  the commit seam in `OwlInputController+Lifecycle.swift`, mirroring how `OwlAutoPair`
//  splits a pure decision from the controller side effects.
//
//  Boundary (ADR-0001 / 0002 / 0003): string/value choice only when reached from the IMK commit
//  path — no disk IO, no YAML, no network, zero Rime config changes.
//

import Foundation

/// The pure "what string should a forced finalize commit" decision.
enum OwlForcedFinalize {

  /// Text to commit when the host force-ends the composition.
  ///
  /// - Parameters:
  ///   - preview: the engine's `commit_text_preview` — the already-converted string the user would
  ///     get on space. `nil` when the engine reports no preview.
  ///   - input: the raw input stream (`engineSession.input()`), used as the never-lose-input fallback.
  /// - Returns: `preview` when it is non-empty (land converted 中文); otherwise `input`
  ///   (fallback — never drop the user's typed characters).
  static func commitText(preview: String?, input: String) -> String {
    OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "forced_finalize_commit_text",
      "args": ["preview": preview as Any? ?? NSNull(), "input": input]
    ])
  }

  /// The forced-finalize SEQUENCE the IMK `commitComposition` override runs (#37 根治).
  ///
  /// The one contract this exists to lock: **`emitCleared` runs on EVERY forced finalize,
  /// whatever the engine state** — including a nil/invalid session or empty input. Before #37
  /// the snapshot-registry clear lived only in `engineUpdate()` (the next-key path), so any
  /// composition ended by a non-key path (`deactivateServer`, a host force-end — Chromium /
  /// Electron do this during ordinary typing — or the TIS input-source fallback) stranded the
  /// snapshot until the user's next complete typing cycle, blocking every snapshot-gated
  /// consumer (#131's wild samples: `isSafeTiming` stuck for the process lifetime).
  ///
  /// - Parameters:
  ///   - input: raw input stream (`engineSession.input()`), or nil when there is no live session.
  ///   - preview: lazily reads `commit_text_preview`; consulted only when `input` is non-empty,
  ///     preserving the pre-#37 engine call pattern on the empty path.
  ///   - commit: lands the decided text in the client (`commit(string:)`).
  ///   - clearComposition: `clear_composition` on the live session.
  ///   - emitCleared: snapshot-registry clear (`OwlSnapshotEmitter.emitCleared`) — already
  ///     idempotent via its `wasComposing` guard, so the no-composition call is a free no-op.
  ///   - trace: decision-only observability (bool/length, never user content).
  static func finalize(
    input: String?,
    preview: () -> String?,
    commit: (String) -> Void,
    clearComposition: () -> Void,
    emitCleared: () -> Void,
    trace: (String) -> Void
  ) {
    if let input, !input.isEmpty {
      let previewText = preview()
      let usedPreview = (previewText?.isEmpty == false)
      let text = commitText(preview: previewText, input: input)
      trace("commitComposition finalize usedPreview=\(usedPreview) len=\(text.count)")
      commit(text)
      clearComposition()
    }
    // #37: the registry mirror follows EVERY forced finalize — the input-empty branch is exactly
    // the stranded class (engine already ended elsewhere, snapshot left behind).
    emitCleared()
    trace("commitComposition emitCleared")
  }
}
