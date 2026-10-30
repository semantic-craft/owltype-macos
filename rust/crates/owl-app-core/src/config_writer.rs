//! Managed-file authorization, backup and rollback policy. Native I/O executes one
//! primitive per request; it cannot select targets or advance the transaction.
use crate::storage::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
pub const MANIFEST: &str = "owltype/rollback-manifest.json";
pub const MANAGED: &[&str] = &[
    "default.custom.yaml",
    "owltype.custom.yaml",
    "rime_ice.custom.yaml",
    "wubi86_jidian.custom.yaml",
    "wubi86_jidian_pinyin.custom.yaml",
    "wubi86_jidian_trad.custom.yaml",
    "wubi86_jidian_trad_pinyin.custom.yaml",
    "owl_quick_send.json",
    "owl_quick_send.txt",
    "owl_templates.json",
    "owl_templates.txt",
    "owl_templates_state.json",
    "owl_prompts.json",
    "owl_prompts.txt",
];
pub fn never_touch(name: &str) -> bool {
    let last = name.rsplit('/').next().unwrap_or(name);
    ["user.yaml", "installation.yaml", "custom_phrase.txt"].contains(&last)
        || last.contains(".userdb")
}
pub fn authorize(name: &str) -> Result<()> {
    if never_touch(name) {
        Err(format!("never_touch:{name}"))
    } else if !MANAGED.contains(&name) {
        Err(format!("unmanaged:{name}"))
    } else {
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackEntry {
    pub path: String,
    pub before_sha256: String,
    pub after_sha256: String,
    pub managed_block: String,
    pub backup_dir: String,
    pub ts: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub version: u32,
    pub files: Vec<RollbackEntry>,
}
pub fn apply_text<H: Host>(
    host: &mut H,
    name: &str,
    updated: &str,
    marker: &str,
    timestamp: &str,
) -> Result<()> {
    let original = text(host, name).ok().flatten().unwrap_or_default();
    write_managed(host, name, &original, updated, marker, timestamp)
}
pub fn write_managed<H: Host>(
    host: &mut H,
    name: &str,
    original: &str,
    updated: &str,
    marker: &str,
    timestamp: &str,
) -> Result<()> {
    authorize(name)?;
    if original.as_bytes() == updated.as_bytes() {
        return Ok(());
    }
    let backup = format!(".owl-backup/{timestamp}");
    write(host, &format!("{backup}/{name}"), original.as_bytes(), None)?;
    checkpoint(host, &format!("backup:{name}"), "writer")?;
    // Replacement and permissions are separate native effects so a post-rename failure is
    // observable. The enclosing library journal, not this writer, decides whether to restore.
    effect(
        host,
        "replace",
        json!({"name":name,"bytes":updated.as_bytes(),"suffix":"owl.tmp"}),
    )?;
    checkpoint(host, &format!("replaced:{name}"), "writer")?;
    let path = decode(effect(host, "path", json!({"name":name}))?)?;
    let backup_dir = decode(effect(host, "path", json!({"name":backup}))?)?;
    let entry = RollbackEntry {
        path,
        before_sha256: hash(original.as_bytes()),
        after_sha256: hash(updated.as_bytes()),
        managed_block: marker.into(),
        backup_dir,
        ts: timestamp.into(),
    };
    let mut manifest = read(host, MANIFEST)
        .ok()
        .flatten()
        .and_then(|v| serde_json::from_slice::<Manifest>(&v).ok())
        .unwrap_or(Manifest {
            version: 1,
            files: vec![],
        });
    manifest.files.push(entry);
    write(
        host,
        MANIFEST,
        &serde_json::to_vec_pretty(&manifest).map_err(|_| "invalid_payload")?,
        None,
    )?;
    checkpoint(host, &format!("manifest:{name}"), "writer")
}
pub fn rollback<H: Host>(host: &mut H) -> Result<()> {
    let Some(bytes) = read(host, MANIFEST).ok().flatten() else {
        return Ok(());
    };
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|_| "invalid_manifest")?;
    let Some(last) = manifest.files.last() else {
        return Ok(());
    };
    let mut batch: Vec<_> = manifest
        .files
        .iter()
        .rev()
        .take_while(|v| v.ts == last.ts && v.backup_dir == last.backup_dir)
        .collect();
    batch.reverse();
    for entry in batch {
        let relative: String = decode(effect(host, "relative", json!({"path":entry.path}))?)?;
        let name = format!("{}/{relative}", entry.backup_dir);
        if let Ok(Some(bytes)) = read(host, &name) {
            let restored = String::from_utf8(bytes).unwrap_or_default();
            let _ = effect(
                host,
                "replace",
                json!({"name":entry.path,"bytes":restored.as_bytes(),"suffix":"owl.rollback.tmp"}),
            );
        }
    }
    Ok(())
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "writer_remove_bare" => Ok(json!(remove_bare(
            args["text"].as_str().ok_or("invalid_payload")?,
            args["marker"].as_str().ok_or("invalid_payload")?
        ))),
        "writer_top_level" => Ok(
            json!({"value":top_level(args["key"].as_str().ok_or("invalid_payload")?,args["text"].as_str().ok_or("invalid_payload")?)}),
        ),
        "writer_apply" | "writer_preview" => {
            let name = args["fileName"].as_str().ok_or("invalid_payload")?;
            let marker = args["marker"].as_str().ok_or("invalid_payload")?;
            if operation == "writer_apply" {
                authorize(name)?
            }
            let original = text(host, name).ok().flatten().unwrap_or("patch:\n".into());
            let source = source(&original, name, marker);
            let lines: Vec<String> = decode(args["lines"].clone())?;
            let rendered = crate::keyboard_export::render_managed(&source, marker, &lines);
            if operation == "writer_preview" {
                return Ok(json!({"before":original,"after":rendered.unwrap_or(original.clone())}));
            }
            let updated = rendered.ok_or("invalid_patch")?;
            write_managed(
                host,
                name,
                &original,
                &updated,
                marker,
                args["timestamp"].as_str().ok_or("invalid_payload")?,
            )?;
            Ok(json!(true))
        }
        "writer_apply_text" => {
            apply_text(
                host,
                args["fileName"].as_str().ok_or("invalid_payload")?,
                args["contents"].as_str().ok_or("invalid_payload")?,
                args["marker"].as_str().ok_or("invalid_payload")?,
                args["timestamp"].as_str().ok_or("invalid_payload")?,
            )?;
            Ok(json!(true))
        }
        "writer_rollback" => {
            rollback(host)?;
            Ok(json!(true))
        }
        "writer_never_touch" => Ok(json!(never_touch(
            args["name"].as_str().ok_or("invalid_payload")?
        ))),
        _ => Err("unknown_operation".into()),
    }
}
fn yaml_item(line: &str) -> Option<(usize, String, &str)> {
    let indent = line
        .bytes()
        .take_while(|b| *b == b' ' || *b == b'\t')
        .count();
    let trimmed = &line[indent..];
    if trimmed.starts_with('#') || trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix('"') {
        let end = rest.find('"')?;
        let key = &rest[..end];
        let tail = rest[end + 1..].trim_start_matches([' ', '\t']);
        Some((indent, key.into(), tail.strip_prefix(':')?))
    } else {
        let (key, value) = trimmed.split_once(':')?;
        let key = crate::foundation_text::trim_spaces(key);
        if key.is_empty() {
            None
        } else {
            Some((indent, key.into(), value))
        }
    }
}
pub fn remove_bare(text: &str, marker: &str) -> String {
    let begin = format!("# >>> {marker}");
    let end = format!("# <<< {marker}");
    let mut inside = false;
    let mut dropping = None;
    let mut out = vec![];
    for line in text.split('\n') {
        if line.contains(&begin) {
            dropping = None;
            inside = true;
            out.push(line);
            continue;
        }
        if line.contains(&end) {
            dropping = None;
            inside = false;
            out.push(line);
            continue;
        }
        let indent = line
            .bytes()
            .take_while(|b| *b == b' ' || *b == b'\t')
            .count();
        if let Some(block_indent) = dropping {
            if crate::foundation_text::trim_spaces(line).is_empty() || indent > block_indent {
                continue;
            }
            dropping = None
        }
        if !inside {
            if let Some((indent, key, value)) = yaml_item(line) {
                let owned = (key.starts_with("app_options/") && key.ends_with("/ascii_mode"))
                    || [
                        "schema_list",
                        "menu/page_size",
                        "menu/alternative_select_keys",
                        "ascii_composer/switch_key/Shift_L",
                        "ascii_composer/switch_key/Shift_R",
                        "ascii_composer/switch_key/Caps_Lock",
                        "ascii_composer/good_old_caps_lock",
                        "key_binder/select_first_character",
                        "key_binder/select_last_character",
                        "punctuator/half_shape/+",
                        "punctuator/full_shape/+",
                        "key_binder/bindings/+",
                        "switcher/save_options/+",
                    ]
                    .contains(&key.as_str());
                if owned {
                    if crate::foundation_text::trim_spaces(value).is_empty() {
                        dropping = Some(indent)
                    }
                    continue;
                }
            }
        }
        out.push(line)
    }
    out.join("\n")
}
pub fn source(original: &str, name: &str, marker: &str) -> String {
    if name == "default.custom.yaml" && marker == "OWL MANAGED DEFAULT PATCH v1" {
        remove_bare(original, marker)
    } else {
        original.into()
    }
}
fn top_level(key: &str, text: &str) -> Option<String> {
    let prefix = format!("{key}:");
    let raw = text
        .split('\n')
        .find_map(|l| l.strip_prefix(&prefix))?
        .trim_matches(crate::foundation_text::is_whitespace);
    if raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2 {
        Some(
            raw[1..raw.len() - 1]
                .replace("\\\"", "\"")
                .replace("\\\\", "\\"),
        )
    } else if raw.starts_with('\'') && raw.ends_with('\'') && raw.len() >= 2 {
        Some(raw[1..raw.len() - 1].replace("''", "'"))
    } else {
        Some(raw.into())
    }
}
