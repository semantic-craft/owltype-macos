//! `U` mode (unicode_query.cpp:39-87): an optional `+` and 1..=6 hex digits that name a scalar value; U+0000 is accepted.

use crate::types::{CandidateSource, WordItem};

const MAXIMUM_DIGITS: usize = 6;

/// One Generated row: the character, `pinyin = "U+%04X"`, weight = digit count.
pub fn query_unicode(code: &str) -> Vec<WordItem> {
    let hex = code.strip_prefix('+').unwrap_or(code);
    if hex.is_empty()
        || hex.len() > MAXIMUM_DIGITS
        || !hex.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Vec::new();
    }
    // Six hex digits always fit in a u32; `from_u32` rejects surrogates and values past U+10FFFF.
    let Some(character) = u32::from_str_radix(hex, 16).ok().and_then(char::from_u32) else {
        return Vec::new();
    };
    vec![WordItem::new(
        format!("U+{:04X}", u32::from(character)),
        character.to_string(),
        hex.len() as i64,
        CandidateSource::Generated,
        "",
    )]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn single(code: &str) -> WordItem {
        let rows = query_unicode(code);
        assert_eq!(rows.len(), 1, "{code}");
        rows.into_iter().next().unwrap()
    }

    #[test]
    fn scalar_values() {
        let han = single("4e00");
        assert_eq!(han.word, "一");
        assert_eq!(han.pinyin, "U+4E00");
        assert_eq!(han.weight, 4);
        assert_eq!(han.source, CandidateSource::Generated);
        assert!(han.canonical_pinyin.is_empty());

        let emoji = single("1F600");
        assert_eq!(emoji.word, "😀");
        assert_eq!(emoji.pinyin, "U+1F600");
        assert_eq!(emoji.weight, 5);

        let plus = single("+41");
        assert_eq!(plus.word, "A");
        assert_eq!(plus.pinyin, "U+0041");
        assert_eq!(plus.weight, 2);

        let nul = single("0");
        assert_eq!(nul.word, "\0");
        assert_eq!(nul.pinyin, "U+0000");

        assert_eq!(single("10ffff").pinyin, "U+10FFFF");
        assert_eq!(single("00004e").weight, 6);
    }

    #[test]
    fn rejected_codes() {
        for code in [
            "", "+", "++41", "d800", "DFFF", "110000", "0000001", "4e0g", "-41", " 41", "４１",
        ] {
            assert!(query_unicode(code).is_empty(), "{code:?}");
        }
    }
}
