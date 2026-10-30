use std::collections::HashMap;

pub fn initial_mode(app: &str, fallback: bool, enabled: bool, modes: &HashMap<String, bool>) -> bool {
    if enabled {
        modes.get(app).copied().unwrap_or(fallback)
    } else {
        fallback
    }
}

pub fn should_remember(app: &str, ascii: bool, enabled: bool, current_mode: Option<bool>) -> bool {
    enabled && app.contains('.') && !app.starts_with("UnknownApp") && current_mode != Some(ascii)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_input_memory_rules() {
        let mut modes = HashMap::new();
        modes.insert("com.apple.Safari".to_string(), true);

        assert_eq!(initial_mode("com.apple.Safari", false, true, &modes), true);
        assert_eq!(initial_mode("com.apple.Safari", false, false, &modes), false);
        assert_eq!(initial_mode("com.apple.Terminal", false, true, &modes), false);

        assert!(should_remember("com.apple.Terminal", true, true, None));
        assert!(!should_remember("UnknownApp", true, true, None));
        assert!(!should_remember("com.apple.Safari", true, true, Some(true)));
        assert!(!should_remember("com.apple.Safari", true, false, None));
    }
}
