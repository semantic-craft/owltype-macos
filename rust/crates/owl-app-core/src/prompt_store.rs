//! Legacy prompt compatibility, normalization and projection. It remains a separate on-disk
//! format until explicit migration; all persistence decisions use the Rust writer.
use crate::{config_writer, keyboard_export, storage::*, template_library::code_valid};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
#[derive(Clone, Serialize, Deserialize)]
pub struct Prompt {
    pub code: String,
    pub title: String,
    pub body: String,
    pub category: String,
}
pub fn entry(mut p: Prompt) -> Result<Prompt> {
    p.code = p.code.trim().to_lowercase();
    p.title = p.title.trim().into();
    p.body = p.body.trim().into();
    p.category = p.category.trim().into();
    if p.title.is_empty() || p.title.contains(['\n', '\t']) {
        return Err("prompt_title".into());
    }
    if p.body.is_empty() {
        return Err("prompt_body".into());
    }
    if !code_valid(&p.code) {
        return Err("prompt_code".into());
    }
    Ok(p)
}
pub fn normalized(entries: Vec<Prompt>) -> Result<Vec<Prompt>> {
    let mut out = BTreeMap::new();
    for e in entries {
        let e = entry(e)?;
        out.insert(e.code.clone(), e);
    }
    Ok(out.into_values().collect())
}
pub const MARKER: &str = "OWL MANAGED PROMPTS RIME_ICE PATCH v1";
pub fn patch() -> Vec<String> {
    [
        "  # 提示词：Owltype-owned table_translator，候选只显示 📝 标题；正文由控制器拦截插入",
        "  \"engine/translators/+\":",
        "    - table_translator@owl_prompts",
        "  owl_prompts:",
        "    dictionary: \"\"",
        "    user_dict: owl_prompts",
        "    db_class: stabledb",
        "    enable_completion: false",
        "    enable_sentence: false",
        "    initial_quality: 100",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}
pub fn projection(entries: &[Prompt]) -> String {
    let mut s="# Rime table\n# coding: utf-8\n#@/db_name owl_prompts\n#@/db_type tabledb\n# Owltype prompt titles. Body lives in owl_prompts.json; selecting a 📝 row inserts the body.\n\n".to_owned();
    for e in entries {
        s.push_str(&format!(
            "📝{}\t{}\t100000\n📝{}\tv{}\t100000\n",
            e.title, e.code, e.title, e.code
        ))
    }
    s
}
pub fn load<H: Host>(host: &mut H) -> Vec<Prompt> {
    let entries = read(host, "owl_prompts.json")
        .ok()
        .flatten()
        .and_then(|b| serde_json::from_slice::<Vec<Prompt>>(&b).ok())
        .unwrap_or_default();
    let valid = entries.into_iter().filter_map(|p| entry(p).ok()).collect();
    normalized(valid).unwrap_or_default()
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "prompt_entry" => {
            let e = entry(decode(args["entry"].clone())?)?;
            let codes: Vec<String> = decode(args["codes"].clone()).unwrap_or_default();
            if codes.contains(&e.code) {
                return Err(format!("prompt_duplicate:{}", e.code));
            }
            Ok(json!(e))
        }
        "prompt_collision" => {
            let code = args["code"].as_str().unwrap_or("").trim().to_lowercase();
            let codes: Vec<String> = decode(args["codes"].clone())?;
            if codes.contains(&code) {
                return Err(format!("prompt_duplicate:{code}"));
            }
            Ok(json!(true))
        }
        "prompt_normalized" => Ok(json!(normalized(decode(args["entries"].clone())?)?)),
        "prompt_load" => Ok(json!(load(host))),
        "prompt_patch" => Ok(json!({"marker":MARKER,"yamlLinesIndentedUnderPatch":patch()})),
        "prompt_projection" => Ok(json!(projection(&decode::<Vec<Prompt>>(
            args["entries"].clone()
        )?))),
        "prompt_save" => {
            let entries = normalized(decode(args["entries"].clone())?)?;
            let timestamp = args["timestamp"].as_str().ok_or("invalid_payload")?;
            let contents =
                serde_json::to_string_pretty(&entries).map_err(|_| "invalid_payload")? + "\n";
            config_writer::apply_text(
                host,
                "owl_prompts.json",
                &contents,
                "OWL MANAGED PROMPTS FILE v1",
                timestamp,
            )?;
            config_writer::apply_text(
                host,
                "owl_prompts.txt",
                &projection(&entries),
                "OWL MANAGED PROMPTS DICT FILE v1",
                timestamp,
            )?;
            let original = text(host, "rime_ice.custom.yaml")
                .ok()
                .flatten()
                .unwrap_or("patch:\n".into());
            let updated = keyboard_export::render_managed(&original, MARKER, &patch())
                .ok_or("invalid_patch")?;
            config_writer::apply_text(host, "rime_ice.custom.yaml", &updated, MARKER, timestamp)?;
            Ok(json!(true))
        }
        "prompt_strip" => {
            let text = args["text"].as_str().unwrap_or("");
            Ok(json!(text
                .strip_prefix('📝')
                .map(|s| s.trim_start_matches([' ', '\u{3000}']))
                .unwrap_or(text)))
        }
        "prompt_match" => {
            let entries: Vec<Prompt> = decode(args["entries"].clone())?;
            let code = args["code"].as_str().unwrap_or("").trim().to_lowercase();
            let title = args["title"].as_str().unwrap_or("");
            let same: Vec<_> = entries
                .iter()
                .filter(|e| {
                    crate::template_library::nfc(&e.title) == crate::template_library::nfc(title)
                })
                .collect();
            let found = same.iter().find(|e| e.code == code).copied().or_else(|| {
                code.strip_prefix('v')
                    .and_then(|c| same.iter().find(|e| e.code == c).copied())
            });
            Ok(json!({"entry":found}))
        }
        "prompt_presets" => {
            let existing: Vec<Prompt> = decode(args["entries"].clone())?;
            let presets: Vec<Prompt> = decode(args["presets"].clone())?;
            let codes: Vec<String> = decode(args["codes"].clone())?;
            let taken: BTreeSet<_> = existing
                .iter()
                .map(|e| e.code.clone())
                .chain(codes)
                .collect();
            let mut merged = existing;
            let mut added = vec![];
            let mut skipped = vec![];
            for e in presets {
                if taken.contains(&e.code) {
                    skipped.push(e.code)
                } else {
                    added.push(e.code.clone());
                    merged.push(e)
                }
            }
            Ok(json!({"merged":merged,"added":added,"skipped":skipped}))
        }
        _ => Err("unknown_operation".into()),
    }
}
