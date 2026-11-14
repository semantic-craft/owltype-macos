//
//  MacOSKeyCodes.swift
//  Owltype
//
//  Created by Leo Liu on 5/9/24.
//

enum OwlKeyMask: UInt32 {
  case shift = 0x0000_0001
  case lock = 0x0000_0002
  case control = 0x0000_0004
  case alt = 0x0000_0008
  case superKey = 0x0400_0000
  case release = 0x4000_0000
}

// Frozen X11 keysym values used by the Rust engine. They used to come from
// the former Rime C headers; keeping the numeric ABI here keeps Swift free of
// any engine header or link-time dependency.
// swiftlint:disable identifier_name
let kShiftMask = OwlKeyMask.shift
let kLockMask = OwlKeyMask.lock
let kControlMask = OwlKeyMask.control
let kAltMask = OwlKeyMask.alt
let kSuperMask = OwlKeyMask.superKey
let kReleaseMask = OwlKeyMask.release

let XK_BackSpace: Int32 = 0x00ff_08
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
let XK_bracketright: Int32 = 0x5d
let XK_grave: Int32 = 0x60
let XK_a: Int32 = 0x61
let XK_c: Int32 = 0x63
let XK_z: Int32 = 0x7a
let XK_asciitilde: Int32 = 0x7e
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
let XK_Shift_L: Int32 = 0x00ff_e1
let XK_Shift_R: Int32 = 0x00ff_e2
let XK_Control_L: Int32 = 0x00ff_e3
let XK_Control_R: Int32 = 0x00ff_e4
let XK_Caps_Lock: Int32 = 0x00ff_e5
let XK_Alt_L: Int32 = 0x00ff_e9
let XK_Alt_R: Int32 = 0x00ff_ea
let XK_KP_Enter: Int32 = 0x00ff_8d
let XK_Home: Int32 = 0x00ff_50
let XK_Left: Int32 = 0x00ff_51
let XK_Up: Int32 = 0x00ff_52
let XK_Right: Int32 = 0x00ff_53
let XK_Down: Int32 = 0x00ff_54
let XK_Page_Up: Int32 = 0x00ff_55
let XK_Page_Down: Int32 = 0x00ff_56
let XK_End: Int32 = 0x00ff_57
let XK_Delete: Int32 = 0x00ff_ff
// swiftlint:enable identifier_name

struct OwlKeycode {

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
}
