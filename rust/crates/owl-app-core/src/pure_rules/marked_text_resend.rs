#[inline]
pub fn should_resend_marked_text(previous: &str, next: &str) -> bool {
    !(previous.is_empty() && next.is_empty())
}

#[inline]
pub fn should_resend_lengths(prev_len: usize, next_len: usize) -> bool {
    !(prev_len == 0 && next_len == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_marked_text_resend() {
        assert!(!should_resend_marked_text("", ""));
        assert!(should_resend_marked_text("a", ""));
        assert!(should_resend_marked_text("", "a"));
        assert!(should_resend_marked_text("a", "b"));
        assert!(should_resend_marked_text("a", "a"));
    }
}
