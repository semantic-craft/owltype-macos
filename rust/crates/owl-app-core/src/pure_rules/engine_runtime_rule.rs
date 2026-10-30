pub const ENGINE_OPTIONS: &[&str] = &[
    "ascii_mode",
    "ascii_punct",
    "full_shape",
    "traditional",
    "traditionalization",
    "zh_trad",
    "simplification",
    "transcription",
    "emoji",
    "vim_mode",
    "_linear",
    "_vertical",
    "_chord_typing",
    "no_inline",
    "inline",
    "soft_cursor",
];

pub fn is_valid_engine_option(name: &str) -> bool {
    ENGINE_OPTIONS.contains(&name)
}

pub fn refresh_decision(pending: bool, composing: bool) -> u32 {
    crate::keyboard::refresh_decision(pending, composing)
}
