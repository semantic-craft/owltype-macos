//! Legacy quick-send store and settings edit plans.
use crate::foundation_text::trim;
use crate::{
    config_writer, keyboard_export,
    storage::*,
    template_library::{code_valid, nfc},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
#[derive(Clone, Serialize, Deserialize)]
pub struct Entry {
    pub text: String,
    pub code: String,
}
pub fn entry(mut e: Entry) -> Result<Entry> {
    e.text = trim(&e.text).into();
    e.code = trim(&e.code).to_lowercase();
    if e.text.is_empty() || e.text.contains(['\n', '\t']) {
        return Err("quick_text".into());
    }
    if !code_valid(&e.code) {
        return Err("quick_code".into());
    }
    Ok(e)
}
fn normalized(entries: Vec<Entry>) -> Result<Vec<Entry>> {
    let mut out = BTreeMap::new();
    for e in entries {
        let e = entry(e)?;
        out.insert(e.code.clone(), e);
    }
    Ok(out.into_values().collect())
}
fn collapse(entries: Vec<Entry>) -> Vec<Entry> {
    let entries = normalized(entries.clone()).unwrap_or(entries);
    let lookup: BTreeMap<_, _> = entries
        .iter()
        .map(|e| (e.code.clone(), nfc(&e.text)))
        .collect();
    entries
        .into_iter()
        .filter(|e| {
            !e.code
                .strip_prefix('v')
                .is_some_and(|c| lookup.get(c) == Some(&nfc(&e.text)))
        })
        .collect()
}
pub fn load<H: Host>(host: &mut H) -> Vec<Entry> {
    if let Some(entries) = read(host, "owl_quick_send.json")
        .ok()
        .flatten()
        .and_then(|b| serde_json::from_slice::<Vec<Entry>>(&b).ok())
    {
        return normalized(entries.into_iter().filter_map(|e| entry(e).ok()).collect())
            .unwrap_or_default();
    }
    let text = text(host, "owl_quick_send.txt")
        .ok()
        .flatten()
        .unwrap_or_default();
    let entries = text
        .lines()
        .filter(|l| !crate::foundation_text::trim_spaces(l).starts_with('#'))
        .filter_map(|line| {
            let parts: Vec<_> = line.split('\t').collect();
            if parts.len() < 2 {
                return None;
            }
            entry(Entry {
                text: parts[0].into(),
                code: parts[1].into(),
            })
            .ok()
        })
        .collect();
    collapse(entries)
}
fn save<H: Host>(host: &mut H, entries: Vec<Entry>, timestamp: &str) -> Result<()> {
    let entries = normalized(entries)?;
    let contents = serde_json::to_string_pretty(&entries).map_err(|_| "invalid_payload")? + "\n";
    config_writer::apply_text(
        host,
        "owl_quick_send.json",
        &contents,
        "OWL MANAGED QUICK_SEND JSON FILE v1",
        timestamp,
    )?;
    let mut dict="# Rime table\n# coding: utf-8\n#@/db_name\towl_quick_send\n#@/db_type\ttabledb\n# Owltype quick-send phrases. Managed by 猫头鹰输入法 settings.\n# 触发：打全短语码，短语置顶。\n\n".to_owned();
    for e in &entries {
        dict.push_str(&format!("{}\t{}\t100000\n", e.text, e.code))
    }
    config_writer::apply_text(
        host,
        "owl_quick_send.txt",
        &dict,
        "OWL MANAGED QUICK_SEND FILE v1",
        timestamp,
    )?;
    let original = text(host, "rime_ice.custom.yaml")
        .ok()
        .flatten()
        .unwrap_or("patch:\n".into());
    let lines: Vec<String> = serde_json::from_str(include_str!("quick_send_patch.json")).unwrap();
    let marker = "OWL MANAGED QUICK_SEND RIME_ICE PATCH v1";
    let updated =
        keyboard_export::render_managed(&original, marker, &lines).ok_or("invalid_patch")?;
    config_writer::write_managed(
        host,
        "rime_ice.custom.yaml",
        &original,
        &updated,
        marker,
        timestamp,
    )
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "quick_entry" => Ok(json!(entry(decode(args["entry"].clone())?)?)),
        "quick_load" => Ok(json!(load(host))),
        "quick_collapse" => Ok(json!(collapse(decode(args["entries"].clone())?))),
        "quick_save" => {
            save(
                host,
                decode(args["entries"].clone())?,
                args["timestamp"].as_str().ok_or("invalid_payload")?,
            )?;
            Ok(json!(true))
        }
        "quick_migrate" => {
            if read(host, "owl_quick_send.json")?.is_some()
                || read(host, "owl_quick_send.txt")?.is_some()
            {
                let entries = load(host);
                save(
                    host,
                    entries,
                    &format!(
                        "{}-quicksend-migration",
                        args["timestamp"].as_str().ok_or("invalid_payload")?
                    ),
                )?
            }
            Ok(json!(true))
        }
        "quick_edit" => {
            let mut entries: Vec<Entry> = decode(args["entries"].clone())?;
            let editing = args["editing"].as_str();
            let e: Entry = decode(args["entry"].clone())?;
            if args["delete"] == true {
                entries.retain(|v| v.code != e.code)
            } else {
                let e = entry(e)?;
                entries.retain(|v| v.code != e.code && Some(v.code.as_str()) != editing);
                entries.push(e)
            }
            Ok(json!(entries))
        }
        "quick_edit_result" => {
            let applied = args["applied"] == true;
            let delete = args["delete"] == true;
            let clear = !delete || args["editing"] == args["code"];
            let status = match (delete, applied) {
                (true, true) => "已删除并应用配置改动。",
                (true, false) => "已删除；应用配置失败，请查看诊断日志。",
                (false, true) => "已保存并应用配置改动。",
                _ => "已保存；应用配置失败，请查看诊断日志。",
            };
            Ok(
                json!({"clear":clear,"editing":if clear{Value::Null}else{args["editing"].clone()},"status":status}),
            )
        }
        _ => Err("unknown_operation".into()),
    }
}
