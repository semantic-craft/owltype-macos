//
//  EngineOption.swift
//  Owltype
//
//  The closed set of engine options Owltype *drives* (set / get / toggle) on a
//  session. Option keys used to be bare string literals scattered across
//  OwlInputController, where a typo would silently no-op. This enum is the single
//  source of truth so the compiler catches the typo instead.
//
//  Scope note: option *names that the engine reports back* (e.g. in the notification
//  handler's `get_state_label_abbreviated(session, name, …)`) are an open namespace
//  owned by Rime/the schema, not by Owltype — those intentionally stay `String` and are
//  NOT enum cases. See CONTEXT.md (repo root) → "Option".
//

/// A session option Owltype drives. `rawValue` is the engine option key.
enum EngineOption: String, CaseIterable {
  // Engine-standard options.
  case asciiMode = "ascii_mode"
  case asciiPunct = "ascii_punct"
  case fullShape = "full_shape"
  case traditional
  case emojiSuggestion = "emoji"

  // Presentation and input-controller flags.
  case linear
  case vertical
}
