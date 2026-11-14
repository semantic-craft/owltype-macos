pub mod app_input_memory;
pub mod commit_transform;
pub mod emoji;
pub mod forced_finalize;
pub mod hotkey;
pub mod input_source_diag;
pub mod logout_prompt;
pub mod marked_text_resend;
pub mod onboarding_practice;
pub mod user_action;

use serde_json::{json, Value};
use std::collections::HashMap;

pub fn dispatch(rule: &str, args: Value) -> Result<Value, String> {
    match rule {
        "commit_transform_apply" => {
            let text = args["text"].as_str().unwrap_or("");
            let cjk_english = args["cjk_english_spacing"].as_bool().unwrap_or(false);
            let cjk_number = args["cjk_number_spacing"].as_bool().unwrap_or(false);
            let previous = args["previous"].as_str().and_then(|s| s.chars().next());
            let transformed = commit_transform::apply_commit_transform(
                text,
                cjk_english,
                cjk_number,
                previous,
            );
            Ok(json!(transformed))
        }

        "forced_finalize_commit_text" => {
            let preview = args["preview"].as_str();
            let input = args["input"].as_str().unwrap_or("");
            let text = forced_finalize::commit_text(preview, input);
            Ok(json!(text))
        }

        "user_action_classify" => {
            let action = user_action::classify_user_action_value(&args)?;
            Ok(json!(action))
        }

        "app_input_memory_initial_mode" => {
            let app = args["app"].as_str().unwrap_or("");
            let fallback = args["fallback"].as_bool().unwrap_or(false);
            let enabled = args["enabled"].as_bool().unwrap_or(true);
            let modes: HashMap<String, bool> = serde_json::from_value(args["modes"].clone())
                .unwrap_or_default();
            let mode = app_input_memory::initial_mode(app, fallback, enabled, &modes);
            Ok(json!(mode))
        }
        "app_input_memory_should_remember" => {
            let app = args["app"].as_str().unwrap_or("");
            let ascii = args["ascii"].as_bool().unwrap_or(false);
            let enabled = args["enabled"].as_bool().unwrap_or(true);
            let modes: HashMap<String, bool> = serde_json::from_value(args["modes"].clone())
                .unwrap_or_default();
            let current_mode = args.get("current_mode").and_then(|v| v.as_bool()).or_else(|| modes.get(app).copied());
            let should = app_input_memory::should_remember(app, ascii, enabled, current_mode);
            Ok(json!(should))
        }

        "onboarding_practice_is_complete" => {
            let target = args["target"]
                .as_str()
                .unwrap_or(onboarding_practice::TARGET);
            let text = args["text"].as_str().unwrap_or("");
            let has_owl_commit = args["has_owl_commit"].as_bool().unwrap_or(false);
            let has_other_source = args["has_other_source"].as_bool().unwrap_or(false);
            let has_marked_text = args["has_marked_text"].as_bool().unwrap_or(false);
            let is_complete = text == target && has_owl_commit && !has_other_source && !has_marked_text;
            Ok(json!(is_complete))
        }
        "onboarding_practice_hint" => {
            let has_other_source = args["has_other_source"].as_bool().unwrap_or(false);
            let hint = if has_other_source {
                Some("包含其他输入法的内容，请清空后用法墨重新输入。")
            } else {
                None
            };
            Ok(json!(hint))
        }

        "emoji_category_items" => {
            let category = args["category"].as_str().unwrap_or("");
            let items = emoji::emoji_catalog(category);
            Ok(json!(items))
        }
        "emoji_search" => {
            let query = args["query"].as_str().unwrap_or("");
            let items = emoji::emoji_search(query);
            Ok(json!(items))
        }
        "emoji_push_recent" => {
            let recents: Vec<String> = serde_json::from_value(
                args.get("list").or_else(|| args.get("recents")).cloned().unwrap_or_default(),
            )
            .unwrap_or_default();
            let item = args
                .get("char")
                .or_else(|| args.get("item"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let cap = args["cap"].as_u64().unwrap_or(14) as usize;
            let updated = emoji::recents_push(&recents, item, cap);
            Ok(json!(updated))
        }

        "hotkey_validate" => {
            let key_code = args["key_code"].as_u64().unwrap_or(0) as u32;
            let modifiers = args["modifiers"].as_u64().unwrap_or(0) as u32;
            let valid = hotkey::validate_hotkey(key_code, modifiers);
            Ok(json!(valid.is_some()))
        }
        "hotkey_encode" => {
            let key_code = args
                .get("key_code")
                .or_else(|| args.get("event_key_code"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32;
            let modifiers = args
                .get("modifiers")
                .or_else(|| args.get("event_flags"))
                .or_else(|| args.get("flags"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32;
            if let Some(hk) = hotkey::validate_hotkey(key_code, modifiers) {
                Ok(json!(hotkey::encode_hotkey(&hk)))
            } else {
                Err("invalid_hotkey".into())
            }
        }
        "hotkey_decode" => {
            let raw = args["raw"].as_str().unwrap_or("");
            let legacy_val = args.get("legacy_presets").or_else(|| args.get("legacy"));
            let legacy: HashMap<String, (u32, u32)> = legacy_val
                .and_then(|v| {
                    if let Ok(map) = serde_json::from_value::<HashMap<String, Vec<u32>>>(v.clone()) {
                        Some(map.into_iter().filter_map(|(k, vec)| {
                            if vec.len() >= 2 {
                                Some((k, (vec[0], vec[1])))
                            } else {
                                None
                            }
                        }).collect())
                    } else if let Ok(map) = serde_json::from_value::<HashMap<String, (u32, u32)>>(v.clone()) {
                        Some(map)
                    } else {
                        None
                    }
                })
                .unwrap_or_default();
            let decoded = hotkey::decode_hotkey(raw, &legacy);
            Ok(json!(decoded))
        }
        "hotkey_matches" => {
            let key_code = args["combo_key_code"].as_u64().unwrap_or(0) as u32;
            let modifiers = args["combo_modifiers"].as_u64().unwrap_or(0) as u32;
            let event_key = args
                .get("key_code")
                .or_else(|| args.get("event_key_code"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u16;
            let event_flags = args
                .get("flags")
                .or_else(|| args.get("event_flags"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let matches = hotkey::hotkey_matches((key_code, modifiers), event_key, event_flags);
            Ok(json!(matches))
        }

        "input_source_diag_classify" => {
            let sources: Vec<input_source_diag::TisSourceState> =
                serde_json::from_value(args["sources"].clone()).unwrap_or_default();
            let current = args["current_source_id"].as_str();
            let expected: Vec<String> = serde_json::from_value(args["expected_ids"].clone())
                .unwrap_or_default();
            let primary = args["primary_id"].as_str().unwrap_or("");
            let diag = input_source_diag::classify_tis_diagnosis(&sources, current, &expected, primary);
            Ok(json!(diag))
        }
        "input_source_diag_classify_claims" => {
            let bundle_id = args["bundle_id"].as_str().unwrap_or("");
            let claims: Vec<input_source_diag::LsBundleClaim> =
                serde_json::from_value(args["claims"].clone()).unwrap_or_default();
            let report = input_source_diag::classify_ls_claims(bundle_id, &claims);
            Ok(json!(report))
        }

        "logout_prompt_should_suggest" => {
            let failed = args["failed_version"].as_str();
            let current = args
                .get("current")
                .or_else(|| args.get("current_version"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let should = logout_prompt::should_suggest(failed, current);
            Ok(json!(should))
        }
        "logout_prompt_recheck_decision" => {
            let unmet: Option<Vec<String>> = serde_json::from_value(args["unmet"].clone()).ok();
            let error = args["error"].as_str();
            let dec = logout_prompt::recheck_decision(unmet.as_deref(), error);
            let dec_str = match dec {
                logout_prompt::RecheckDecision::Recovered => "recovered",
                logout_prompt::RecheckDecision::Present => "present",
            };
            Ok(json!(dec_str))
        }
        "logout_prompt_safe_verdict" => {
            let snapshot_id = args["snapshot_id"].as_u64();
            let idle_seconds = args["idle_seconds"].as_f64();
            let is_login = args["is_login_window"].as_bool().unwrap_or(false);
            let blocked_ticks = args["blocked_ticks"].as_u64().unwrap_or(0) as usize;
            let stale_ticks = args["stale_composition_ticks"].as_u64().unwrap_or(120) as usize;
            let idle_threshold = args["idle_threshold"].as_f64().unwrap_or(2.0);

            if is_login {
                return Ok(json!({
                    "kind": "blocked",
                    "block_reason": "login_window"
                }));
            }
            if let Some(id) = snapshot_id {
                if blocked_ticks >= stale_ticks {
                    if let Some(idle) = idle_seconds {
                        if idle < idle_threshold {
                            return Ok(json!({
                                "kind": "blocked",
                                "block_reason": "input_busy",
                                "idle_seconds": idle
                            }));
                        }
                    }
                    return Ok(json!({
                        "kind": "safe",
                        "stale_composition_override": true
                    }));
                } else {
                    return Ok(json!({
                        "kind": "blocked",
                        "block_reason": "composing",
                        "snapshot_id": id,
                        "blocked_ticks": blocked_ticks
                    }));
                }
            }
            if let Some(idle) = idle_seconds {
                if idle < idle_threshold {
                    return Ok(json!({
                        "kind": "blocked",
                        "block_reason": "input_busy",
                        "idle_seconds": idle
                    }));
                }
            }
            Ok(json!({
                "kind": "safe",
                "stale_composition_override": false
            }))
        }
        "logout_prompt_activation_verdict" => {
            let is_active = args["is_active"].as_bool().unwrap_or(false);
            let awaiting_ticks = args["awaiting_ticks"].as_u64().unwrap_or(0) as usize;
            let confirm_ticks = args["activation_confirm_ticks"].as_u64().unwrap_or(60) as usize;
            if is_active {
                Ok(json!({
                    "kind": "present",
                    "forced_without_active_confirm": false
                }))
            } else if awaiting_ticks >= confirm_ticks {
                Ok(json!({
                    "kind": "present",
                    "forced_without_active_confirm": true
                }))
            } else {
                Ok(json!({
                    "kind": "waitNextTick"
                }))
            }
        }
        "logout_prompt_classify" => {
            let error_num = args["error_number"].as_i64().map(|v| v as i32);
            let classification = logout_prompt::classify_logout_error(error_num);
            Ok(json!(classification))
        }

        _ => Err(format!("unknown_pure_rule:{}", rule)),
    }
}
