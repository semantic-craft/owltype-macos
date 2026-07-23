//
//  RimeValueTypes.swift
//  Famo
//
//  Plain Swift value types that cross the Rime Engine/Session seam. The Live
//  adapters (see RimeSeam.swift) do the librime C-struct alloc → read → free
//  *internally* and hand back ONLY these value types — no `RimeContext_stdbool` /
//  `RimeStatus_stdbool` / `RimeCommit` C struct ever leaks past the protocol.
//
//  These carry the RAW extracted fields. Presentation logic (UTF-16 index math,
//  inline-preview assembly) stays in `FamoInputController.rimeUpdate`, operating
//  on these value types. The seam is "talk to Rime"; "drive IMK UI" is the
//  controller's job. See CONTEXT.md (repo root) → Composition / Status / Option.
//

/// One candidate as Rime reports it: the display text plus an optional comment
/// (the `备注` / pinyin hint). Maps 1:1 to a `RimeCandidate` C struct entry.
struct RimeCandidate {
  let text: String
  let comment: String?
}

/// A snapshot of the current composition (`RimeContext_stdbool`), with every C
/// pointer already decoded into Swift values. Byte offsets (`selStart`/`selEnd`/
/// `cursorPos`) are librime UTF-8 byte indices into `preedit` — the controller
/// converts them to the UTF-16 indices IMK wants, exactly as before.
struct RimeComposition {
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
  let candidates: [RimeCandidate]
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
  /// `ctx.menu.num_candidates`.
  let numCandidates: Int
}

/// A snapshot of session status (`RimeStatus_stdbool`), decoded into Swift values.
struct RimeStatus {
  /// `status.schema_id`, or "" when absent.
  let schemaId: String
  let isASCIIMode: Bool
  let isASCIIPunct: Bool
  let isFullShape: Bool
}
