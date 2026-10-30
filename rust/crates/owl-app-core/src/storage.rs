//! Synchronous native effects. Rust owns sequencing and decisions; the host supplies raw
//! filesystem operations, canonical paths, UUIDs and Foundation collation facts.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub type Result<T> = std::result::Result<T, String>;
pub trait Host {
    fn effect(&mut self, request: Value) -> Result<Value>;
}
pub fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T> {
    serde_json::from_value(value).map_err(|_| "invalid_payload".into())
}
pub fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
pub fn effect<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    host.effect(json!({"operation":operation,"args":args}))
}
pub fn checkpoint<H: Host>(host: &mut H, name: &str, channel: &str) -> Result<()> {
    effect(host, "checkpoint", json!({"name":name,"channel":channel}))?;
    Ok(())
}
pub fn read<H: Host>(host: &mut H, name: &str) -> Result<Option<Vec<u8>>> {
    decode(effect(host, "read", json!({"name":name}))?)
}
pub fn text<H: Host>(host: &mut H, name: &str) -> Result<Option<String>> {
    read(host, name)?
        .map(|b| String::from_utf8(b).map_err(|_| "invalid_utf8".into()))
        .transpose()
}
pub fn write<H: Host>(
    host: &mut H,
    name: &str,
    bytes: &[u8],
    permissions: Option<u32>,
) -> Result<()> {
    effect(
        host,
        "write",
        json!({"name":name,"bytes":bytes,"permissions":permissions}),
    )?;
    Ok(())
}
pub fn remove<H: Host>(host: &mut H, name: &str) -> Result<()> {
    effect(host, "remove", json!({"name":name}))?;
    Ok(())
}
pub fn uuid<H: Host>(host: &mut H) -> Result<String> {
    decode(effect(host, "uuid", json!({}))?)
}
pub fn locked<H: Host, T>(host: &mut H, action: impl FnOnce(&mut H) -> Result<T>) -> Result<T> {
    effect(host, "lock", json!({}))?;
    let result = action(host);
    let unlock = effect(host, "unlock", json!({}));
    match result {
        Err(e) => Err(e),
        Ok(v) => {
            unlock?;
            Ok(v)
        }
    }
}
pub fn persist<H: Host, T: Serialize>(host: &mut H, name: &str, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| "invalid_payload")?;
    write(host, name, &bytes, None)?;
    if read(host, name)?.as_deref() != Some(&bytes) {
        return Err("migration_recovery".into());
    }
    Ok(())
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedWrite {
    pub file_name: String,
    pub contents: String,
    pub marker: String,
}

/// Serialize public reads with in-process transactions without creating lock files or
/// directories. Cross-process flock remains a write effect, matching the existing contract.
pub fn process_locked<H: Host, T>(
    host: &mut H,
    action: impl FnOnce(&mut H) -> Result<T>,
) -> Result<T> {
    effect(host, "process_lock", json!({}))?;
    let result = action(host);
    let unlock = effect(host, "process_unlock", json!({}));
    match result {
        Err(error) => Err(error),
        Ok(value) => {
            unlock?;
            Ok(value)
        }
    }
}
