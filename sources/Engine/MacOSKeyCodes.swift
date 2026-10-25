//
//  MacOSKeyCodes.swift
//  Owltype
//
//  Created by Leo Liu on 5/9/24.
//

import Carbon
import AppKit

enum OwlKeyMask: UInt32 {
  case shift = 0x0000_0001
  case lock = 0x0000_0002
  case control = 0x0000_0004
  case alt = 0x0000_0008
  case superKey = 0x0400_0000
  case release = 0x4000_0000
}

// Frozen X11 keysym values used by the Rust engine. They used to come from
// librime's C headers; keeping the numeric ABI here removes every header and
// link-time dependency on librime from Swift.
// swiftlint:disable identifier_name
let kShiftMask = OwlKeyMask.shift
let kLockMask = OwlKeyMask.lock
let kControlMask = OwlKeyMask.control
let kAltMask = OwlKeyMask.alt
let kSuperMask = OwlKeyMask.superKey
let kReleaseMask = OwlKeyMask.release

let XK_VoidSymbol: Int32 = 0x00ff_ffff
let XK_BackSpace: Int32 = 0x00ff_08
let XK_Tab: Int32 = 0x00ff_09
let XK_Clear: Int32 = 0x00ff_0b
let XK_Return: Int32 = 0x00ff_0d
let XK_Escape: Int32 = 0x00ff_1b
let XK_space: Int32 = 0x20
let XK_numbersign: Int32 = 0x23
let XK_apostrophe: Int32 = 0x27
let XK_comma: Int32 = 0x2c
let XK_minus: Int32 = 0x2d
let XK_period: Int32 = 0x2e
let XK_slash: Int32 = 0x2f
let XK_0: Int32 = 0x30
let XK_1: Int32 = 0x31
let XK_2: Int32 = 0x32
let XK_3: Int32 = 0x33
let XK_4: Int32 = 0x34
let XK_5: Int32 = 0x35
let XK_6: Int32 = 0x36
let XK_7: Int32 = 0x37
let XK_8: Int32 = 0x38
let XK_9: Int32 = 0x39
let XK_semicolon: Int32 = 0x3b
let XK_equal: Int32 = 0x3d
let XK_less: Int32 = 0x3c
let XK_C: Int32 = 0x43
let XK_bracketleft: Int32 = 0x5b
let XK_backslash: Int32 = 0x5c
let XK_bracketright: Int32 = 0x5d
let XK_underscore: Int32 = 0x5f
let XK_grave: Int32 = 0x60
let XK_a: Int32 = 0x61
let XK_b: Int32 = 0x62
let XK_c: Int32 = 0x63
let XK_d: Int32 = 0x64
let XK_e: Int32 = 0x65
let XK_f: Int32 = 0x66
let XK_g: Int32 = 0x67
let XK_h: Int32 = 0x68
let XK_i: Int32 = 0x69
let XK_j: Int32 = 0x6a
let XK_k: Int32 = 0x6b
let XK_l: Int32 = 0x6c
let XK_m: Int32 = 0x6d
let XK_n: Int32 = 0x6e
let XK_o: Int32 = 0x6f
let XK_p: Int32 = 0x70
let XK_q: Int32 = 0x71
let XK_r: Int32 = 0x72
let XK_s: Int32 = 0x73
let XK_t: Int32 = 0x74
let XK_u: Int32 = 0x75
let XK_v: Int32 = 0x76
let XK_w: Int32 = 0x77
let XK_x: Int32 = 0x78
let XK_y: Int32 = 0x79
let XK_z: Int32 = 0x7a
let XK_asciitilde: Int32 = 0x7e
let XK_yen: Int32 = 0x00a5
let XK_section: Int32 = 0x00a7
let XK_KP_Multiply: Int32 = 0x00ff_aa
let XK_KP_Add: Int32 = 0x00ff_ab
let XK_KP_Subtract: Int32 = 0x00ff_ad
let XK_KP_Decimal: Int32 = 0x00ff_ae
let XK_KP_Divide: Int32 = 0x00ff_af
let XK_KP_0: Int32 = 0x00ff_b0
let XK_KP_1: Int32 = 0x00ff_b1
let XK_KP_2: Int32 = 0x00ff_b2
let XK_KP_3: Int32 = 0x00ff_b3
let XK_KP_4: Int32 = 0x00ff_b4
let XK_KP_5: Int32 = 0x00ff_b5
let XK_KP_6: Int32 = 0x00ff_b6
let XK_KP_7: Int32 = 0x00ff_b7
let XK_KP_8: Int32 = 0x00ff_b8
let XK_KP_9: Int32 = 0x00ff_b9
let XK_KP_Equal: Int32 = 0x00ff_bd
let XK_F1: Int32 = 0x00ff_be
let XK_F2: Int32 = 0x00ff_bf
let XK_F3: Int32 = 0x00ff_c0
let XK_F4: Int32 = 0x00ff_c1
let XK_F5: Int32 = 0x00ff_c2
let XK_F6: Int32 = 0x00ff_c3
let XK_F7: Int32 = 0x00ff_c4
let XK_F8: Int32 = 0x00ff_c5
let XK_F9: Int32 = 0x00ff_c6
let XK_F10: Int32 = 0x00ff_c7
let XK_F11: Int32 = 0x00ff_c8
let XK_F12: Int32 = 0x00ff_c9
let XK_F13: Int32 = 0x00ff_ca
let XK_F14: Int32 = 0x00ff_cb
let XK_F15: Int32 = 0x00ff_cc
let XK_F16: Int32 = 0x00ff_cd
let XK_F17: Int32 = 0x00ff_ce
let XK_F18: Int32 = 0x00ff_cf
let XK_F19: Int32 = 0x00ff_d0
let XK_F20: Int32 = 0x00ff_d1
let XK_Shift_L: Int32 = 0x00ff_e1
let XK_Shift_R: Int32 = 0x00ff_e2
let XK_Control_L: Int32 = 0x00ff_e3
let XK_Control_R: Int32 = 0x00ff_e4
let XK_Caps_Lock: Int32 = 0x00ff_e5
let XK_Alt_L: Int32 = 0x00ff_e9
let XK_Alt_R: Int32 = 0x00ff_ea
let XK_Super_L: Int32 = 0x00ff_eb
let XK_Super_R: Int32 = 0x00ff_ec
let XK_Hyper_L: Int32 = 0x00ff_ed
let XK_Meta_L: Int32 = XK_Super_L
let XK_Meta_R: Int32 = XK_Super_R
let XK_KP_Enter: Int32 = 0x00ff_8d
let XK_Home: Int32 = 0x00ff_50
let XK_Left: Int32 = 0x00ff_51
let XK_Up: Int32 = 0x00ff_52
let XK_Right: Int32 = 0x00ff_53
let XK_Down: Int32 = 0x00ff_54
let XK_Page_Up: Int32 = 0x00ff_55
let XK_Page_Down: Int32 = 0x00ff_56
let XK_End: Int32 = 0x00ff_57
let XK_Help: Int32 = 0x00ff_6a
let XK_Delete: Int32 = 0x00ff_ff
let XK_Kana_Shift: Int32 = 0x00ff_2e
let XK_Eisu_Shift: Int32 = 0x00ff_2f
// swiftlint:enable identifier_name

struct OwlKeycode {

  static func osxModifiersToRime(modifiers: NSEvent.ModifierFlags) -> UInt32 {
    var ret: UInt32 = 0
    if modifiers.contains(.capsLock) {
      ret |= kLockMask.rawValue
    }
    if modifiers.contains(.shift) {
      ret |= kShiftMask.rawValue
    }
    if modifiers.contains(.control) {
      ret |= kControlMask.rawValue
    }
    if modifiers.contains(.option) {
      ret |= kAltMask.rawValue
    }
    if modifiers.contains(.command) {
      ret |= kSuperMask.rawValue
    }
    return ret
  }

  /// `/` switches the IME to English (ASCII) mode globally for programming convenience unless the
  /// user explicitly enabled the slash symbol menu. PURE decision; the controller performs the
  /// commit / `set_option` side effects. True only for a BARE slash (no Ctrl/Alt/Cmd) pressed while
  /// currently in Chinese mode — so Control+slash and an already-English `/` are left alone.
  /// CapsLock does not change `/`, so it does not block the switch. Schema-agnostic by
  /// construction: the decision sits above the active schema (works for pinyin / wubi / any).
  static func slashSwitchesToEnglish(
    keycode: UInt32,
    modifiers: UInt32,
    asciiMode: Bool,
    symbolMenuEnabled: Bool
  ) -> Bool {
    guard !symbolMenuEnabled, !asciiMode, keycode == UInt32(XK_slash) else { return false }
    let blocked = kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue
    return (modifiers & blocked) == 0
  }

  static func osxKeycodeToRime(keycode: UInt16, keychar: Character?, shift: Bool, caps: Bool) -> UInt32 {
    if let code = keycodeMappings[Int(keycode)] {
      return UInt32(code)
    }

    if let keychar = keychar, keychar.isASCII, let codeValue = keychar.unicodeScalars.first?.value {
      // NOTE: IBus/Rime use different keycodes for uppercase/lowercase letters.
      if keychar.isLowercase && (shift != caps) {
        // lowercase -> Uppercase
        return keychar.uppercased().unicodeScalars.first!.value
      }

      switch codeValue {
      case 0x20...0x7e:
        return codeValue
      case 0x1b:
        return UInt32(XK_bracketleft)
      case 0x1c:
        return UInt32(XK_backslash)
      case 0x1d:
        return UInt32(XK_bracketright)
      case 0x1f:
        return UInt32(XK_minus)
      default:
        break
      }
    }

    if let code = additionalCodeMappings[Int(keycode)] {
      return UInt32(code)
    }

    return UInt32(XK_VoidSymbol)
  }

  static let modifierKeycodes: Set<UInt16> = [
    UInt16(kVK_Shift), UInt16(kVK_RightShift),
    UInt16(kVK_CapsLock),
    UInt16(kVK_Control), UInt16(kVK_RightControl),
    UInt16(kVK_Option), UInt16(kVK_RightOption),
    UInt16(kVK_Command), UInt16(kVK_RightCommand),
    UInt16(kVK_Function)
  ]

  static func inferModifierKeycode(from changes: NSEvent.ModifierFlags) -> UInt16? {
    if changes.contains(.capsLock) {
      return UInt16(kVK_CapsLock)
    } else if changes.contains(.shift) {
      return UInt16(kVK_Shift)
    } else if changes.contains(.control) {
      return UInt16(kVK_Control)
    } else if changes.contains(.option) {
      return UInt16(kVK_Option)
    } else if changes.contains(.command) {
      return UInt16(kVK_Command)
    }
    return nil
  }

  private static let keycodeMappings: [Int: Int32] = [
    // modifiers
    kVK_CapsLock: XK_Caps_Lock,
    kVK_Command: XK_Super_L,  // XK_Meta_L?
    kVK_RightCommand: XK_Super_R,  // XK_Meta_R?
    kVK_Control: XK_Control_L,
    kVK_RightControl: XK_Control_R,
    kVK_Function: XK_Hyper_L,
    kVK_Option: XK_Alt_L,
    kVK_RightOption: XK_Alt_R,
    kVK_Shift: XK_Shift_L,
    kVK_RightShift: XK_Shift_R,

    // special
    kVK_Delete: XK_BackSpace,
    kVK_Escape: XK_Escape,
    kVK_ForwardDelete: XK_Delete,
    kVK_Help: XK_Help,
    kVK_Return: XK_Return,
    kVK_Space: XK_space,
    kVK_Tab: XK_Tab,

    // function
    kVK_F1: XK_F1,
    kVK_F2: XK_F2,
    kVK_F3: XK_F3,
    kVK_F4: XK_F4,
    kVK_F5: XK_F5,
    kVK_F6: XK_F6,
    kVK_F7: XK_F7,
    kVK_F8: XK_F8,
    kVK_F9: XK_F9,
    kVK_F10: XK_F10,
    kVK_F11: XK_F11,
    kVK_F12: XK_F12,
    kVK_F13: XK_F13,
    kVK_F14: XK_F14,
    kVK_F15: XK_F15,
    kVK_F16: XK_F16,
    kVK_F17: XK_F17,
    kVK_F18: XK_F18,
    kVK_F19: XK_F19,
    kVK_F20: XK_F20,

    // cursor
    kVK_UpArrow: XK_Up,
    kVK_DownArrow: XK_Down,
    kVK_LeftArrow: XK_Left,
    kVK_RightArrow: XK_Right,
    kVK_PageUp: XK_Page_Up,
    kVK_PageDown: XK_Page_Down,
    kVK_Home: XK_Home,
    kVK_End: XK_End,

    // keypad
    kVK_ANSI_Keypad0: XK_KP_0,
    kVK_ANSI_Keypad1: XK_KP_1,
    kVK_ANSI_Keypad2: XK_KP_2,
    kVK_ANSI_Keypad3: XK_KP_3,
    kVK_ANSI_Keypad4: XK_KP_4,
    kVK_ANSI_Keypad5: XK_KP_5,
    kVK_ANSI_Keypad6: XK_KP_6,
    kVK_ANSI_Keypad7: XK_KP_7,
    kVK_ANSI_Keypad8: XK_KP_8,
    kVK_ANSI_Keypad9: XK_KP_9,
    kVK_ANSI_KeypadClear: XK_Clear,
    kVK_ANSI_KeypadDecimal: XK_KP_Decimal,
    kVK_ANSI_KeypadEquals: XK_KP_Equal,
    kVK_ANSI_KeypadMinus: XK_KP_Subtract,
    kVK_ANSI_KeypadMultiply: XK_KP_Multiply,
    kVK_ANSI_KeypadPlus: XK_KP_Add,
    kVK_ANSI_KeypadDivide: XK_KP_Divide,
    kVK_ANSI_KeypadEnter: XK_KP_Enter,

    // other
    kVK_ISO_Section: XK_section,
    kVK_JIS_Yen: XK_yen,
    kVK_JIS_Underscore: XK_underscore,
    kVK_JIS_KeypadComma: XK_comma,
    kVK_JIS_Eisu: XK_Eisu_Shift,
    kVK_JIS_Kana: XK_Kana_Shift
  ]

  private static let additionalCodeMappings: [Int: Int32] = [
    // numbers
    kVK_ANSI_0: XK_0,
    kVK_ANSI_1: XK_1,
    kVK_ANSI_2: XK_2,
    kVK_ANSI_3: XK_3,
    kVK_ANSI_4: XK_4,
    kVK_ANSI_5: XK_5,
    kVK_ANSI_6: XK_6,
    kVK_ANSI_7: XK_7,
    kVK_ANSI_8: XK_8,
    kVK_ANSI_9: XK_9,

    // pubct
    kVK_ANSI_RightBracket: XK_bracketright,
    kVK_ANSI_LeftBracket: XK_bracketleft,
    kVK_ANSI_Comma: XK_comma,
    kVK_ANSI_Grave: XK_grave,
    kVK_ANSI_Period: XK_period,
    // kVK_VolumeUp:
    // kVK_VolumeDown:
    // kVK_Mute:
    kVK_ANSI_Semicolon: XK_semicolon,
    kVK_ANSI_Quote: XK_apostrophe,
    kVK_ANSI_Backslash: XK_backslash,
    kVK_ANSI_Minus: XK_minus,
    kVK_ANSI_Slash: XK_slash,
    kVK_ANSI_Equal: XK_equal,

    // letters
    kVK_ANSI_A: XK_a,
    kVK_ANSI_B: XK_b,
    kVK_ANSI_C: XK_c,
    kVK_ANSI_D: XK_d,
    kVK_ANSI_E: XK_e,
    kVK_ANSI_F: XK_f,
    kVK_ANSI_G: XK_g,
    kVK_ANSI_H: XK_h,
    kVK_ANSI_I: XK_i,
    kVK_ANSI_J: XK_j,
    kVK_ANSI_K: XK_k,
    kVK_ANSI_L: XK_l,
    kVK_ANSI_M: XK_m,
    kVK_ANSI_N: XK_n,
    kVK_ANSI_O: XK_o,
    kVK_ANSI_P: XK_p,
    kVK_ANSI_Q: XK_q,
    kVK_ANSI_R: XK_r,
    kVK_ANSI_S: XK_s,
    kVK_ANSI_T: XK_t,
    kVK_ANSI_U: XK_u,
    kVK_ANSI_V: XK_v,
    kVK_ANSI_W: XK_w,
    kVK_ANSI_X: XK_x,
    kVK_ANSI_Y: XK_y,
    kVK_ANSI_Z: XK_z
  ]
}
