//! Synchronous native effects and Rust-native filesystem storage guarded by `msime-path-trust`.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

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

static COUNTER: AtomicU64 = AtomicU64::new(1);

pub fn next_uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    if let Ok(mut f) = fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut bytes);
    } else {
        let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
        bytes[..8].copy_from_slice(&seq.to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

fn prepare_private_directory(dir: &Path) -> Result<()> {
    msime_path_trust::reject_symlinked_components(dir).map_err(|e| e.to_string())?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    set_mode(dir, 0o700).map_err(|e| e.to_string())
}

fn copy_recursive(src: &Path, dst: &Path) -> Result<()> {
    msime_path_trust::reject_symlinked_components(src).map_err(|e| e.to_string())?;
    msime_path_trust::reject_symlinked_components(dst).map_err(|e| e.to_string())?;
    let meta = fs::symlink_metadata(src).map_err(|e| e.to_string())?;
    if meta.is_dir() {
        prepare_private_directory(dst)?;
        for entry in fs::read_dir(src).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let child_src = entry.path();
            let child_dst = dst.join(entry.file_name());
            copy_recursive(&child_src, &child_dst)?;
        }
        Ok(())
    } else {
        if let Some(parent) = dst.parent() {
            prepare_private_directory(parent)?;
        }
        fs::copy(src, dst).map_err(|e| e.to_string())?;
        set_mode(dst, 0o600).map_err(|e| e.to_string())
    }
}

pub struct FilesystemHost {
    pub data_dir: PathBuf,
    pub fail_checkpoint: Option<String>,
    pub committed_library: bool,
}

impl FilesystemHost {
    pub fn new(data_dir: PathBuf, fail_checkpoint: Option<String>) -> Self {
        Self {
            data_dir,
            fail_checkpoint,
            committed_library: false,
        }
    }

    fn resolve(&self, name: &str) -> PathBuf {
        if name.starts_with('/') {
            PathBuf::from(name)
        } else {
            self.data_dir.join(name)
        }
    }

    fn write_atomic(&self, target: &Path, bytes: &[u8], mode: u32) -> Result<()> {
        msime_path_trust::reject_symlinked_components(target).map_err(|_| "write_failed".to_string())?;
        let parent = target.parent().unwrap_or(&self.data_dir);
        prepare_private_directory(parent).map_err(|_| "write_failed".to_string())?;
        let file_name = target
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "file".into());
        let temp = parent.join(format!(
            ".{}.{}.owl.tmp",
            file_name,
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::write(&temp, bytes).map_err(|_| "write_failed".to_string())?;
        if set_mode(&temp, mode).is_err() {
            let _ = fs::remove_file(&temp);
            return Err("write_failed".into());
        }
        if fs::rename(&temp, target).is_err() {
            let _ = fs::remove_file(&temp);
            return Err("write_failed".into());
        }
        set_mode(target, mode).map_err(|_| "write_failed".to_string())
    }
}

impl Host for FilesystemHost {
    fn effect(&mut self, request: Value) -> Result<Value> {
        let operation = request["operation"].as_str().unwrap_or("");
        let args = &request["args"];
        match operation {
            "read" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                msime_path_trust::reject_symlinked_components(&target)
                    .map_err(|_| "read_failed".to_string())?;
                match fs::symlink_metadata(&target) {
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Null),
                    Err(_) => Err("read_failed".into()),
                    Ok(meta) => {
                        if !meta.is_file() {
                            return Err("read_failed".into());
                        }
                        let bytes = fs::read(&target).map_err(|_| "read_failed".to_string())?;
                        Ok(json!(bytes))
                    }
                }
            }
            "write" | "replace" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                let bytes: Vec<u8> = decode(args["bytes"].clone())?;
                let mode = args["permissions"].as_u64().unwrap_or(0o600) as u32;
                self.write_atomic(&target, &bytes, mode)?;
                Ok(Value::Bool(true))
            }
            "remove" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                msime_path_trust::reject_symlinked_components(&target)
                    .map_err(|_| "remove_failed".to_string())?;
                if let Ok(meta) = fs::symlink_metadata(&target) {
                    if meta.is_dir() {
                        fs::remove_dir_all(&target).map_err(|_| "remove_failed".to_string())?;
                    } else {
                        fs::remove_file(&target).map_err(|_| "remove_failed".to_string())?;
                    }
                }
                Ok(Value::Bool(true))
            }
            "permissions" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                match fs::symlink_metadata(&target) {
                    Ok(meta) => {
                        #[cfg(unix)]
                        {
                            use std::os::unix::fs::PermissionsExt;
                            Ok(json!(meta.permissions().mode() & 0o777))
                        }
                        #[cfg(not(unix))]
                        {
                            let _ = meta;
                            Ok(json!(0o600))
                        }
                    }
                    Err(_) => Ok(Value::Null),
                }
            }
            "path" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                Ok(json!(target.to_string_lossy()))
            }
            "sibling" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                let sib = target
                    .parent()
                    .unwrap_or(&self.data_dir)
                    .join(args["sibling"].as_str().unwrap_or(""));
                Ok(json!(sib.to_string_lossy()))
            }
            "library_committed" => {
                self.committed_library = true;
                Ok(Value::Bool(true))
            }
            "checkpoint" | "user_native_checkpoint" => {
                let name = args["name"].as_str().unwrap_or("");
                if self.fail_checkpoint.as_deref() == Some(name) {
                    return Err("checkpoint_failed".into());
                }
                Ok(Value::Bool(true))
            }
            "lock" | "unlock" => Ok(Value::Bool(true)),
            "user_native_kind" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                match fs::symlink_metadata(&target) {
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!("missing")),
                    Err(e) => Err(e.to_string()),
                    Ok(meta) => Ok(json!(if meta.is_dir() { "directory" } else { "other" })),
                }
            }
            "user_native_list" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                let mut names = Vec::new();
                for entry in fs::read_dir(&target).map_err(|e| e.to_string())? {
                    let entry = entry.map_err(|e| e.to_string())?;
                    names.push(entry.file_name().to_string_lossy().into_owned());
                }
                Ok(json!(names))
            }
            "user_native_exists" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                Ok(json!(fs::symlink_metadata(&target).is_ok()))
            }
            "user_native_mkdir" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                prepare_private_directory(&target)?;
                Ok(Value::Bool(true))
            }
            "user_native_copy" => {
                let src = self.resolve(args["source"].as_str().unwrap_or(""));
                let dst = self.resolve(args["destination"].as_str().unwrap_or(""));
                copy_recursive(&src, &dst)?;
                Ok(Value::Bool(true))
            }
            "user_native_remove" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                if let Ok(meta) = fs::symlink_metadata(&target) {
                    if meta.is_dir() {
                        fs::remove_dir_all(&target).map_err(|e| e.to_string())?;
                    } else {
                        fs::remove_file(&target).map_err(|e| e.to_string())?;
                    }
                }
                Ok(Value::Bool(true))
            }
            "user_native_path" => {
                let target = self.resolve(args["name"].as_str().unwrap_or(""));
                Ok(json!(target.to_string_lossy()))
            }
            _ => Err("unknown_native_effect".into()),
        }
    }
}

pub fn dispatch_storage(
    data_dir: &str,
    operation: &str,
    args: Value,
    fail_checkpoint: Option<String>,
) -> std::result::Result<(Value, bool), String> {
    let mut host = FilesystemHost::new(PathBuf::from(data_dir), fail_checkpoint);
    let result = if operation.starts_with("user_") {
        crate::user_data::dispatch(&mut host, operation, args)
    } else if matches!(operation, "import_preview" | "import_commit") {
        crate::template_import::dispatch_storage(&mut host, operation, args)
    } else if matches!(
        operation,
        "library_mode" | "library_load" | "library_save" | "library_delete"
    ) {
        crate::template_library::dispatch_storage(&mut host, operation, args)
    } else {
        Err("invalid_storage_operation".into())
    };
    result.map(|v| (v, host.committed_library))
}
