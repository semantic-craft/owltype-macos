use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawKeyEvent {
    pub event_type: String, // "keyDown", "flagsChanged", "other"
    pub key_code: u16,
    pub characters: Option<String>,
    pub characters_ignoring_modifiers: Option<String>,
    pub modifier_flags: u64,
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
