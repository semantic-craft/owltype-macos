import Foundation

enum OwlCapsLockTransition: Equatable {
  case passThrough
  case setASCIIMode(Bool, consumed: Bool)
}

/// Mirrors librime `ascii_composer.cc:143-186`. The caller passes the pre-flip `kLockMask`
/// state, matching the classifier's Caps Lock revert event on macOS.
struct OwlCapsLockKeyState {
  private(set) var toggleWithCaps = false

  mutating func resetForOtherASCIIModeSwitch() {
    toggleWithCaps = false
  }

  mutating func processPress(
    preFlipCapsLocked: Bool,
    asciiMode: Bool,
    goodOldCapsLock: Bool
  ) -> OwlCapsLockTransition {
    if goodOldCapsLock && !toggleWithCaps && asciiMode {
      return .passThrough
    }
    toggleWithCaps = !preFlipCapsLocked
    return .setASCIIMode(toggleWithCaps, consumed: !goodOldCapsLock)
  }
}

extension OwlRustSession {
  func asciiKeyCharacter(for keycode: UInt32) -> Character? {
    let keypad = keycode >= UInt32(XK_KP_0) && keycode <= UInt32(XK_KP_9)
    let value = keypad ? UInt32(XK_0) + (keycode - UInt32(XK_KP_0)) : keycode
    guard value >= 0x21, value <= 0x7E, let scalar = UnicodeScalar(value) else { return nil }
    return Character(String(scalar))
  }

  func invertedASCIILetter(for keycode: UInt32) -> String? {
    let uppercase: ClosedRange<UInt32> = 0x41...0x5A
    let lowercase: ClosedRange<UInt32> = 0x61...0x7A
    guard uppercase.contains(keycode) || lowercase.contains(keycode),
          let scalar = UnicodeScalar(keycode) else { return nil }
    let character = Character(String(scalar))
    return character.isUppercase
      ? String(character).lowercased()
      : String(character).uppercased()
  }

  func asciiPunctuationString(for keycode: UInt32) -> String? {
    guard keycode >= 0x21 && keycode <= 0x7E,
          let scalar = UnicodeScalar(keycode) else { return nil }
    let byte = UInt8(keycode)
    let isAlphaNum = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
      || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
      || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    guard !isAlphaNum else { return nil }
    return String(scalar)
  }

  func candidateSelectionIndex(for keycode: UInt32) -> Int? {
    if OwlKeyboardPreferences.select23Semicolon {
      if keycode == UInt32(XK_semicolon) { return 1 }
      if keycode == UInt32(XK_apostrophe) { return 2 }
    }
    if keycode >= UInt32(XK_1) && keycode <= UInt32(XK_9) {
      return Int(keycode - UInt32(XK_1))
    }
    if keycode >= UInt32(XK_KP_1) && keycode <= UInt32(XK_KP_9) {
      return Int(keycode - UInt32(XK_KP_1))
    }
    return nil
  }

  func isPageUpKey(_ keycode: UInt32) -> Bool {
    if keycode == UInt32(XK_Page_Up) { return true }
    if OwlKeyboardPreferences.pageMinusEquals && keycode == UInt32(XK_minus) { return true }
    if OwlKeyboardPreferences.pageBrackets && keycode == UInt32(XK_bracketleft) { return true }
    if OwlKeyboardPreferences.pageCommaPeriod && keycode == UInt32(XK_comma) { return true }
    return false
  }

  func isPageDownKey(_ keycode: UInt32) -> Bool {
    if keycode == UInt32(XK_Page_Down) { return true }
    if OwlKeyboardPreferences.pageMinusEquals && keycode == UInt32(XK_equal) { return true }
    if OwlKeyboardPreferences.pageBrackets && keycode == UInt32(XK_bracketright) { return true }
    if OwlKeyboardPreferences.pageCommaPeriod && keycode == UInt32(XK_period) { return true }
    return false
  }
}
