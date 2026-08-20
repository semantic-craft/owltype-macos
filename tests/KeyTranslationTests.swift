//
//  KeyTranslationTests.swift
//  OwltypeTests — pure input pipeline (task 06-22-pure-input-pipeline-refactor)
//
//  Before this task ZERO tests touched key translation: `OwlKeycode.osxKeycodeToRime` /
//  `osxModifiersToRime` / `inferModifierKeycode`, the `keyChars` character resolution, and the
//  classification of a raw key event into rime keycodes lived inline in `handle()`, only
//  exercisable on a real machine. The refactor lifted that logic into the PURE
//  `OwlUserActionClassifier` + `OwlKeycode`, so it is now unit-testable headless (no librime,
//  no IMK, no NSScreen — see `.trellis/spec/frontend/type-safety.md` Equatable-testability rule).
//
//  These tests lock the behaviour byte-for-byte against the old inline code, INCLUDING the three
//  real bugs the inline comments cite:
//    • Parsec #825 — flagsChanged with keyCode 0 (kVK_ANSI_A) must NOT ghost-type 'a'; the real
//      modifier keycode is inferred from the changed flags.
//    • #715 — flagsChanged keyCode availability / modifier-keycode validation.
//    • iTerm2 / non-ASCII — non-letter under shift/caps, or non-ASCII otherwise, falls back to
//      `event.characters`.
//

import AppKit
import Carbon
import XCTest
@testable import Owltype

final class KeyTranslationTests: XCTestCase {

  // MARK: - OwlKeycode.osxModifiersToRime

  func testModifiersNoneIsZero() {
    XCTAssertEqual(OwlKeycode.osxModifiersToRime(modifiers: []), 0)
  }

  func testModifiersShiftMapsToShiftMask() {
    XCTAssertEqual(OwlKeycode.osxModifiersToRime(modifiers: .shift), kShiftMask.rawValue)
  }

  func testModifiersControlOptionCommandCapsCombine() {
    let mods: NSEvent.ModifierFlags = [.control, .option, .command, .capsLock]
    let expected = kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue | kLockMask.rawValue
    XCTAssertEqual(OwlKeycode.osxModifiersToRime(modifiers: mods), expected)
  }

  // MARK: - OwlKeycode.osxKeycodeToRime

  func testKeycodeLowercaseLetterA() {
    // 'a' keyCode (kVK_ANSI_A) with char 'a', no shift/caps → XK_a.
    let rime = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_ANSI_A), keychar: "a", shift: false, caps: false)
    XCTAssertEqual(rime, UInt32(XK_a))
  }

  func testKeycodeUppercaseViaShift() {
    // IBus/Rime use different keycodes for upper/lower. Shift on a lowercase char → uppercase keysym.
    let rime = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_ANSI_A), keychar: "a", shift: true, caps: false)
    XCTAssertEqual(rime, "A".unicodeScalars.first!.value)
  }

  func testKeycodeCapsAndShiftCancelToLowercase() {
    // shift != caps drives the uppercase branch; shift == caps (both true) does NOT → stays 'a'.
    let rime = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_ANSI_A), keychar: "a", shift: true, caps: true)
    XCTAssertEqual(rime, UInt32(XK_a))
  }

  func testKeycodeSpecialSpace() {
    let rime = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Space), keychar: " ", shift: false, caps: false)
    XCTAssertEqual(rime, UInt32(XK_space))
  }

  func testKeycodeReturnViaMapping() {
    let rime = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Return), keychar: nil, shift: false, caps: false)
    XCTAssertEqual(rime, UInt32(XK_Return))
  }

  func testKeycodeBackspaceViaMapping() {
    let rime = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Delete), keychar: nil, shift: false, caps: false)
    XCTAssertEqual(rime, UInt32(XK_BackSpace))
  }

  func testKeycodeUnknownNonASCIIIsVoidSymbol() {
    // A non-ASCII char with an unmapped keyCode → XK_VoidSymbol (the old fall-through).
    let rime = OwlKeycode.osxKeycodeToRime(keycode: 9999, keychar: "中", shift: false, caps: false)
    XCTAssertEqual(rime, UInt32(XK_VoidSymbol))
  }

  // MARK: - OwlKeycode.inferModifierKeycode (#825 Parsec ghost-'a' fix backing)

  func testInferShiftKeycode() {
    XCTAssertEqual(OwlKeycode.inferModifierKeycode(from: .shift), UInt16(kVK_Shift))
  }

  func testInferControlKeycode() {
    XCTAssertEqual(OwlKeycode.inferModifierKeycode(from: .control), UInt16(kVK_Control))
  }

  func testInferOptionKeycode() {
    XCTAssertEqual(OwlKeycode.inferModifierKeycode(from: .option), UInt16(kVK_Option))
  }

  func testInferCommandKeycode() {
    XCTAssertEqual(OwlKeycode.inferModifierKeycode(from: .command), UInt16(kVK_Command))
  }

  func testInferCapsLockKeycode() {
    XCTAssertEqual(OwlKeycode.inferModifierKeycode(from: .capsLock), UInt16(kVK_CapsLock))
  }

  func testInferReturnsNilWhenNoModifierChanged() {
    XCTAssertNil(OwlKeycode.inferModifierKeycode(from: []))
  }

  func testModifierKeycodesSetContainsRealModifiers() {
    XCTAssertTrue(OwlKeycode.modifierKeycodes.contains(UInt16(kVK_Shift)))
    XCTAssertTrue(OwlKeycode.modifierKeycodes.contains(UInt16(kVK_Command)))
    // kVK_ANSI_A (0) — the Parsec default-keyCode value — is NOT a modifier keycode.
    XCTAssertFalse(OwlKeycode.modifierKeycodes.contains(UInt16(kVK_ANSI_A)))
  }

  // MARK: - OwlKeycode.slashSwitchesToEnglish (task 06-30: '/' → English for programming)

  func testSlashSwitchesToEnglishWhenChineseAndBareSlash() {
    XCTAssertTrue(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: 0, asciiMode: false, symbolMenuEnabled: false))
  }

  func testSlashDoesNotSwitchWhenSymbolMenuEnabled() {
    XCTAssertFalse(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: 0, asciiMode: false, symbolMenuEnabled: true))
  }

  func testSlashDoesNotSwitchWhenAlreadyAscii() {
    // Already English → leave '/' alone (it just types normally).
    XCTAssertFalse(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: 0, asciiMode: true, symbolMenuEnabled: false))
  }

  func testSlashDoesNotSwitchWithControl() {
    // Control+slash is bound (toggle simplification) — must NOT be hijacked.
    XCTAssertFalse(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: kControlMask.rawValue, asciiMode: false,
      symbolMenuEnabled: false))
  }

  func testSlashDoesNotSwitchWithCommandOrOption() {
    XCTAssertFalse(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: kSuperMask.rawValue, asciiMode: false,
      symbolMenuEnabled: false))
    XCTAssertFalse(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: kAltMask.rawValue, asciiMode: false,
      symbolMenuEnabled: false))
  }

  func testSlashStillSwitchesWithCapsLock() {
    // CapsLock doesn't change '/'; only Ctrl/Alt/Cmd block the switch, not Lock.
    XCTAssertTrue(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_slash), modifiers: kLockMask.rawValue, asciiMode: false,
      symbolMenuEnabled: false))
  }

  func testNonSlashKeyDoesNotSwitch() {
    XCTAssertFalse(OwlKeycode.slashSwitchesToEnglish(
      keycode: UInt32(XK_a), modifiers: 0, asciiMode: false, symbolMenuEnabled: false))
  }

  // MARK: - resolveKeyChars (iTerm2 / non-ASCII fallback, was inline at handle():152-157)

  func testResolveKeyCharsPlainLetterKeepsIgnoringModifiers() {
    let resolved = OwlUserActionClassifier.resolveKeyChars(
      charactersIgnoringModifiers: "a", characters: "a", modifiers: [])
    XCTAssertEqual(resolved, "a")
  }

  func testResolveKeyCharsShiftNonLetterFallsBackToCharacters() {
    // capitalModifiers (shift) + non-letter charsIgnoringModifiers ("1") → use `characters` ("!").
    let resolved = OwlUserActionClassifier.resolveKeyChars(
      charactersIgnoringModifiers: "1", characters: "!", modifiers: .shift)
    XCTAssertEqual(resolved, "!")
  }

  func testResolveKeyCharsShiftLetterKeepsIgnoringModifiers() {
    // capitalModifiers (shift) + letter → keep charsIgnoringModifiers ("a"); the keysym shift is
    // applied later in osxKeycodeToRime, not by swapping to `characters`.
    let resolved = OwlUserActionClassifier.resolveKeyChars(
      charactersIgnoringModifiers: "a", characters: "A", modifiers: .shift)
    XCTAssertEqual(resolved, "a")
  }

  func testResolveKeyCharsNonASCIINonLetterFallsBackToCharacters() {
    // Subtlety preserved from the ORIGINAL inline code: `capitalModifiers` = modifiers ⊆
    // {shift, capsLock}, and the EMPTY set is a subset of everything → `capitalModifiers` is TRUE
    // for no modifiers. So with no modifiers the active branch is `(capitalModifiers && !isLetter)`.
    // A non-ASCII NON-letter ("•" U+2022) trips it → fall back to `characters`.
    let resolved = OwlUserActionClassifier.resolveKeyChars(
      charactersIgnoringModifiers: "•", characters: "8", modifiers: [])
    XCTAssertEqual(resolved, "8")
  }

  func testResolveKeyCharsNonASCIILetterNoModsKept() {
    // Counterpart: a non-ASCII LETTER ("ñ") with no modifiers is KEPT, because the empty-set
    // `capitalModifiers` selects the `!isLetter` branch (false for a letter). Behaviour-equivalent
    // to the old inline `handle()` — documenting the empty-set-subset quirk explicitly.
    let resolved = OwlUserActionClassifier.resolveKeyChars(
      charactersIgnoringModifiers: "ñ", characters: "n", modifiers: [])
    XCTAssertEqual(resolved, "ñ")
  }

  func testResolveKeyCharsNilStaysNil() {
    let resolved = OwlUserActionClassifier.resolveKeyChars(
      charactersIgnoringModifiers: nil, characters: nil, modifiers: [])
    XCTAssertNil(resolved)
  }

  // MARK: - classify: keyDown

  private func keyDown(keyCode: UInt16, chars: String?, ignoring: String?,
                       modifiers: NSEvent.ModifierFlags = []) -> OwlKeyEvent {
    OwlKeyEvent(type: .keyDown, keyCode: keyCode, characters: chars,
                 charactersIgnoringModifiers: ignoring, modifierFlags: modifiers, lastModifiers: [])
  }

  func testClassifyPlainLetterKeyDown() {
    let action = OwlUserActionClassifier.classify(keyDown(keyCode: UInt16(kVK_ANSI_A), chars: "a", ignoring: "a"))
    XCTAssertEqual(action, .keyDown(rimeKeycode: UInt32(XK_a), rimeModifiers: 0))
  }

  func testClassifyShiftLetterKeyDownProducesUppercaseKeysym() {
    let action = OwlUserActionClassifier.classify(
      keyDown(keyCode: UInt16(kVK_ANSI_A), chars: "A", ignoring: "a", modifiers: .shift))
    XCTAssertEqual(action, .keyDown(rimeKeycode: "A".unicodeScalars.first!.value, rimeModifiers: kShiftMask.rawValue))
  }

  func testClassifyCommandKeyDownIsPassthrough() {
    // Command+X hotkeys are passed to the app (handled stays false).
    let action = OwlUserActionClassifier.classify(
      keyDown(keyCode: UInt16(kVK_ANSI_C), chars: "c", ignoring: "c", modifiers: .command))
    XCTAssertEqual(action, .commandPassthrough)
  }

  func testClassifyKeyDownNoCharsIsIgnored() {
    let action = OwlUserActionClassifier.classify(keyDown(keyCode: 9999, chars: nil, ignoring: nil))
    XCTAssertEqual(action, .ignored)
  }

  func testClassifyKeyDownVoidSymbolStillFedToLibrime() {
    // Behaviour-equivalence guard: the old `handle()` guard was `if rimeKeycode != 0`, and
    // XK_VoidSymbol is 0xFFFFFF (NON-zero), so an unmapped keyCode + non-ASCII char produced a
    // VoidSymbol keycode that WAS fed to librime (with no modifiers). The classifier must do the
    // same — `.ignored` here would be a behaviour change. (Only an actual 0 keycode is dropped.)
    let action = OwlUserActionClassifier.classify(keyDown(keyCode: 9999, chars: "中", ignoring: "中"))
    XCTAssertEqual(action, .keyDown(rimeKeycode: UInt32(XK_VoidSymbol), rimeModifiers: 0))
  }

  func testClassifyKeyDownSpace() {
    let action = OwlUserActionClassifier.classify(
      keyDown(keyCode: UInt16(kVK_Space), chars: " ", ignoring: " "))
    XCTAssertEqual(action, .keyDown(rimeKeycode: UInt32(XK_space), rimeModifiers: 0))
  }

  // MARK: - classify: flagsChanged

  func testClassifyFlagsUnchanged() {
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: .shift, lastModifiers: .shift)
    XCTAssertEqual(OwlUserActionClassifier.classify(event), .flagsUnchanged)
  }

  func testClassifyShiftPress() {
    // shift goes from off → on; real shift keyCode.
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: .shift, lastModifiers: [])
    let action = OwlUserActionClassifier.classify(event)
    let rimeShiftKeycode = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Shift), keychar: nil, shift: false, caps: false)
    XCTAssertEqual(action, .flagsChanged(
      capsLockRevert: nil,
      events: [(keycode: rimeShiftKeycode, modifiers: kShiftMask.rawValue)],
      updateLastModifiers: .shift,
      handled: false))
  }

  func testClassifyShiftRelease() {
    // shift goes from on → off; release events use kReleaseMask and are processed first.
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: [], lastModifiers: .shift)
    let action = OwlUserActionClassifier.classify(event)
    let rimeShiftKeycode = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Shift), keychar: nil, shift: false, caps: false)
    // On release, rimeModifiers reflects the NEW (empty) modifiers (0), OR'd with kReleaseMask.
    XCTAssertEqual(action, .flagsChanged(
      capsLockRevert: nil,
      events: [(keycode: rimeShiftKeycode, modifiers: kReleaseMask.rawValue)],
      updateLastModifiers: [],
      handled: false))
  }

  // Regression (task 06-23-fix-famo-left-shift-cjk-english-switch-broken): the live
  // `OwlKeyEvent(event:lastModifiers:)` init used to read `event.characters` /
  // `charactersIgnoringModifiers` UNCONDITIONALLY. For a modifier press (a `flagsChanged`, not a
  // keyDown) `NSEvent.characters` raises NSInternalInconsistencyException — IMK swallowed it and
  // `handle()` aborted BEFORE feeding the modifier to librime, so left-Shift CJK/English toggle
  // (all flagsChanged handling) was silently dead. The fix sets characters to `nil` for non-keyDown
  // events. These two tests prove the classifier feeds the correct Shift down/up keycode+modifier
  // pairs with `characters: nil` — i.e. the modifier-feed path works WITHOUT ever needing
  // `.characters`. (The actual NSEvent-`.characters`-throws crash needs real-machine verification:
  // headless XCTest cannot construct a `flagsChanged` NSEvent to exercise the live `init(event:)`.)
  func testClassifyShiftPressWithNilCharactersFeedsToggle() {
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: .shift, lastModifiers: [])
    let action = OwlUserActionClassifier.classify(event)
    let rimeShiftKeycode = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Shift), keychar: nil, shift: false, caps: false)
    XCTAssertEqual(action, .flagsChanged(
      capsLockRevert: nil,
      events: [(keycode: rimeShiftKeycode, modifiers: kShiftMask.rawValue)],
      updateLastModifiers: .shift,
      handled: false),
      "Shift-press flagsChanged with nil characters must still feed the Shift keycode to librime")
  }

  func testClassifyShiftReleaseWithNilCharactersFeedsToggle() {
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: [], lastModifiers: .shift)
    let action = OwlUserActionClassifier.classify(event)
    let rimeShiftKeycode = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Shift), keychar: nil, shift: false, caps: false)
    XCTAssertEqual(action, .flagsChanged(
      capsLockRevert: nil,
      events: [(keycode: rimeShiftKeycode, modifiers: kReleaseMask.rawValue)],
      updateLastModifiers: [],
      handled: false),
      "Shift-release flagsChanged with nil characters must still feed the release to librime")
  }

  func testClassifyParsecGhostAFixInfersModifierKeycode() {
    // #825: Parsec sends a flagsChanged for a shift PRESS but with keyCode 0 (kVK_ANSI_A). The
    // classifier MUST NOT translate keyCode 0 → 'a' (which would ghost-type 'a'); it infers the
    // real shift keycode from the changed flag instead.
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_ANSI_A), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: .shift, lastModifiers: [])
    let action = OwlUserActionClassifier.classify(event)
    let inferredShift = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_Shift), keychar: nil, shift: false, caps: false)
    // The fed keycode is the SHIFT keysym, never XK_a.
    XCTAssertEqual(action, .flagsChanged(
      capsLockRevert: nil,
      events: [(keycode: inferredShift, modifiers: kShiftMask.rawValue)],
      updateLastModifiers: .shift,
      handled: false))
    if case let .flagsChanged(_, events, _, _) = action {
      XCTAssertNotEqual(events.first?.keycode, UInt32(XK_a), "Parsec keyCode-0 must not ghost-type 'a'")
    } else {
      XCTFail("expected flagsChanged")
    }
  }

  func testClassifyFlagsChangedUninferableProducesEmptyEvents() {
    // keyCode is not a real modifier AND no modifier flag changed in a way we can infer → the old
    // code stored lastModifiers, ran rimeUpdate, marked handled. Represented as empty events.
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_ANSI_A), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: [.function], lastModifiers: [])
    let action = OwlUserActionClassifier.classify(event)
    // Couldn't-infer bail: this is the ONE flagsChanged sub-path the original returned handled=true on.
    XCTAssertEqual(action, .flagsChanged(capsLockRevert: nil, events: [], updateLastModifiers: [.function], handled: true))
  }

  func testClassifyCapsLockProducesRevertAndPress() {
    // capsLock turning on: a revert event (kLockMask XOR'd out) precedes, then the normal buffer.
    let event = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_CapsLock), characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: .capsLock, lastModifiers: [])
    let action = OwlUserActionClassifier.classify(event)
    guard case let .flagsChanged(capsLockRevert, events, updateLast, _) = action else {
      return XCTFail("expected flagsChanged")
    }
    XCTAssertNotNil(capsLockRevert, "capsLock change must emit a revert event before the buffer")
    // capsLock is not in the [shift, control, option, command] buffer loop → no buffered events.
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(updateLast, .capsLock)
    let rimeCaps = OwlKeycode.osxKeycodeToRime(keycode: UInt16(kVK_CapsLock), keychar: nil, shift: false, caps: false)
    XCTAssertEqual(capsLockRevert?.keycode, rimeCaps)
    // rimeModifiers starts as kLockMask (caps on), XOR'd with kLockMask → 0.
    XCTAssertEqual(capsLockRevert?.modifiers, 0)
  }

  // Regression (reviewer-found): the ONLY flagsChanged outcome the original `handle()` returned
  // `true` on was the couldn't-infer bail. The normal modifier press/release path — and a
  // capsLock-only change — left `handled` at its initial `false`, so the host app still receives
  // the modifier event. `events.isEmpty` cannot distinguish these, hence the explicit `handled`.
  func testClassifyFlagsChangedHandledReturnValue() {
    func handled(_ action: OwlUserAction) -> Bool? {
      if case let .flagsChanged(_, _, _, h) = action { return h }
      return nil
    }
    let shiftPress = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: nil,
                                  charactersIgnoringModifiers: nil, modifierFlags: .shift, lastModifiers: [])
    XCTAssertEqual(handled(OwlUserActionClassifier.classify(shiftPress)), false,
                   "normal modifier press must NOT be swallowed (handled=false)")

    let capsOnly = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_CapsLock), characters: nil,
                                charactersIgnoringModifiers: nil, modifierFlags: .capsLock, lastModifiers: [])
    XCTAssertEqual(handled(OwlUserActionClassifier.classify(capsOnly)), false,
                   "capsLock-only change is the normal path (handled=false) despite empty events")

    let uninferable = OwlKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_ANSI_A), characters: nil,
                                   charactersIgnoringModifiers: nil, modifierFlags: [.function], lastModifiers: [])
    XCTAssertEqual(handled(OwlUserActionClassifier.classify(uninferable)), true,
                   "the couldn't-infer bail is the one path that returned handled=true")
  }

  func testClassifyOtherEventTypeIgnored() {
    let event = OwlKeyEvent(type: .other, keyCode: 0, characters: nil,
                             charactersIgnoringModifiers: nil, modifierFlags: [], lastModifiers: [])
    XCTAssertEqual(OwlUserActionClassifier.classify(event), .ignored)
  }

  // MARK: - OwlClientAction value type

  func testClientActionInsertTextEquatable() {
    XCTAssertEqual(OwlClientAction.insertText("你好"), .insertText("你好"))
    XCTAssertNotEqual(OwlClientAction.insertText("你好"), .insertText("你"))
  }

  func testClientActionSetMarkedTextEquatable() {
    let a = OwlClientAction.setMarkedText(preedit: "ni", selRange: NSRange(location: 0, length: 2), caretPos: 2)
    let b = OwlClientAction.setMarkedText(preedit: "ni", selRange: NSRange(location: 0, length: 2), caretPos: 2)
    let c = OwlClientAction.setMarkedText(preedit: "ni", selRange: NSRange(location: 0, length: 2), caretPos: 1)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
  }
}
