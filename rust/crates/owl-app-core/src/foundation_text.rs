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
