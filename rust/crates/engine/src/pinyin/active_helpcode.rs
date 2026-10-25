//! Quanpin helpcode detection (quanpin.md §8, QU:471-508): trailing uppercase letters after complete pinyin filter or reorder the candidates.

use super::segment::is_complete_pinyin_input;
use crate::helpcode::{is_quanpin_double_help_mode, is_quanpin_single_help_mode};

/// Whether `raw_input` minus its last `strip` letters is complete pinyin.
fn has_complete_base(raw_input: &str, strip: usize) -> bool {
    raw_input.len() >= strip
        && raw_input
            .get(..raw_input.len() - strip)
            .is_some_and(is_complete_pinyin_input)
}

/// 2 for double help mode over a complete prefix, 1 for single, else 0.
pub fn detect_active_helpcode_length(raw_input: &str, raw_input_with_cases: &str) -> usize {
    let cased = if raw_input_with_cases.is_empty() {
        raw_input
    } else {
        raw_input_with_cases
    };
    if is_quanpin_double_help_mode(cased) && has_complete_base(raw_input, 2) {
        2
    } else if is_quanpin_single_help_mode(cased) && has_complete_base(raw_input, 1) {
        1
    } else {
        0
    }
}

/// Drops the last `length` bytes, or returns `text` whole when it is shorter (QU:489-508). A non-zero length was detected on ASCII capitals over a base that sliced cleanly, so the cut falls on a character boundary.
fn without_tail(text: &str, length: usize) -> String {
    if length == 0 || text.len() < length {
        return text.to_owned();
    }
    text[..text.len() - length].to_owned()
}

/// `raw_input` without the active helpcode letters.
pub fn strip_active_helpcodes(raw_input: &str, raw_input_with_cases: &str) -> String {
    without_tail(
        raw_input,
        detect_active_helpcode_length(raw_input, raw_input_with_cases),
    )
}

/// `raw_input_with_cases` without the active helpcode letters.
pub fn strip_active_helpcodes_with_cases(raw_input: &str, raw_input_with_cases: &str) -> String {
    let cased = if raw_input_with_cases.is_empty() {
        raw_input
    } else {
        raw_input_with_cases
    };
    without_tail(
        cased,
        detect_active_helpcode_length(raw_input, raw_input_with_cases),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // test_input_session.cpp:978-988.
    #[test]
    fn helpcodes_activate_only_after_complete_pinyin() {
        assert_eq!(detect_active_helpcode_length("jinianriz", "jinianriZ"), 1);
        assert_eq!(strip_active_helpcodes("jinianriz", "jinianriZ"), "jinianri");
        assert_eq!(detect_active_helpcode_length("nihc", "nihC"), 0);
        assert_eq!(strip_active_helpcodes("nihc", "nihC"), "nihc");
    }

    #[test]
    fn double_and_single_modes() {
        assert_eq!(detect_active_helpcode_length("nihaoab", "nihaoAB"), 2);
        assert_eq!(strip_active_helpcodes("nihaoab", "nihaoAB"), "nihao");
        assert_eq!(
            strip_active_helpcodes_with_cases("nihaoab", "NihaoAB"),
            "Nihao"
        );
        // One capital over a complete base.
        assert_eq!(detect_active_helpcode_length("nihaoc", "nihaoC"), 1);
        assert_eq!(
            strip_active_helpcodes_with_cases("nihaoc", "nihaoC"),
            "nihao"
        );
        // Two capitals over an incomplete base fall through to neither mode: single mode excludes double shapes.
        assert_eq!(detect_active_helpcode_length("nihab", "nihAB"), 0);
        assert_eq!(detect_active_helpcode_length("nihao", "nihao"), 0);
        // Without a cased copy the lowercase input is tested, which never has a helpcode.
        assert_eq!(detect_active_helpcode_length("nihaoc", ""), 0);
        assert_eq!(strip_active_helpcodes_with_cases("nihaoc", ""), "nihaoc");
        assert_eq!(detect_active_helpcode_length("c", "C"), 0);
        assert_eq!(detect_active_helpcode_length("", ""), 0);
        assert_eq!(detect_active_helpcode_length("xi'anc", "xi'anC"), 1);
    }
}
