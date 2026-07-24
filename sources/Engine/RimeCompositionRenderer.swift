//
//  RimeCompositionRenderer.swift
//  Famo
//
//  Pure value renderer for the IMK marked-text presentation of a Composition (C3,
//  task 07-05-famo-composition-render-seam). The byte→UTF-16 index math and the
//  inline-candidate-preview assembly were moved here VERBATIM out of
//  `FamoInputController+RimeUpdate.swift` (rimeUpdate) — no logic edits; the only
//  change is that the three former `show(...)` call sites now RETURN a `RimeMarkedText`
//  value instead of driving IMK.
//
//  Depth: a caller hands in a Composition + the two inline style flags and gets back a
//  ready-to-`setMarkedText` description — all of librime's UTF-8 byte-offset hazard stays
//  behind this seam. Pure: Foundation only (String / NSRange), no AppKit, no librime.
//  The interface is the test surface — feed a fabricated `RimeComposition`, assert the
//  `RimeMarkedText` (no NSPanel, no live engine). See CONTEXT.md → Composition.
//

import Foundation

/// What the controller needs to present one Composition as IMK marked text, plus the
/// preedit-space caret the composition Snapshot records. All offsets are UTF-16.
struct RimeMarkedText: Equatable {
  /// The string to `setMarkedText` — the inline candidate preview, a full-shape space,
  /// or the raw preedit, depending on the inline flags (see `markedText`).
  let preedit: String
  /// Selection range, UTF-16, indexing into `preedit` (this value's string, not the input).
  let selRange: NSRange
  /// Caret position, UTF-16, indexing into `preedit` (this value's string).
  let caretPos: Int
  /// Caret position, UTF-16, indexing into the RAW `composition.preedit` — for the
  /// composition Snapshot's `cursor`. Equals `caretPos` EXCEPT in the inline-candidate
  /// branch, where `preedit` above is the candidate preview (a different string). Computed
  /// here so the byte→index math lives in exactly one place.
  let preeditCaretUTF16: Int
  /// Highlight span (the converting syllable) in the RAW `composition.preedit`, UTF-16 offsets —
  /// for the panel's active-syllable tint. Both 0 when there's no selection. Computed here so the
  /// byte→index math stays in one place, alongside `preeditCaretUTF16`.
  let preeditSelStartUTF16: Int
  let preeditSelEndUTF16: Int
}

enum RimeCompositionRenderer {

  /// 合成期 keep-alive 占位（#89, spec 主线仓#88 §3）：零宽空格 U+200B。
  /// fcitx5-macos 先例（macosfrontend.swift `commitAndSetPreeditSync`，见
  /// docs/chromium-omnibox-ime-prior-art.md §2.2）：合成进行中 marked text 一旦为空，
  /// Chromium omnibox 等宿主把「空 marked text」当作合成结束——下一个退格落到已上屏文本，
  /// `TextfieldModel::Backspace → CancelCompositionText` 整段清除（squirrel#906 同款）。
  /// 只在「真在组码（raw preedit 非空）而渲染产物为空」的回合注入；raw preedit 为空的
  /// 回合（闲置 / ESC / 删空收尾）必须继续产出空串——那是客户端 marked text 的清理路径。
  static let compositionKeepAlive = "\u{200B}"

  /// Byte→UTF-16 index math + inline-candidate-preview assembly（verbatim 搬运体见
  /// `rendered`），外加 #89 的合成期 keep-alive 兜底：组码中渲染产物为空 → 以
  /// `compositionKeepAlive` 顶住 marked text 非空契约。Pure — no side effects.
  static func markedText(composition: RimeComposition,
                         inlinePreedit: Bool,
                         inlineCandidate: Bool) -> RimeMarkedText {
    let marked = rendered(composition: composition,
                          inlinePreedit: inlinePreedit, inlineCandidate: inlineCandidate)
    // 空产出面只有 inlineCandidate 分支（commitTextPreview 空且无尾码）能在组码中触达；
    // 其余分支「渲染空 ⇔ raw 空」。统一在唯一出口兜底，防未来分支演化漏网。
    guard marked.preedit.isEmpty, !composition.preedit.isEmpty else { return marked }
    return RimeMarkedText(
      preedit: compositionKeepAlive,
      selRange: NSRange(location: 0, length: 0),
      caretPos: 0,
      preeditCaretUTF16: marked.preeditCaretUTF16,
      preeditSelStartUTF16: marked.preeditSelStartUTF16,
      preeditSelEndUTF16: marked.preeditSelEndUTF16)
  }

  /// Byte→UTF-16 index math + inline-candidate-preview assembly, moved verbatim from
  /// `rimeUpdate`. `inlinePreedit` / `inlineCandidate` are the controller's resolved style
  /// flags (schema style + rime options). Pure — no side effects, no dependencies created.
  private static func rendered(composition: RimeComposition,
                               inlinePreedit: Bool,
                               inlineCandidate: Bool) -> RimeMarkedText {
    let preedit = composition.preedit

    let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: composition.selStart), within: preedit) ?? preedit.startIndex
    let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: composition.selEnd), within: preedit) ?? preedit.startIndex
    let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: composition.cursorPos), within: preedit) ?? preedit.startIndex

    // Snapshot cursor: the caret in the RAW preedit (UTF-16). Independent of the branch
    // below (which may re-anchor the caret into the candidate preview).
    let preeditCaretUTF16 = caretPos.utf16Offset(in: preedit)
    // Highlight span in the RAW preedit (UTF-16), for the panel's active-syllable tint. Uses the
    // original `start`/`end` (computed before the inline-candidate branch shadows `start`).
    let preeditSelStartUTF16 = start.utf16Offset(in: preedit)
    let preeditSelEndUTF16 = end.utf16Offset(in: preedit)

    if inlineCandidate {
      var candidatePreview = composition.commitTextPreview ?? ""
      let endOfCandidatePreview = candidatePreview.endIndex
      if inlinePreedit {
        // 左移光標後的情形：
        // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
        // commit_text_preview: ^已選某些字向左移動$
        // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
        // 繼續翻頁至指定更短字詞的情形：
        // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
        // commit_text_preview: ^已選某些字向左yidong$
        // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
        // 光標移至當前段落最左端的情形：
        // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
        // commit_text_preview: ^已選某些字向左移動光標$
        // candidate_preview:   ^已選某些字|[向左移動光標]$
        // 討論：
        // preedit 與 commit_text_preview 中“已選某些字”部分一致
        // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
        // 光標位置的範圍是 start ..= endOfCandidatePreview
        if caretPos >= end && caretPos < preedit.endIndex {
          // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
          candidatePreview += preedit[caretPos...]
        }
      } else {
        // 翻頁至指定更短字詞的情形：
        // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
        // commit_text_preview: ^已選某些字向左yidongguangbiao$
        // candidate_preview:   ^已選某些字[向左???]|$
        // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
        // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
        // commit_text_preview: ^已選某些字向左yidongguangbiao$
        // candidate_preview:   ^已選某些字|[向左]???$
        // FIXME: add librime APIs to support preview candidate without remaining code.
      }
      // preedit can contain additional prompt text before start:
      // ^(prompt)[selection]$
      let start = min(start, candidatePreview.endIndex)
      // caret can be either before or after the selected range.
      let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
      return RimeMarkedText(
        preedit: candidatePreview,
        selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                          length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
        caretPos: caretPos.utf16Offset(in: candidatePreview),
        preeditCaretUTF16: preeditCaretUTF16,
        preeditSelStartUTF16: preeditSelStartUTF16,
        preeditSelEndUTF16: preeditSelEndUTF16)
    } else {
      if inlinePreedit {
        return RimeMarkedText(
          preedit: preedit,
          selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)),
          caretPos: caretPos.utf16Offset(in: preedit),
          preeditCaretUTF16: preeditCaretUTF16,
          preeditSelStartUTF16: preeditSelStartUTF16,
          preeditSelEndUTF16: preeditSelEndUTF16)
      } else {
        // TRICKY: display a non-empty string to prevent iTerm2 from echoing
        // each character in preedit. note this is a full-shape space U+3000;
        // using half shape characters like "..." will result in an unstable
        // baseline when composing Chinese characters.
        return RimeMarkedText(
          preedit: preedit.isEmpty ? "" : "　",
          selRange: NSRange(location: 0, length: 0),
          caretPos: 0,
          preeditCaretUTF16: preeditCaretUTF16,
          preeditSelStartUTF16: preeditSelStartUTF16,
          preeditSelEndUTF16: preeditSelEndUTF16)
      }
    }
  }
}
