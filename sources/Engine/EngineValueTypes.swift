//
//  EngineValueTypes.swift
//  Owltype
//
//  Plain Swift value types that cross the engine/session seam. The Rust adapters
//  (see OwlRustEngine.swift) decode the FFI's payloads *internally* and hand back
//  ONLY these value types — no native handle or payload ever leaks past the protocol.
//
//  These carry the RAW extracted fields. Presentation logic (UTF-16 index math,
//  inline-preview assembly) stays in `OwlInputController.engineUpdate`, operating
//  on these value types. The seam is "talk to the engine"; "drive IMK UI" is the
//  controller's job. See CONTEXT.md (repo root) → Composition / Status / Option.
//

/// One candidate as the engine reports it: the display text plus an optional comment
/// (the `备注` / pinyin hint).
struct EngineCandidate {
  let text: String
  let comment: String?
}

/// A snapshot of the current composition, already decoded into Swift values. Byte offsets (`selStart`/`selEnd`/
/// `cursorPos`) are engine UTF-8 byte indices into `preedit` — the controller
/// converts them to the UTF-16 indices IMK wants, exactly as before.
struct EngineComposition {
  /// The preedit string (`ctx.composition.preedit`), or "" when absent.
  let preedit: String
  /// Selection start, as a UTF-8 byte offset into `preedit`.
  let selStart: Int
  /// Selection end, as a UTF-8 byte offset into `preedit`.
  let selEnd: Int
  /// Caret position, as a UTF-8 byte offset into `preedit`.
  let cursorPos: Int
  /// `ctx.commit_text_preview` — the would-be-committed string for inline candidate.
  let commitTextPreview: String?
  /// The candidates on the current page (`ctx.menu.candidates[0..<num_candidates]`).
  let candidates: [EngineCandidate]
  /// Selection labels, resolved with today's exact precedence: `ctx.menu.select_keys`
  /// (one label per character) if present, else `ctx.select_labels[0..<page_size]`.
  let labels: [String]
  /// `ctx.menu.page_no`.
  let pageNo: Int
  /// `ctx.menu.page_size`.
  let pageSize: Int
  /// `ctx.menu.is_last_page`.
  let isLastPage: Bool
  /// `ctx.menu.highlighted_candidate_index`.
  let highlightedIndex: Int
}

/// A snapshot of session status, decoded into Swift values.
struct EngineStatus {
  /// `status.schema_id`, or "" when absent.
  let schemaId: String
  let isASCIIMode: Bool
  let isASCIIPunct: Bool
  let isFullShape: Bool
}
