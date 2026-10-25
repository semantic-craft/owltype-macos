//! Minimal punctuation style types extracted from `msime-client-core` for `msime-input-runtime`.

use crate::preferences::BracketStyle;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuoteMarks {
    #[default]
    Curly,
    Corner,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct PunctuationMarks {
    pub quotes: QuoteMarks,
    pub brackets: BracketStyle,
    pub enumeration_comma_backslash: bool,
    pub enumeration_comma_slash: bool,
}

impl Default for PunctuationMarks {
    fn default() -> Self {
        Self {
            quotes: QuoteMarks::Curly,
            brackets: BracketStyle::Solid,
            enumeration_comma_backslash: true,
            enumeration_comma_slash: false,
        }
    }
}
