#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BoundaryKind {
    Cjk,
    Latin,
    Digit,
}

impl BoundaryKind {
    fn from_char(c: char) -> Option<Self> {
        let u = c as u32;
        if c.is_whitespace() {
            return None;
        }
        if matches!(u, 0x3400..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F) {
            Some(BoundaryKind::Cjk)
        } else if c.is_ascii_alphabetic() {
            Some(BoundaryKind::Latin)
        } else if c.is_ascii_digit() {
            Some(BoundaryKind::Digit)
        } else {
            None
        }
    }
}

fn needs_space(
    left: BoundaryKind,
    right: BoundaryKind,
    cjk_english_spacing: bool,
    cjk_number_spacing: bool,
) -> bool {
    match (left, right) {
        (BoundaryKind::Cjk, BoundaryKind::Latin) | (BoundaryKind::Latin, BoundaryKind::Cjk) => {
            cjk_english_spacing
        }
        (BoundaryKind::Cjk, BoundaryKind::Digit) | (BoundaryKind::Digit, BoundaryKind::Cjk) => {
            cjk_number_spacing
        }
        _ => false,
    }
}

pub fn apply_commit_transform(
    text: &str,
    cjk_english_spacing: bool,
    cjk_number_spacing: bool,
    previous: Option<char>,
) -> String {
    if !cjk_english_spacing && !cjk_number_spacing {
        return text.to_string();
    }
    let mut result = String::with_capacity(text.len() + 8);
    let mut prev = previous.and_then(BoundaryKind::from_char);
    for c in text.chars() {
        let current = BoundaryKind::from_char(c);
        if let (Some(p), Some(cur)) = (prev, current) {
            if needs_space(p, cur, cjk_english_spacing, cjk_number_spacing)
                && !result.ends_with(' ')
            {
                result.push(' ');
            }
        }
        result.push(c);
        prev = current;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_commit_transform_spacing() {
        assert_eq!(
            apply_commit_transform("hello中文world", true, true, None),
            "hello 中文 world"
        );
        assert_eq!(
            apply_commit_transform("中文123", true, true, None),
            "中文 123"
        );
        assert_eq!(
            apply_commit_transform("中文123", true, false, None),
            "中文123"
        );
        assert_eq!(
            apply_commit_transform("world", true, true, Some('中')),
            " world"
        );
    }
}
