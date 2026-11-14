//! Foundation CharacterSet compatibility shared by parser, stores and editor. Rust's
//! Unicode White_Space omits U+200B, which Foundation includes. Keep authored bytes intact;
//! callers explicitly choose whitespaces or whitespacesAndNewlines, as in the native API.
pub fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}
pub fn is_whitespace_and_newline(c: char) -> bool {
    c.is_whitespace() || c == '\u{200b}'
}
pub fn is_whitespace(c: char) -> bool {
    is_whitespace_and_newline(c) && !is_newline(c)
}
pub fn trim(text: &str) -> &str {
    text.trim_matches(is_whitespace_and_newline)
}
pub fn trim_spaces(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}
pub fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split(is_newline)
}

pub fn nfc(s: &str) -> String {
    icu_normalizer::ComposingNormalizer::new_nfc()
        .normalize(s)
        .into_owned()
}

pub fn title_ranks(titles: &[String]) -> Vec<usize> {
    let keys: Vec<String> = titles.iter().map(|t| nfc(t).to_lowercase()).collect();
    let mut order: Vec<usize> = (0..titles.len()).collect();
    order.sort_by(|&a, &b| keys[a].cmp(&keys[b]));
    let mut ranks = vec![0usize; titles.len()];
    let mut rank = 0usize;
    for (pos, &idx) in order.iter().enumerate() {
        if pos > 0 && keys[order[pos - 1]] != keys[idx] {
            rank += 1;
        }
        ranks[idx] = rank;
    }
    ranks
}

pub fn case_contains(values: &[String], target: &str) -> bool {
    let target = nfc(target).to_lowercase();
    values.iter().any(|v| nfc(v).to_lowercase() == target)
}

pub fn localized_contains(text: &str, query: &str) -> bool {
    nfc(text).to_lowercase().contains(&nfc(query).to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nfc_normalizes_canonical_equivalents() {
        assert_eq!(nfc("e\u{301}"), "\u{00e9}");
        assert_eq!(nfc("\u{00e9}"), "\u{00e9}");
    }

    #[test]
    fn title_ranks_folds_case_and_nfc_with_dense_ties() {
        let titles: Vec<String> = ["b", "A", "a\u{301}", "\u{00e1}"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(title_ranks(&titles), vec![1, 0, 2, 2]);
        assert_eq!(title_ranks(&[]), Vec::<usize>::new());
    }

    #[test]
    fn case_and_localized_containment_honor_nfc_and_unicode_case() {
        let tags: Vec<String> = ["Cafe\u{301}", "Work", "\u{00c1}lpha"]
            .into_iter()
            .map(String::from)
            .collect();
        assert!(case_contains(&tags, "CAF\u{00c9}"));
        assert!(case_contains(&tags, "a\u{301}lpha"));
        assert!(!case_contains(&tags, "cafe"));

        assert!(localized_contains("Resume\u{301} Draft", "\u{00c9}"));
        assert!(localized_contains("A\u{301}lpha", "\u{00e1}lp"));
        assert!(!localized_contains("Alpha", "beta"));
    }
}
