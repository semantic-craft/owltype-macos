//! Minimal preference types extracted from `msime-client-core` for `msime-input-runtime`.

use serde::{Deserialize, Serialize};

pub const MAX_CANDIDATE_PAGE_SIZE: u8 = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TouchKeyboardLayout {
    #[default]
    TwentySixKey,
    NineKey,
    Handwriting,
    FourteenKey,
    NineKeyShuangpin,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BracketStyle {
    #[default]
    Solid,
    Hollow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SecondThirdCandidateKeys {
    #[default]
    SemicolonQuote,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SecondThirdCandidatePreferences {
    pub enabled: bool,
    pub keys: SecondThirdCandidateKeys,
}

impl SecondThirdCandidatePreferences {
    pub fn slot(&self, value: u8) -> Option<usize> {
        if !self.enabled {
            return None;
        }
        match self.keys {
            SecondThirdCandidateKeys::SemicolonQuote => match value {
                b';' => Some(1),
                b'\'' => Some(2),
                _ => None,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct WubiCandidateSelectionPreferences {
    pub enabled: bool,
    pub second_key: String,
    pub third_key: String,
}

impl Default for WubiCandidateSelectionPreferences {
    fn default() -> Self {
        Self {
            enabled: false,
            second_key: ";".into(),
            third_key: "'".into(),
        }
    }
}

impl WubiCandidateSelectionPreferences {
    pub fn validate(&self) -> bool {
        let valid = |key: &str| key.len() == 1 && key.as_bytes()[0].is_ascii_punctuation();
        valid(&self.second_key) && valid(&self.third_key) && self.second_key != self.third_key
    }

    pub fn slot(&self, value: u8) -> Option<usize> {
        if !self.enabled || !self.validate() {
            return None;
        }
        if self.second_key.as_bytes() == [value] {
            Some(1)
        } else if self.third_key.as_bytes() == [value] {
            Some(2)
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PunctuationLock {
    #[default]
    Follow,
    Chinese,
    English,
}
