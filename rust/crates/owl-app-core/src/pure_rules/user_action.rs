use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawKeyEvent {
    #[serde(alias = "eventType")]
    pub event_type: String, // "keyDown", "flagsChanged", "other"
    #[serde(alias = "keyCode")]
    pub key_code: u16,
    pub characters: Option<String>,
    #[serde(alias = "charactersIgnoringModifiers")]
    pub characters_ignoring_modifiers: Option<String>,
    #[serde(alias = "modifierFlags", alias = "flags")]
    pub modifier_flags: u64,
    #[serde(alias = "lastModifiers", default)]
    pub last_modifiers: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum UserAction {
    KeyDown {
        engine_keycode: u32,
        engine_modifiers: u32,
    },
    FlagsChanged {
        caps_lock_revert: Option<(u32, u32)>,
        events: Vec<(u32, u32)>,
        update_last_modifiers: u64,
        handled: bool,
    },
    FlagsUnchanged,
    CommandPassthrough,
    Ignored,
}

pub const K_SHIFT_MASK: u32 = 0x0000_0001;
pub const K_LOCK_MASK: u32 = 0x0000_0002;
pub const K_CONTROL_MASK: u32 = 0x0000_0004;
pub const K_ALT_MASK: u32 = 0x0000_0008;
pub const K_SUPER_MASK: u32 = 0x0400_0000;
pub const K_RELEASE_MASK: u32 = 0x4000_0000;

pub const NS_CAPS_LOCK_FLAG: u64 = 1 << 16;
pub const NS_SHIFT_FLAG: u64 = 1 << 17;
pub const NS_CONTROL_FLAG: u64 = 1 << 18;
pub const NS_OPTION_FLAG: u64 = 1 << 19;
pub const NS_COMMAND_FLAG: u64 = 1 << 20;

pub fn osx_modifiers_to_engine(modifiers: u64) -> u32 {
    let mut res: u32 = 0;
    if modifiers & NS_SHIFT_FLAG != 0 { res |= K_SHIFT_MASK; }
    if modifiers & NS_CAPS_LOCK_FLAG != 0 { res |= K_LOCK_MASK; }
    if modifiers & NS_CONTROL_FLAG != 0 { res |= K_CONTROL_MASK; }
    if modifiers & NS_OPTION_FLAG != 0 { res |= K_ALT_MASK; }
    if modifiers & NS_COMMAND_FLAG != 0 { res |= K_SUPER_MASK; }
    res
}

pub fn infer_modifier_keycode(changes: u64) -> Option<u16> {
    if changes & NS_SHIFT_FLAG != 0 { Some(0x38) }
    else if changes & NS_CONTROL_FLAG != 0 { Some(0x3b) }
    else if changes & NS_OPTION_FLAG != 0 { Some(0x3a) }
    else if changes & NS_COMMAND_FLAG != 0 { Some(0x37) }
    else if changes & NS_CAPS_LOCK_FLAG != 0 { Some(0x39) }
    else { None }
}

pub const MODIFIER_KEYCODES: &[u16] = &[
    0x38, // Shift
    0x3c, // RightShift
    0x3b, // Control
    0x3e, // RightControl
    0x3a, // Option
    0x3d, // RightOption
    0x37, // Command
    0x36, // RightCommand
    0x39, // CapsLock
    0x3f, // Function
];

pub fn resolve_key_chars<'a>(
    characters_ignoring_modifiers: Option<&'a str>,
    characters: Option<&'a str>,
    modifiers: u64,
) -> Option<&'a str> {
    let mut key_chars = characters_ignoring_modifiers;
    let capital_modifiers = (modifiers & !(NS_SHIFT_FLAG | NS_CAPS_LOCK_FLAG)) == 0;
    if let Some(first_char) = key_chars.and_then(|s| s.chars().next()) {
        if (capital_modifiers && !first_char.is_alphabetic())
            || (!capital_modifiers && !first_char.is_ascii())
        {
            key_chars = characters;
        }
    }
    key_chars
}

pub fn classify_user_action_with<F>(event: &RawKeyEvent, osx_keycode_to_engine: F) -> UserAction
where
    F: Fn(u16, Option<char>, bool, bool) -> u32,
{
    let modifiers = event.modifier_flags;
    let changes = event.last_modifiers ^ modifiers;

    match event.event_type.as_str() {
        "flagsChanged" => {
            if event.last_modifiers == modifiers {
                return UserAction::FlagsUnchanged;
            }
            let mut engine_modifiers = osx_modifiers_to_engine(modifiers);
            let mut key_code = event.key_code;
            if !MODIFIER_KEYCODES.contains(&key_code) {
                match infer_modifier_keycode(changes) {
                    Some(inferred) => key_code = inferred,
                    None => {
                        return UserAction::FlagsChanged {
                            caps_lock_revert: None,
                            events: vec![],
                            update_last_modifiers: modifiers,
                            handled: true,
                        };
                    }
                }
            }
            let engine_keycode = osx_keycode_to_engine(key_code, None, false, false);
            let mut caps_lock_revert = None;
            if changes & NS_CAPS_LOCK_FLAG != 0 {
                engine_modifiers ^= K_LOCK_MASK;
                caps_lock_revert = Some((engine_keycode, engine_modifiers));
            }

            let mut buffer = Vec::new();
            for &(flag, _) in &[
                (NS_SHIFT_FLAG, "shift"),
                (NS_CONTROL_FLAG, "control"),
                (NS_OPTION_FLAG, "option"),
                (NS_COMMAND_FLAG, "command"),
            ] {
                if changes & flag != 0 {
                    if modifiers & flag != 0 {
                        buffer.push((engine_keycode, engine_modifiers));
                    } else {
                        buffer.insert(0, (engine_keycode, engine_modifiers | K_RELEASE_MASK));
                    }
                }
            }
            UserAction::FlagsChanged {
                caps_lock_revert,
                events: buffer,
                update_last_modifiers: modifiers,
                handled: false,
            }
        }
        "keyDown" => {
            if modifiers & NS_COMMAND_FLAG != 0 {
                return UserAction::CommandPassthrough;
            }
            let key_chars = resolve_key_chars(
                event.characters_ignoring_modifiers.as_deref(),
                event.characters.as_deref(),
                modifiers,
            );
            let Some(first_char) = key_chars.and_then(|s| s.chars().next()) else {
                return UserAction::Ignored;
            };
            let engine_keycode = osx_keycode_to_engine(
                event.key_code,
                Some(first_char),
                modifiers & NS_SHIFT_FLAG != 0,
                modifiers & NS_CAPS_LOCK_FLAG != 0,
            );
            if engine_keycode == 0 {
                return UserAction::Ignored;
            }
            let engine_modifiers = osx_modifiers_to_engine(modifiers);
            UserAction::KeyDown {
                engine_keycode,
                engine_modifiers,
            }
        }
        _ => UserAction::Ignored,
    }
}

pub fn osx_keycode_to_engine(keycode: u16, keychar: Option<char>, shift: bool, caps: bool) -> u32 {
    // 1. Direct keycode mappings (modifiers, navigation, keypad, function keys, special, other)
    match keycode {
        0x39 => 0x00ff_e5, // CapsLock -> XK_Caps_Lock
        0x37 => 0x00ff_eb, // Command -> XK_Super_L
        0x36 => 0x00ff_ec, // RightCommand -> XK_Super_R
        0x3b => 0x00ff_e3, // Control -> XK_Control_L
        0x3e => 0x00ff_e4, // RightControl -> XK_Control_R
        0x3f => 0x00ff_ed, // Function -> XK_Hyper_L
        0x3a => 0x00ff_e9, // Option -> XK_Alt_L
        0x3d => 0x00ff_ea, // RightOption -> XK_Alt_R
        0x38 => 0x00ff_e1, // Shift -> XK_Shift_L
        0x3c => 0x00ff_e2, // RightShift -> XK_Shift_R
        0x33 => 0x00ff_08, // Delete -> XK_BackSpace
        0x35 => 0x00ff_1b, // Escape -> XK_Escape
        0x75 => 0x00ff_ff, // ForwardDelete -> XK_Delete
        0x72 => 0x00ff_6a, // Help -> XK_Help
        0x24 => 0x00ff_0d, // Return -> XK_Return
        0x31 => 0x0000_20, // Space -> XK_space
        0x30 => 0x00ff_09, // Tab -> XK_Tab
        0x7a => 0x00ff_be, // F1
        0x78 => 0x00ff_bf, // F2
        0x63 => 0x00ff_c0, // F3
        0x76 => 0x00ff_c1, // F4
        0x60 => 0x00ff_c2, // F5
        0x61 => 0x00ff_c3, // F6
        0x62 => 0x00ff_c4, // F7
        0x64 => 0x00ff_c5, // F8
        0x65 => 0x00ff_c6, // F9
        0x6d => 0x00ff_c7, // F10
        0x67 => 0x00ff_c8, // F11
        0x6f => 0x00ff_c9, // F12
        0x69 => 0x00ff_ca, // F13
        0x6b => 0x00ff_cb, // F14
        0x71 => 0x00ff_cc, // F15
        0x6a => 0x00ff_cd, // F16
        0x40 => 0x00ff_ce, // F17
        0x4f => 0x00ff_cf, // F18
        0x50 => 0x00ff_d0, // F19
        0x5a => 0x00ff_d1, // F20
        0x7e => 0x00ff_52, // UpArrow -> XK_Up
        0x7d => 0x00ff_54, // DownArrow -> XK_Down
        0x7b => 0x00ff_51, // LeftArrow -> XK_Left
        0x7c => 0x00ff_53, // RightArrow -> XK_Right
        0x74 => 0x00ff_55, // PageUp -> XK_Page_Up
        0x79 => 0x00ff_56, // PageDown -> XK_Page_Down
        0x73 => 0x00ff_50, // Home -> XK_Home
        0x77 => 0x00ff_57, // End -> XK_End
        0x52 => 0x00ff_b0, // Keypad0 -> XK_KP_0
        0x53 => 0x00ff_b1, // Keypad1 -> XK_KP_1
        0x54 => 0x00ff_b2, // Keypad2 -> XK_KP_2
        0x55 => 0x00ff_b3, // Keypad3 -> XK_KP_3
        0x56 => 0x00ff_b4, // Keypad4 -> XK_KP_4
        0x57 => 0x00ff_b5, // Keypad5 -> XK_KP_5
        0x58 => 0x00ff_b6, // Keypad6 -> XK_KP_6
        0x59 => 0x00ff_b7, // Keypad7 -> XK_KP_7
        0x5b => 0x00ff_b8, // Keypad8 -> XK_KP_8
        0x5c => 0x00ff_b9, // Keypad9 -> XK_KP_9
        0x47 => 0x00ff_0b, // KeypadClear -> XK_Clear
        0x41 => 0x00ff_ae, // KeypadDecimal -> XK_KP_Decimal
        0x51 => 0x00ff_bd, // KeypadEquals -> XK_KP_Equal
        0x4e => 0x00ff_ad, // KeypadMinus -> XK_KP_Subtract
        0x43 => 0x00ff_aa, // KeypadMultiply -> XK_KP_Multiply
        0x45 => 0x00ff_ab, // KeypadPlus -> XK_KP_Add
        0x4b => 0x00ff_af, // KeypadDivide -> XK_KP_Divide
        0x4c => 0x00ff_8d, // KeypadEnter -> XK_KP_Enter
        0x0a => 0x00a7,    // ISO_Section -> XK_section
        0x5d => 0x00a5,    // JIS_Yen -> XK_yen
        0x5e => 0x005f,    // JIS_Underscore -> XK_underscore
        0x5f => 0x2c,      // JIS_KeypadComma -> XK_comma
        0x66 => 0x00ff_2f, // JIS_Eisu -> XK_Eisu_Shift
        0x68 => 0x00ff_2e, // JIS_Kana -> XK_Kana_Shift
        _ => {
            // 2. ASCII Character resolution
            if let Some(c) = keychar {
                if c.is_ascii() {
                    let code_val = c as u32;
                    if c.is_ascii_lowercase() && (shift != caps) {
                        return c.to_ascii_uppercase() as u32;
                    }
                    match code_val {
                        0x20..=0x7e => return code_val,
                        0x1b => return 0x5b, // [
                        0x1c => return 0x5c, // \
                        0x1d => return 0x5d, // ]
                        0x1f => return 0x2d, // -
                        _ => {}
                    }
                }
            }
            // 3. Additional code mappings (numbers, punctuation, letters)
            match keycode {
                0x1d => 0x30, 0x12 => 0x31, 0x13 => 0x32, 0x14 => 0x33, 0x15 => 0x34,
                0x17 => 0x35, 0x16 => 0x36, 0x1a => 0x37, 0x1c => 0x38, 0x19 => 0x39,
                0x1e => 0x5d, 0x21 => 0x5b, 0x2b => 0x2c, 0x32 => 0x60, 0x2f => 0x2e,
                0x29 => 0x3b, 0x27 => 0x27, 0x2a => 0x5c, 0x1b => 0x2d, 0x2c => 0x2f,
                0x18 => 0x3d,
                0x00 => 0x61, 0x0b => 0x62, 0x08 => 0x63, 0x02 => 0x64, 0x0e => 0x65,
                0x03 => 0x66, 0x05 => 0x67, 0x04 => 0x68, 0x22 => 0x69, 0x26 => 0x6a,
                0x28 => 0x6b, 0x25 => 0x6c, 0x2e => 0x6d, 0x2d => 0x6e, 0x1f => 0x6f,
                0x23 => 0x70, 0x0c => 0x71, 0x0f => 0x72, 0x01 => 0x73, 0x11 => 0x74,
                0x20 => 0x75, 0x09 => 0x76, 0x0d => 0x77, 0x07 => 0x78, 0x10 => 0x79,
                0x06 => 0x7a,
                _ => 0x00ff_ffff, // XK_VoidSymbol
            }
        }
    }
}

pub fn classify_user_action(event: &RawKeyEvent) -> UserAction {
    classify_user_action_with(event, osx_keycode_to_engine)
}

pub fn classify_user_action_value(val: &Value) -> Result<UserAction, String> {
    let event_val = val.get("event").unwrap_or(val);
    let event: RawKeyEvent = serde_json::from_value(event_val.clone())
        .map_err(|e| format!("invalid_event: {}", e))?;
    Ok(classify_user_action(&event))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_osx_keycode_letter_a() {
        let code = osx_keycode_to_engine(0, Some('a'), false, false);
        assert_eq!(code, 0x61); // 'a'
        let code_shift = osx_keycode_to_engine(0, Some('a'), true, false);
        assert_eq!(code_shift, 0x41); // 'A'
        let code_cancel = osx_keycode_to_engine(0, Some('a'), true, true);
        assert_eq!(code_cancel, 0x61); // 'a'
    }

    #[test]
    fn test_classify_keydown_a() {
        let event = RawKeyEvent {
            event_type: "keyDown".into(),
            key_code: 0,
            characters: Some("a".into()),
            characters_ignoring_modifiers: Some("a".into()),
            modifier_flags: 0,
            last_modifiers: 0,
        };
        let action = classify_user_action(&event);
        assert_eq!(
            action,
            UserAction::KeyDown {
                engine_keycode: 0x61,
                engine_modifiers: 0,
            }
        );
    }

    #[test]
    fn test_classify_command_passthrough() {
        let event = RawKeyEvent {
            event_type: "keyDown".into(),
            key_code: 8, // 'c'
            characters: Some("c".into()),
            characters_ignoring_modifiers: Some("c".into()),
            modifier_flags: NS_COMMAND_FLAG,
            last_modifiers: 0,
        };
        let action = classify_user_action(&event);
        assert_eq!(action, UserAction::CommandPassthrough);
    }
}
