//! Owltype-owned business rules. Platform effects use explicit injected primitives;
//! no AppKit, IMK or credential dependencies.

pub mod keyboard;
pub mod keyboard_export;
pub mod template;

/// Existing per-application initial input mode; preferences are supplied by the host.
pub fn initial_ascii_mode(
    bundle_id: &str,
    english_bundle_ids: &[String],
    default_ascii: bool,
) -> bool {
    default_ascii || english_bundle_ids.iter().any(|id| id == bundle_id)
}

/// Convert a macOS UTF-16 range to UTF-8 byte boundaries, rejecting split surrogates.
/// Empty ranges are valid only at a scalar boundary. Addition never wraps.
pub fn utf16_range(text: &str, location: usize, length: usize) -> Option<std::ops::Range<usize>> {
    let end = location.checked_add(length)?;
    let mut units = 0;
    let mut start_byte = None;
    let mut end_byte = None;
    for (byte, character) in text.char_indices() {
        if units == location {
            start_byte = Some(byte);
        }
        if units == end {
            end_byte = Some(byte);
        }
        units += character.len_utf16();
    }
    if units == location {
        start_byte = Some(text.len());
    }
    if units == end {
        end_byte = Some(text.len());
    }
    Some(start_byte?..end_byte?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_ranges_do_not_split_surrogates_or_wrap() {
        let text = "中😀e\u{301}";
        assert_eq!(utf16_range(text, 1, 2), Some(3..7));
        assert_eq!(utf16_range(text, 2, 1), None);
        assert_eq!(utf16_range(text, 1, 1), None);
        assert_eq!(utf16_range(text, 5, 0), Some(10..10));
        assert_eq!(utf16_range(text, usize::MAX, 1), None);
        assert_eq!(utf16_range("", 0, 0), Some(0..0));
    }

    #[test]
    fn per_app_override_preserves_exact_match_and_default() {
        let apps = vec!["com.example.Editor".into()];
        assert!(initial_ascii_mode("com.example.Editor", &apps, false));
        assert!(!initial_ascii_mode("com.example.editor", &apps, false));
        assert!(initial_ascii_mode("other", &apps, true));
    }
}

pub mod config_writer;
pub mod foundation_text;
pub mod picker;
pub mod prompt_store;
pub mod quick_send;
pub mod storage;
pub mod template_backup;
pub mod template_editor;
pub mod template_import;
pub mod template_library;
pub mod template_migration;
pub mod template_transaction;

pub mod template_session;

pub mod host_delivery;

pub mod provider_wire;

pub mod provider_store;

pub mod provider_search;

pub mod ai_business;

pub mod ai_verification;

pub mod ai_selection;

pub mod user_data;

pub mod user_migration;

pub mod resource;

pub mod resource_contract;

pub mod resource_catalog;

pub mod resource_lifecycle;

pub mod client_capability;

pub mod agent;

pub mod pure_rules;
