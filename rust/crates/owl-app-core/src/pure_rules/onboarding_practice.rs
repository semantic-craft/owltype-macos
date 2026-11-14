pub const TARGET: &str = "你好，法墨";

pub fn is_complete(
    text: &str,
    target: &str,
    has_owl_commit: bool,
    has_other_source: bool,
    has_marked_text: bool,
) -> bool {
    text == target && has_owl_commit && !has_other_source && !has_marked_text
}

pub fn hint(has_other_source: bool) -> Option<&'static str> {
    if has_other_source {
        Some("包含其他输入法的内容，请清空后用法墨重新输入。")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_complete_and_hint() {
        assert!(is_complete(TARGET, TARGET, true, false, false));
        assert!(!is_complete("", TARGET, true, false, false));
        assert!(!is_complete(TARGET, TARGET, false, false, false));
        assert!(!is_complete(TARGET, TARGET, true, true, false));
        assert!(!is_complete(TARGET, TARGET, true, false, true));

        assert_eq!(
            hint(true),
            Some("包含其他输入法的内容，请清空后用法墨重新输入。")
        );
        assert_eq!(hint(false), None);
    }
}
