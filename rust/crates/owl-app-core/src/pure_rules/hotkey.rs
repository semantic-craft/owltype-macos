use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const CONTROL_KEY: u32 = 0x1000;
pub const OPTION_KEY: u32 = 0x0800;
pub const SHIFT_KEY: u32 = 0x0200;
pub const CMD_KEY: u32 = 0x0100;
pub const ALLOWED_MODIFIER_BITS: u32 = CONTROL_KEY | OPTION_KEY | SHIFT_KEY | CMD_KEY;

pub fn is_letter_keycode(key_code: u32) -> bool {
    matches!(
        key_code,
        0 | 11 | 8 | 2 | 14 | 3 | 5 | 4 | 34 | 38 | 40 | 37 | 46 | 45 | 31 | 35 | 12 | 15 | 1 | 17 | 32 | 9 | 13 | 7 | 16 | 6
    )
}

pub fn letter_name(key_code: u32) -> Option<&'static str> {
    match key_code {
        0 => Some("A"),
        11 => Some("B"),
        8 => Some("C"),
        2 => Some("D"),
        14 => Some("E"),
        3 => Some("F"),
        5 => Some("G"),
        4 => Some("H"),
        34 => Some("I"),
        38 => Some("J"),
        40 => Some("K"),
        37 => Some("L"),
        46 => Some("M"),
        45 => Some("N"),
        31 => Some("O"),
        35 => Some("P"),
        12 => Some("Q"),
        15 => Some("R"),
        1 => Some("S"),
        17 => Some("T"),
        32 => Some("U"),
        9 => Some("V"),
        13 => Some("W"),
        7 => Some("X"),
        16 => Some("Y"),
        6 => Some("Z"),
        _ => None,
    }
}

pub fn keycode_from_letter(letter: &str) -> Option<u32> {
    match letter.to_uppercase().as_str() {
        "A" => Some(0),
        "B" => Some(11),
        "C" => Some(8),
        "D" => Some(2),
        "E" => Some(14),
        "F" => Some(3),
        "G" => Some(5),
        "H" => Some(4),
        "I" => Some(34),
        "J" => Some(38),
        "K" => Some(40),
        "L" => Some(37),
        "M" => Some(46),
        "N" => Some(45),
        "O" => Some(31),
        "P" => Some(35),
        "Q" => Some(12),
        "R" => Some(15),
        "S" => Some(1),
        "T" => Some(17),
        "U" => Some(32),
        "V" => Some(9),
        "W" => Some(13),
        "X" => Some(7),
        "Y" => Some(16),
        "Z" => Some(6),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordedHotKey {
    pub key_code: u32,
    pub modifiers: u32,
}

pub fn validate_hotkey(key_code: u32, modifiers: u32) -> Option<RecordedHotKey> {
    if !is_letter_keycode(key_code) {
        return None;
    }
    if modifiers & !ALLOWED_MODIFIER_BITS != 0 {
        return None;
    }
    if modifiers.count_ones() < 2 {
        return None;
    }
    Some(RecordedHotKey { key_code, modifiers })
}

pub fn hotkey_label(hotkey: &RecordedHotKey) -> String {
    let mut text = String::new();
    if hotkey.modifiers & CONTROL_KEY != 0 {
        text.push('⌃');
    }
    if hotkey.modifiers & OPTION_KEY != 0 {
        text.push('⌥');
    }
    if hotkey.modifiers & SHIFT_KEY != 0 {
        text.push('⇧');
    }
    if hotkey.modifiers & CMD_KEY != 0 {
        text.push('⌘');
    }
    text.push_str(letter_name(hotkey.key_code).unwrap_or("?"));
    text
}

pub fn encode_hotkey(hotkey: &RecordedHotKey) -> String {
    let mut tokens = Vec::new();
    if hotkey.modifiers & CONTROL_KEY != 0 {
        tokens.push("ctrl");
    }
    if hotkey.modifiers & OPTION_KEY != 0 {
        tokens.push("opt");
    }
    if hotkey.modifiers & SHIFT_KEY != 0 {
        tokens.push("shift");
    }
    if hotkey.modifiers & CMD_KEY != 0 {
        tokens.push("cmd");
    }
    tokens.push(letter_name(hotkey.key_code).unwrap_or("?"));
    tokens.join("+")
}

pub fn decode_hotkey(
    raw: &str,
    legacy_presets: &HashMap<String, (u32, u32)>,
) -> Option<RecordedHotKey> {
    if let Some(&(key_code, modifiers)) = legacy_presets.get(raw) {
        return Some(RecordedHotKey { key_code, modifiers });
    }
    let tokens: Vec<&str> = raw.split('+').collect();
    if tokens.len() < 2 {
        return None;
    }
    let letter = tokens.last()?;
    let key_code = keycode_from_letter(letter)?;
    let mut modifiers: u32 = 0;
    for &token in &tokens[..tokens.len() - 1] {
        match token {
            "ctrl" => modifiers |= CONTROL_KEY,
            "opt" => modifiers |= OPTION_KEY,
            "shift" => modifiers |= SHIFT_KEY,
            "cmd" => modifiers |= CMD_KEY,
            _ => return None,
        }
    }
    validate_hotkey(key_code, modifiers)
}

pub fn hotkey_matches(combo: (u32, u32), key_code: u16, flags: u64) -> bool {
    if combo.0 != key_code as u32 {
        return false;
    }
    let mut expected_flags: u64 = 0;
    if combo.1 & CONTROL_KEY != 0 {
        expected_flags |= 1 << 18;
    }
    if combo.1 & OPTION_KEY != 0 {
        expected_flags |= 1 << 19;
    }
    if combo.1 & SHIFT_KEY != 0 {
        expected_flags |= 1 << 17;
    }
    if combo.1 & CMD_KEY != 0 {
        expected_flags |= 1 << 20;
    }
    let held = flags & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20));
    held == expected_flags
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_and_encode() {
        let hotkey = validate_hotkey(0, CONTROL_KEY | SHIFT_KEY).unwrap();
        assert_eq!(hotkey_label(&hotkey), "⌃⇧A");
        assert_eq!(encode_hotkey(&hotkey), "ctrl+shift+A");

        let decoded = decode_hotkey("ctrl+shift+A", &HashMap::new()).unwrap();
        assert_eq!(decoded, hotkey);
    }

    #[test]
    fn test_single_modifier_rejected() {
        assert_eq!(validate_hotkey(0, CONTROL_KEY), None);
    }
}
