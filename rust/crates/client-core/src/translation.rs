//! Minimal translation display types extracted from `msime-client-core` for `msime-input-runtime`.

use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TranslationRunRole {
    Pos,
    Separator,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TranslationRun {
    pub start: usize,
    pub length: usize,
    pub role: TranslationRunRole,
}

pub fn source_gets_no_gloss(source: u8) -> bool {
    matches!(source, 6 | 7 | 13 | 14 | 15 | 16)
}

pub fn translation_runs(gloss: &str) -> Vec<TranslationRun> {
    const LABELS: [&str; 13] = [
        "proper n. ",
        "interj. ",
        "idiom. ",
        "pron. ",
        "prep. ",
        "conj. ",
        "adj. ",
        "adv. ",
        "num. ",
        "det. ",
        "aux. ",
        "n. ",
        "v. ",
    ];
    let mut runs: Vec<TranslationRun> = Vec::new();
    let mut push = |start: usize, length: usize, role| {
        if let Some(last) = runs.last_mut() {
            if last.role == role && last.start + last.length == start {
                last.length += length;
                return;
            }
        }
        runs.push(TranslationRun {
            start,
            length,
            role,
        });
    };
    let mut start = 0;
    for (end, separator_width) in gloss
        .char_indices()
        .filter(|(_, ch)| matches!(ch, ';' | '；'))
        .map(|(at, ch)| (at, ch.len_utf8()))
        .chain(std::iter::once((gloss.len(), 0)))
    {
        let sense = &gloss[start..end];
        let trimmed = sense.trim_start_matches([' ', '\t', '\r', '\n']);
        if let Some(label) = LABELS
            .iter()
            .find(|label| trimmed.len() > label.len() && trimmed.starts_with(**label))
        {
            push(
                start + sense.len() - trimmed.len(),
                label.len() - 1,
                TranslationRunRole::Pos,
            );
        }
        if separator_width != 0 {
            push(end, separator_width, TranslationRunRole::Separator);
        }
        start = end + separator_width;
    }
    runs
}
