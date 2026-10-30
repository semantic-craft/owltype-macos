pub mod app_input_memory;
pub mod auto_pair;
pub mod commit_transform;
pub mod emoji;
pub mod engine_runtime_rule;
pub mod forced_finalize;
pub mod hotkey;
pub mod input_source_diag;
pub mod logout_prompt;
pub mod marked_text_resend;
pub mod onboarding_practice;
pub mod session_restart;
pub mod user_action;

use serde_json::{json, Value};
use std::collections::HashMap;

pub fn dispatch(rule: &str, args: Value) -> Result<Value, String> {
    match rule {
        "auto_pair_decide" => {
            let enabled = args["enabled"].as_bool().unwrap_or(false);
            let commit_text = args["commit_text"].as_str().unwrap_or("");
            let right_neighbor = args["right_neighbor"]
                .as_str()
                .and_then(|s| s.chars().next());
            let caret_move_allowed = args["caret_move_allowed"].as_bool().unwrap_or(false);
            let action = auto_pair::decide(enabled, commit_text, right_neighbor, caret_move_allowed);
            Ok(json!(action))
        }
        "auto_pair_single_closer" => {
            let text = args["text"].as_str().unwrap_or("");
            let closer = auto_pair::single_closer(text).map(|c| c.to_string());
            Ok(json!({ "closer": closer }))
        }
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
            Ok(json!({ "transformed": transformed }))
        }
        "forced_finalize_plan" => {
            let input = args["input"].as_str();
            let preview = args["preview"].as_str();
            let plan = forced_finalize::plan_forced_finalize(input, preview);
            Ok(json!(plan))
        }
        "marked_text_resend_should_send" => {
            let previous = args["previous"].as_str().unwrap_or("");
            let next = args["next"].as_str().unwrap_or("");
            let should_send = marked_text_resend::should_resend_marked_text(previous, next);
            Ok(json!({ "should_send": should_send }))
        }
        "app_input_memory_initial_mode" => {
            let app = args["app"].as_str().unwrap_or("");
            let fallback = args["fallback"].as_bool().unwrap_or(false);
            let enabled = args["enabled"].as_bool().unwrap_or(true);
            let modes: HashMap<String, bool> = serde_json::from_value(args["modes"].clone())
                .unwrap_or_default();
            let mode = app_input_memory::initial_mode(app, fallback, enabled, &modes);
            Ok(json!({ "mode": mode }))
        }
        "app_input_memory_should_remember" => {
            let app = args["app"].as_str().unwrap_or("");
            let ascii = args["ascii"].as_bool().unwrap_or(false);
            let enabled = args["enabled"].as_bool().unwrap_or(true);
            let current_mode = args["current_mode"].as_bool();
            let should = app_input_memory::should_remember(app, ascii, enabled, current_mode);
            Ok(json!({ "should_remember": should }))
        }
        "practice_proof_eval" => {
            let proof: onboarding_practice::PracticeProof =
                serde_json::from_value(args["proof"].clone()).unwrap_or_default();
            let text = args["text"].as_str().unwrap_or("");
            let has_marked = args["has_marked_text"].as_bool().unwrap_or(false);
            let is_complete = proof.is_complete(text, has_marked);
            let hint = proof.hint().map(str::to_string);
            Ok(json!({
                "is_complete": is_complete,
                "hint": hint,
            }))
        }
        "emoji_items" => {
            let category = args["category"].as_str().unwrap_or("");
            let items = emoji::emoji_catalog(category);
            Ok(json!(items))
        }
        "emoji_search" => {
            let query = args["query"].as_str().unwrap_or("");
            let items = emoji::emoji_search(query);
            Ok(json!(items))
        }
        "emoji_recents_push" => {
            let recents: Vec<String> = serde_json::from_value(args["recents"].clone())
                .unwrap_or_default();
            let item = args["item"].as_str().unwrap_or("");
            let cap = args["cap"].as_u64().unwrap_or(14) as usize;
            let updated = emoji::recents_push(&recents, item, cap);
            Ok(json!(updated))
        }
        "emoji_recents_seed" => {
            Ok(json!(emoji::recents_seed()))
        }
        "hotkey_validate" => {
            let key_code = args["key_code"].as_u64().unwrap_or(0) as u32;
            let modifiers = args["modifiers"].as_u64().unwrap_or(0) as u32;
            let valid = hotkey::validate_hotkey(key_code, modifiers);
            Ok(json!(valid))
        }
        "hotkey_encode" => {
            let key_code = args["key_code"].as_u64().unwrap_or(0) as u32;
            let modifiers = args["modifiers"].as_u64().unwrap_or(0) as u32;
            if let Some(hk) = hotkey::validate_hotkey(key_code, modifiers) {
                Ok(json!({ "encoded": hotkey::encode_hotkey(&hk), "label": hotkey::hotkey_label(&hk) }))
            } else {
                Err("invalid_hotkey".into())
            }
        }
        "hotkey_decode" => {
            let raw = args["raw"].as_str().unwrap_or("");
            let legacy: HashMap<String, (u32, u32)> = serde_json::from_value(args["legacy"].clone())
                .unwrap_or_default();
            let decoded = hotkey::decode_hotkey(raw, &legacy);
            Ok(json!(decoded))
        }
        "hotkey_matches" => {
            let key_code = args["combo_key_code"].as_u64().unwrap_or(0) as u32;
            let modifiers = args["combo_modifiers"].as_u64().unwrap_or(0) as u32;
            let event_key = args["event_key_code"].as_u64().unwrap_or(0) as u16;
            let event_flags = args["event_flags"].as_u64().unwrap_or(0);
            let matches = hotkey::hotkey_matches((key_code, modifiers), event_key, event_flags);
            Ok(json!({ "matches": matches }))
        }
        "tis_diagnose" => {
            let sources: Vec<input_source_diag::TisSourceState> =
                serde_json::from_value(args["sources"].clone()).unwrap_or_default();
            let current = args["current_source_id"].as_str();
            let expected: Vec<String> = serde_json::from_value(args["expected_ids"].clone())
                .unwrap_or_default();
            let primary = args["primary_id"].as_str().unwrap_or("");
            let diag = input_source_diag::classify_tis_diagnosis(&sources, current, &expected, primary);
            Ok(json!(diag))
        }
        "tis_classify_claims" => {
            let bundle_id = args["bundle_id"].as_str().unwrap_or("");
            let claims: Vec<input_source_diag::LsBundleClaim> =
                serde_json::from_value(args["claims"].clone()).unwrap_or_default();
            let report = input_source_diag::classify_ls_claims(bundle_id, &claims);
            Ok(json!(report))
        }
        "session_restart_maps_lsof" => {
            let lsof = args["lsof"].as_str().unwrap_or("");
            let path = args["path"].as_str().unwrap_or("");
            let inode = args["inode"].as_u64().unwrap_or(0);
            let matches = session_restart::maps_lsof(lsof, path, inode);
            Ok(json!({ "maps": matches }))
        }
        "session_restart_unmet_conditions" => {
            let observation: session_restart::RestartObservation =
                serde_json::from_value(args["observation"].clone()).map_err(|e| e.to_string())?;
            let request: session_restart::RestartRequest =
                serde_json::from_value(args["request"].clone()).map_err(|e| e.to_string())?;
            let unmet = session_restart::unmet_conditions(&observation, &request);
            Ok(json!(unmet))
        }
        "logout_should_suggest" => {
            let failed = args["failed_version"].as_str();
            let current = args["current_version"].as_str().unwrap_or("");
            let should = logout_prompt::should_suggest(failed, current);
            Ok(json!({ "should_suggest": should }))
        }
        "logout_recheck_decision" => {
            let unmet: Option<Vec<String>> = serde_json::from_value(args["unmet"].clone()).ok();
            let error = args["error"].as_str();
            let dec = logout_prompt::recheck_decision(unmet.as_deref(), error);
            Ok(json!(dec))
        }
        "logout_safe_verdict" => {
            let snapshot_id = args["snapshot_id"].as_u64();
            let idle_seconds = args["idle_seconds"].as_f64();
            let is_login = args["is_login_window"].as_bool().unwrap_or(false);
            let blocked_ticks = args["blocked_ticks"].as_u64().unwrap_or(0) as usize;
            let verdict = logout_prompt::evaluate_safe_verdict(snapshot_id, idle_seconds, is_login, blocked_ticks);
            Ok(json!(verdict))
        }
        "logout_classify_error" => {
            let error_num = args["error_number"].as_i64().map(|v| v as i32);
            let classification = logout_prompt::classify_logout_error(error_num);
            Ok(json!({ "classification": classification }))
        }
        "engine_option_valid" => {
            let name = args["name"].as_str().unwrap_or("");
            let valid = engine_runtime_rule::is_valid_engine_option(name);
            Ok(json!({ "valid": valid }))
        }
        "engine_refresh_decision" => {
            let pending = args["pending"].as_bool().unwrap_or(false);
            let composing = args["composing"].as_bool().unwrap_or(false);
            let decision = engine_runtime_rule::refresh_decision(pending, composing);
            Ok(json!({ "decision": decision }))
        }
        _ => Err(format!("unknown_pure_rule:{}", rule)),
    }
}
