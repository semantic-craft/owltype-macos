use serde::{Deserialize, Serialize};

pub const PAIRS: &[(char, char)] = &[
    ('（', '）'),
    ('【', '】'),
    ('《', '》'),
    ('〈', '〉'),
    ('「', '」'),
    ('『', '』'),
    ('〔', '〕'),
    ('“', '”'),
    ('‘', '’'),
    ('<', '>'),
    ('(', ')'),
    ('[', ']'),
    ('{', '}'),
];

pub fn single_closer(text: &str) -> Option<char> {
    let mut chars = text.chars();
    let first = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    if PAIRS.iter().any(|(_, close)| *close == first) {
        Some(first)
    } else {
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AutoPairAction {
    Plain,
    Pair {
        open: String,
        close: String,
        caret_move: bool,
    },
    SkipOver {
        close: String,
    },
}

pub fn decide(
    enabled: bool,
    commit_text: &str,
    right_neighbor: Option<char>,
    caret_move_allowed: bool,
) -> AutoPairAction {
    if !enabled {
        return AutoPairAction::Plain;
    }
    let mut chars = commit_text.chars();
    let first = match chars.next() {
        Some(c) => c,
        None => return AutoPairAction::Plain,
    };
    if chars.next().is_some() {
        return AutoPairAction::Plain;
    }
    if let Some(&(_, close)) = PAIRS.iter().find(|(open, _)| *open == first) {
        return AutoPairAction::Pair {
            open: first.to_string(),
            close: close.to_string(),
            caret_move: caret_move_allowed,
        };
    }
    if PAIRS.iter().any(|(_, close)| *close == first) && right_neighbor == Some(first) {
        return AutoPairAction::SkipOver {
            close: first.to_string(),
        };
    }
    AutoPairAction::Plain
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_auto_pair_disabled() {
        assert_eq!(
            decide(false, "（", Some('）'), true),
            AutoPairAction::Plain
        );
    }

    #[test]
    fn test_auto_pair_open() {
        assert_eq!(
            decide(true, "（", None, true),
            AutoPairAction::Pair {
                open: "（".into(),
                close: "）".into(),
                caret_move: true,
            }
        );
    }

    #[test]
    fn test_auto_pair_skip_over() {
        assert_eq!(
            decide(true, "）", Some('）'), true),
            AutoPairAction::SkipOver {
                close: "）".into(),
            }
        );
    }

    #[test]
    fn test_single_closer() {
        assert_eq!(single_closer("）"), Some('）'));
        assert_eq!(single_closer("（"), None);
        assert_eq!(single_closer("）abc"), None);
    }
}
