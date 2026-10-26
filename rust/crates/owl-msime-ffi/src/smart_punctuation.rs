//! JSON transport only; punctuation decisions belong to the pinned client-core module.
use msime_client_core::preferences::PunctuationLock;
use msime_client_core::punctuation::*;
use serde_json::{json, Value};

pub fn dispatch(value: &Value) -> Value {
    let flag = |name: &str, default| value[name].as_bool().unwrap_or(default);
    let number = |name: &str| value[name].as_u64().unwrap_or(0);
    let character = value["character"].as_u64().unwrap_or(0) as u8;
    let preceding = value["preceding"].as_str().and_then(|s| s.chars().next());
    let composition = flag("has_composition", false);
    let generation = number("editor_generation");
    let timestamp = number("timestamp_ms");
    let smart = flag("smart", true);
    match value["op"].as_str().unwrap_or("") {
        "route" => json!({"ascii": route(PunctuationContext {
            character, preceding, host_context_available: flag("available", false),
            has_composition: composition, chinese_punctuation: flag("chinese", true),
            smart_punctuation: smart, direct_digit: true, direct_letter: true,
            lock: PunctuationLock::Follow, caps_lock_ascii: false,
        }) == PunctuationRoute::Ascii}),
        "repeat" => json!({"replacement": should_replace_repeat(
        serde_json::from_value(value["snapshot"].clone()).ok(), RepeatContext {
            ascii: character, preceding, timestamp_ms: timestamp, editor_generation: generation,
            smart_punctuation: smart, repeat_enabled: flag("repeat_enabled", true),
            has_composition: composition, candidate_count: number("candidate_count") as usize,
        })}),
        "space" => json!({"replacement": decide_space_convert(
            serde_json::from_value(value["snapshot"].clone()).ok(), character, preceding,
            composition, generation).map(char::from)}),
        "arm" => {
            let committed = value["commit"].as_str().unwrap_or("");
            // macOS arms from the committed tail even when punctuation finishes a candidate.
            let tail = committed
                .chars()
                .next_back()
                .map(String::from)
                .unwrap_or_default();
            json!({
                "repeat": if smart && flag("repeat_enabled", true) && flag("chinese", true) {
                    arm_repeat(character, committed, timestamp, generation)
                } else { None },
                "space": arm_space_convert(&tail, flag("auto_closed_pair", false), smart,
                    flag("space_enabled", false), generation, character, &PunctuationMarks::default()),
            })
        }
        _ => json!({}),
    }
}
