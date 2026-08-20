//
//  OwlUserAction.swift
//  Owltype
//
//  The PURE key-event classifier (task 06-22-pure-input-pipeline-refactor).
//
//  Pipeline:  NSEvent → OwlUserAction (PURE classify) → feed librime (processKey, stateful)
//             → OwlClientAction[] → apply(client) (single side-effect point).
//
//  This file owns ONLY the "what semantic action is this key event?" decision, lifted verbatim
//  out of `OwlInputController.handle()` (the `keyChars`/`capitalModifiers` character resolution
//  and the flagsChanged press/release ordering buffer). It is a pure value enum + a pure
//  classifier: no AppKit-instance state is held, no librime, no IMK. Reading an `NSEvent`'s
//  fields as classifier INPUT is fine (mirrors azooKey's `KeyEventCore`); the classifier itself
//  works on plain value fields (`OwlKeyEvent`) so it is fully unit-testable headless.
//
//  IMPORTANT (the task's hard constraint): librime still owns ALL conversion state
//  (`RimeContext` via `RimeSeam`). This is NOT a `OwlInputState` reducer — it only classifies
//  a single raw key event into the rime keycode/modifier pair(s) the controller must feed
//  librime, plus the press/release ORDERING for flagsChanged. State stays in librime.
//

import AppKit

/// A de-platformed snapshot of the fields `handle()` reads off an `NSEvent`, so the classifier
/// is pure (mirrors azooKey's `KeyEventCore`). `lastModifiers` is the controller's previously
/// seen modifier state — flagsChanged classification is relative to it.
struct OwlKeyEvent: Equatable {
  let type: EventType
  let keyCode: UInt16
  /// `event.characters` (modifiers applied).
  let characters: String?
  /// `event.charactersIgnoringModifiers`.
  let charactersIgnoringModifiers: String?
  let modifierFlags: NSEvent.ModifierFlags
  /// The controller's `lastModifiers` at the moment this event arrived.
  let lastModifiers: NSEvent.ModifierFlags

  /// Only the two event types `handle()` acts on; everything else is `.other`.
  enum EventType: Equatable {
    case keyDown
    case flagsChanged
    case other
  }

  /// Build from a live `NSEvent` (the only impure read — the fields themselves are values).
  init(event: NSEvent, lastModifiers: NSEvent.ModifierFlags) {
    let type: EventType
    switch event.type {
    case .keyDown: type = .keyDown
    case .flagsChanged: type = .flagsChanged
    default: type = .other
    }
    self.type = type
    self.keyCode = event.keyCode
    // NSEvent.characters / charactersIgnoringModifiers raise NSInternalInconsistencyException for
    // non-key events (a modifier press is a flagsChanged, not keyDown). Reading them eagerly here
    // threw for EVERY modifier event → IMK swallowed the exception → handle() aborted before the
    // modifier reached librime → Shift CJK/English toggle (all flagsChanged handling) was silently
    // dead (regression from the pure-pipeline refactor 27b337e). Only keyDown uses these (classify's
    // .keyDown case); leave them nil for flagsChanged/other.
    if type == .keyDown {
      self.characters = event.characters
      self.charactersIgnoringModifiers = event.charactersIgnoringModifiers
    } else {
      self.characters = nil
      self.charactersIgnoringModifiers = nil
    }
    self.modifierFlags = event.modifierFlags
    self.lastModifiers = lastModifiers
  }

  /// Direct value init (tests / non-AppKit callers).
  init(type: EventType, keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
       modifierFlags: NSEvent.ModifierFlags, lastModifiers: NSEvent.ModifierFlags) {
    self.type = type
    self.keyCode = keyCode
    self.characters = characters
    self.charactersIgnoringModifiers = charactersIgnoringModifiers
    self.modifierFlags = modifierFlags
    self.lastModifiers = lastModifiers
  }
}

/// The semantic action a raw key event maps to. The controller feeds the resulting rime
/// keycode/modifier pair(s) to librime (which owns conversion state) and then runs `rimeUpdate`.
enum OwlUserAction: Equatable {
  /// A real key press to feed librime. `rimeKeycode == 0` is NOT produced (the classifier drops
  /// it, matching the old `if rimeKeycode != 0` guard); a non-zero keycode here is always fed.
  case keyDown(rimeKeycode: UInt32, rimeModifiers: UInt32)

  /// One or more modifier transitions to feed librime IN ORDER (release-before-down ordering
  /// already applied). `updateLastModifiers` always becomes the controller's new `lastModifiers`.
  /// `events` may be empty (e.g. capsLock-only revert handled via `capsLockRevert`) — the
  /// controller still runs `rimeUpdate` and stores `updateLastModifiers`.
  /// `handled` is the value `handle()` must return: the original code returned `true` ONLY on the
  /// couldn't-infer-keycode early-bail; the normal modifier press/release path left `handled` at
  /// its initial `false` (so the host app still sees the modifier event). `events.isEmpty` cannot
  /// distinguish these — a capsLock-only change is a normal path (false) yet has empty `events`.
  case flagsChanged(capsLockRevert: (keycode: UInt32, modifiers: UInt32)?,
                    events: [(keycode: UInt32, modifiers: UInt32)],
                    updateLastModifiers: NSEvent.ModifierFlags,
                    handled: Bool)

  /// `flagsChanged` where nothing actually changed (`lastModifiers == modifiers`) — old code
  /// returned `handled = true` and did nothing else.
  case flagsUnchanged

  /// A Command-modified `keyDown` (Command+X hotkeys) — old code `break`s, `handled` stays false.
  case commandPassthrough

  /// Nothing to do; `handled` stays false (non-key event, or a keyDown that produced no usable
  /// rime keycode — same as the old fall-through where `keyChars?.first` was nil or rimeKeycode 0).
  case ignored

  // Equatable can't be synthesized for the tuple-carrying `flagsChanged` case; provide it.
  static func == (lhs: OwlUserAction, rhs: OwlUserAction) -> Bool {
    switch (lhs, rhs) {
    case let (.keyDown(lk, lm), .keyDown(rk, rm)):
      return lk == rk && lm == rm
    case let (.flagsChanged(lcaps, le, lmod, lh), .flagsChanged(rcaps, re, rmod, rh)):
      let capsEqual: Bool
      switch (lcaps, rcaps) {
      case let (l?, r?): capsEqual = l == r
      case (nil, nil): capsEqual = true
      default: capsEqual = false
      }
      return capsEqual && le.elementsEqual(re, by: ==) && lmod == rmod && lh == rh
    case (.flagsUnchanged, .flagsUnchanged),
         (.commandPassthrough, .commandPassthrough),
         (.ignored, .ignored):
      return true
    default:
      return false
    }
  }
}

/// The pure classifier. Lifted verbatim from `OwlInputController.handle()`; reuses the existing
/// `OwlKeycode` helpers in `MacOSKeyCodes.swift` (never reimplements key translation).
enum OwlUserActionClassifier {

  /// Resolve the character to translate for a `keyDown` — the `keyChars`/`capitalModifiers` logic
  /// that was inline at `OwlInputController.swift:152-157`. Pure; cited bugs preserved:
  ///   - non-letter under shift/caps, or non-ASCII otherwise → fall back to `characters`.
  static func resolveKeyChars(charactersIgnoringModifiers: String?,
                              characters: String?,
                              modifiers: NSEvent.ModifierFlags) -> String? {
    var keyChars = charactersIgnoringModifiers
    let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
    if let code = keyChars?.first,
       (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
      keyChars = characters
    }
    return keyChars
  }

  /// Classify a de-platformed key event. PURE: no librime, no IMK, no `NSScreen`.
  static func classify(_ event: OwlKeyEvent) -> OwlUserAction {
    let modifiers = event.modifierFlags
    let changes = event.lastModifiers.symmetricDifference(modifiers)

    switch event.type {
    case .flagsChanged:
      if event.lastModifiers == modifiers {
        return .flagsUnchanged
      }
      var rimeModifiers: UInt32 = OwlKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15 (#715).
      // Some remote desktop software (e.g. Parsec) sends flagsChanged events with keyCode
      // defaulting to 0 (kVK_ANSI_A) instead of the actual modifier keycode, causing a ghost 'a'
      // keypress. Validate and infer the correct keycode from the changed modifier flags. (#825)
      var keyCode = event.keyCode
      if !OwlKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = OwlKeycode.inferModifierKeycode(from: changes) else {
          // Couldn't infer a modifier keycode → old code stored lastModifiers, ran rimeUpdate,
          // and marked handled = true. Represent that as a flagsChanged with no events to feed.
          return .flagsChanged(capsLockRevert: nil, events: [], updateLastModifiers: modifiers, handled: true)
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = OwlKeycode.osxKeycodeToRime(keycode: keyCode, keychar: nil, shift: false, caps: false)

      var capsLockRevert: (keycode: UInt32, modifiers: UInt32)?
      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes, while the
        // NSFlagsChanged event has the flag changed already — so revert kLockMask.
        // The original code mutated `rimeModifiers` in place via `^=`; subsequent press/release
        // events use that XOR'd value. Preserve that exactly.
        rimeModifiers ^= kLockMask.rawValue
        capsLockRevert = (keycode: rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because sometimes the release event is
      // delayed to the next modifier keydown.
      var buffer = [(keycode: UInt32, modifiers: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifiers: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifiers: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      // Normal modifier press/release path: the original code left `handled` at its initial
      // `false` here (only the couldn't-infer bail above set it true), so the host app still
      // sees the modifier event. capsLock-only changes also land here (handled: false).
      return .flagsChanged(capsLockRevert: capsLockRevert, events: buffer, updateLastModifiers: modifiers, handled: false)

    case .keyDown:
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        return .commandPassthrough
      }
      let keyChars = resolveKeyChars(charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                     characters: event.characters,
                                     modifiers: modifiers)
      // translate osx keyevents to rime keyevents
      guard let char = keyChars?.first else { return .ignored }
      let rimeKeycode = OwlKeycode.osxKeycodeToRime(keycode: event.keyCode, keychar: char,
                                                     shift: modifiers.contains(.shift),
                                                     caps: modifiers.contains(.capsLock))
      guard rimeKeycode != 0 else { return .ignored }
      let rimeModifiers = OwlKeycode.osxModifiersToRime(modifiers: modifiers)
      return .keyDown(rimeKeycode: rimeKeycode, rimeModifiers: rimeModifiers)

    case .other:
      return .ignored
    }
  }
}
