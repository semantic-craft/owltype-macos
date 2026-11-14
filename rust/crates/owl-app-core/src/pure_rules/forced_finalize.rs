pub fn commit_text(preview: Option<&str>, input: &str) -> String {
    if let Some(p) = preview {
        if !p.is_empty() {
            return p.to_string();
        }
    }
    input.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_forced_finalize_commit_text() {
        assert_eq!(commit_text(Some("你好"), "nihao"), "你好");
        assert_eq!(commit_text(Some(""), "nihao"), "nihao");
        assert_eq!(commit_text(None, "nihao"), "nihao");
    }
}
