//! Atomic single-file template library persistence (`owl_templates.json`).
use crate::{storage::*, template_library::*};
use serde_json::{json, Value};

pub fn decode_valid_library(bytes: &[u8]) -> Result<Library> {
    let library: Library = serde_json::from_slice(bytes)
        .map_err(|_| "已保存的快捷模板库无法读取，为避免覆盖，已停止写入。")?;
    validate(&library)?;
    Ok(library)
}

pub fn mode<H: Host>(host: &mut H) -> Value {
    match read(host, FILE) {
        Ok(None) => json!({"kind": "empty"}),
        Ok(Some(bytes)) => match decode_valid_library(&bytes) {
            Ok(_) => json!({"kind": "unified"}),
            Err(message) => json!({"kind": "unavailable", "message": message}),
        },
        Err(message) => json!({"kind": "unavailable", "message": message}),
    }
}

pub(crate) fn load_unlocked<H: Host>(host: &mut H) -> Result<Library> {
    match read(host, FILE)? {
        None => Ok(Library::default()),
        Some(bytes) => decode_valid_library(&bytes),
    }
}

pub fn load<H: Host>(host: &mut H) -> Result<Library> {
    locked(host, load_unlocked)
}

pub fn current<H: Host>(host: &mut H) -> Result<Library> {
    load(host)
}

pub(crate) fn save_unlocked<H: Host>(
    host: &mut H,
    library: &Library,
    expected: Option<&Library>,
) -> Result<()> {
    validate(library)?;
    let existing = load_unlocked(host)?;
    if let Some(expected) = expected {
        if !same(&existing, expected) {
            return Err("changed_on_disk".into());
        }
    }
    let mut bytes = encoded(library)?;
    bytes.push(b'\n');
    checkpoint(host, FILE, "transaction")?;
    write(host, FILE, &bytes, None)?;
    effect(host, "library_committed", json!({}))?;
    Ok(())
}

pub fn save<H: Host>(host: &mut H, library: &Library, expected: Option<&Library>) -> Result<()> {
    locked(host, |host| save_unlocked(host, library, expected))
}

pub fn delete<H: Host>(host: &mut H, id: &str, expected: &Library) -> Result<Library> {
    locked(host, |host| {
        let existing = load_unlocked(host)?;
        if !same(&existing, expected) {
            return Err("changed_on_disk".into());
        }
        let mut next = existing;
        let before = next.entries.len();
        next.entries.retain(|e| !e.id.eq_ignore_ascii_case(id));
        if next.entries.len() == before {
            return Err("missing_entry".into());
        }
        save_unlocked(host, &next, None)?;
        Ok(next)
    })
}
