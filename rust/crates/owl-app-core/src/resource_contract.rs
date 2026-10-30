//! Frozen manifest, digest, path and SQLite compatibility contract.
use crate::{
    foundation_text::trim,
    storage::{hash, Result},
};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

// Mirror Codable's persisted comparison: unknown fields are ignored and an absent
// optional requiredTables is equivalent to null. Raw JSON object equality is not.
#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct StoredManifest {
    schema_version: i64,
    package_id: String,
    input_kind: String,
    version: i64,
    digest: String,
    license: Vec<StoredLicense>,
    engine_compatibility: StoredCompatibility,
    files: Vec<StoredFile>,
}
#[derive(Deserialize, PartialEq)]
struct StoredLicense {
    identifier: String,
    attribution: String,
    files: Vec<String>,
}
#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct StoredCompatibility {
    minimum_contract_version: i64,
    maximum_contract_version: i64,
    required_capabilities: Vec<String>,
}
#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct StoredFile {
    path: String,
    role: String,
    media_type: String,
    size: i64,
    digest: String,
    required_tables: Option<Vec<String>>,
}
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Read,
    path::{Path, PathBuf},
};
fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
pub fn error(code: &str, args: Value) -> String {
    format!("resource:{}", json!({"code":code,"args":args}))
}
fn invalid(m: impl Into<String>) -> String {
    error("invalidManifest", json!([m.into()]))
}
fn file_error(p: &Path, e: impl std::fmt::Display) -> String {
    error(
        "fileOperationFailed",
        json!([p.to_string_lossy(), e.to_string()]),
    )
}
pub fn digest_valid(s: &str) -> bool {
    s.len() == 71
        && s.starts_with("sha256:")
        && s.as_bytes()[7..]
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
}
pub fn relative(p: &str) -> Result<()> {
    if p.is_empty()
        || p.contains(['\0', '\\'])
        || p.split('/').any(|c| c.is_empty() || c == "." || c == "..")
    {
        Err(error("unsafePath", json!([p])))
    } else {
        Ok(())
    }
}
pub fn package_valid(p: &str) -> bool {
    (1..=128).contains(&p.len())
        && p.as_bytes()[0].is_ascii_alphanumeric()
        && p.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
}
pub fn metadata(m: &Value) -> Result<()> {
    if m["schemaVersion"] != 1 {
        return Err(invalid(format!(
            "不支持 schemaVersion {}",
            m["schemaVersion"]
        )));
    }
    if !package_valid(text(m, "packageId")) {
        return Err(invalid(format!("packageId 无效：{}", text(m, "packageId"))));
    }
    if m["version"].as_i64().unwrap_or(0) <= 0 {
        return Err(invalid("version 必须为正整数"));
    }
    if !digest_valid(text(m, "digest")) {
        return Err(error("invalidDigest", json!([m["digest"]])));
    }
    let licenses = m["license"]
        .as_array()
        .filter(|a| !a.is_empty())
        .ok_or_else(|| invalid("license 不得为空"))?;
    let files = m["files"]
        .as_array()
        .filter(|a| !a.is_empty())
        .ok_or_else(|| invalid("files 不得为空"))?;
    let mut paths = BTreeSet::new();
    let mut roles = BTreeSet::new();
    let mut license_files = BTreeSet::new();
    for f in files {
        let p = text(f, "path");
        relative(p)?;
        if !p.starts_with("files/") {
            return Err(error("unsafePath", json!([p])));
        }
        if !paths.insert(p) {
            return Err(error("duplicatePath", json!([p])));
        }
        if f["size"].as_i64().unwrap_or(0) <= 0 {
            return Err(invalid(format!("文件大小必须为正：{p}")));
        }
        if !digest_valid(text(f, "digest")) {
            return Err(error("invalidDigest", json!([f["digest"]])));
        }
        if trim(text(f, "mediaType")).is_empty() {
            return Err(invalid(format!("mediaType 为空：{p}")));
        }
        let role = text(f, "role");
        if [
            "main-dictionary",
            "wubi-dictionary",
            "english-dictionary",
            "bigram",
            "trigram",
        ]
        .contains(&role)
            && !roles.insert(role)
        {
            return Err(invalid(format!("role 重复：{role}")));
        }
        if role == "license" {
            license_files.insert(p);
        }
        if let Some(tables) = f["requiredTables"].as_array() {
            for t in tables {
                if trim(t.as_str().unwrap_or("")).is_empty() {
                    return Err(invalid(format!("requiredTables 含空表名：{p}")));
                }
            }
        }
    }
    for l in licenses {
        let names = l["files"]
            .as_array()
            .filter(|a| !a.is_empty())
            .ok_or_else(|| invalid("license 条目缺少 identifier/attribution/files"))?;
        if trim(text(l, "identifier")).is_empty() || trim(text(l, "attribution")).is_empty() {
            return Err(invalid("license 条目缺少 identifier/attribution/files"));
        }
        for name in names {
            let p = name.as_str().unwrap_or("");
            relative(p)?;
            if !license_files.contains(p) {
                return Err(invalid(format!(
                    "license notice 未以 role=license 列入 files：{p}"
                )));
            }
        }
    }
    let c = &m["engineCompatibility"];
    let min = c["minimumContractVersion"].as_i64().unwrap_or(0);
    let max = c["maximumContractVersion"].as_i64().unwrap_or(0);
    if min <= 0 || max < min {
        return Err(invalid("engineCompatibility 版本区间无效"));
    }
    let caps = c["requiredCapabilities"]
        .as_array()
        .ok_or_else(|| invalid("requiredCapabilities 含空值或重复值"))?;
    let mut seen = BTreeSet::new();
    if caps
        .iter()
        .any(|v| trim(v.as_str().unwrap_or("")).is_empty() || !seen.insert(v.as_str()))
    {
        return Err(invalid("requiredCapabilities 含空值或重复值"));
    }
    Ok(())
}
pub fn calculated(m: &Value) -> String {
    let mut unsigned = m.clone();
    unsigned["digest"] = json!(format!("sha256:{}", "0".repeat(64)));
    format!("sha256:{}", hash(&serde_json::to_vec(&unsigned).unwrap()))
}
pub fn validate(m: &Value) -> Result<()> {
    metadata(m)?;
    let actual = calculated(m);
    if actual != text(m, "digest") {
        return Err(error(
            "manifestDigestMismatch",
            json!([m["digest"], actual]),
        ));
    }
    Ok(())
}
pub fn compatibility(m: &Value, e: &Value) -> Result<()> {
    let c = &m["engineCompatibility"];
    let v = e["contractVersion"].as_i64().unwrap_or(0);
    let min = c["minimumContractVersion"].as_i64().unwrap_or(0);
    let max = c["maximumContractVersion"].as_i64().unwrap_or(0);
    if !(min..=max).contains(&v) {
        return Err(error(
            "incompatibleEngine",
            json!([format!("engine contract {v} 不在 {min}...{max}")]),
        ));
    }
    let provided = e["capabilities"].as_array().cloned().unwrap_or_default();
    let mut missing: Vec<_> = c["requiredCapabilities"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|v| !provided.contains(v))
        .filter_map(Value::as_str)
        .collect();
    missing.sort();
    missing.dedup();
    if !missing.is_empty() {
        return Err(error(
            "incompatibleEngine",
            json!([format!("缺少 capabilities：{}", missing.join(", "))]),
        ));
    }
    Ok(())
}
pub fn safe_file(root: &Path, p: &str) -> Result<PathBuf> {
    relative(p)?;
    let mut current = root.to_owned();
    for c in p.split('/') {
        current.push(c);
        let info = fs::symlink_metadata(&current).map_err(|_| error("fileMissing", json!([p])))?;
        if info.file_type().is_symlink() {
            return Err(error("fileNotRegular", json!([p])));
        }
    }
    Ok(current)
}
fn configuration(a: &Value) -> Result<Value> {
    use std::os::unix::fs::DirBuilderExt;
    let keys = [
        "libraryRoot",
        "stagingRoot",
        "runtimeRoot",
        "stateRoot",
        "userRoot",
        "cacheRoot",
    ];
    let roots: Vec<_> = keys.iter().map(|k| text(a, k)).collect();
    let fail = |message: String| error("invalidConfiguration", json!([message]));
    for p in &roots {
        if !p.starts_with('/') {
            return Err(fail("所有根必须为绝对路径".into()));
        }
        if p.split('/')
            .skip(1)
            .any(|c| c.is_empty() || c == "." || c == "..")
        {
            return Err(fail("所有根必须为规范路径".into()));
        }
    }
    if !Path::new(roots[4]).is_dir() {
        return Err(fail(format!("userRoot 必须已存在：{}", roots[4])));
    }
    for p in &roots {
        let mut current = PathBuf::from("/");
        for c in p.split('/').skip(1) {
            current.push(c);
            match fs::symlink_metadata(&current) {
                Ok(m) => {
                    if m.file_type().is_symlink() {
                        return Err(fail(format!("路径不得含 symlink：{}", current.display())));
                    }
                    if !m.is_dir() {
                        return Err(fail(format!("路径祖先不是目录：{}", current.display())));
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => break,
                Err(e) => return Err(fail(format!("无法检查路径 {}：{e}", current.display()))),
            }
        }
    }
    let overlaps = |paths: &[String]| -> Result<()> {
        for i in 0..paths.len() {
            for j in i + 1..paths.len() {
                let l = &paths[i];
                let r = &paths[j];
                if l == r || l.starts_with(&format!("{r}/")) || r.starts_with(&format!("{l}/")) {
                    return Err(fail(format!("根目录重叠：{l} / {r}")));
                }
            }
        }
        Ok(())
    };
    overlaps(&roots.iter().map(|p| p.to_string()).collect::<Vec<_>>())?;
    for (i, p) in roots.iter().enumerate() {
        if i != 4 {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(p)
                .map_err(|e| fail(format!("无法创建 {p}：{e}")))?;
        }
    }
    let canonical: Vec<String> = roots
        .iter()
        .map(|p| {
            fs::canonicalize(p)
                .map(|p| p.to_string_lossy().into_owned())
                .map_err(|e| fail(format!("无法解析目录 {p}：{e}")))
        })
        .collect::<Result<_>>()?;
    overlaps(&canonical)?;
    Ok(Value::Object(
        keys.iter()
            .zip(canonical)
            .map(|(k, v)| (k.to_string(), json!(v)))
            .collect(),
    ))
}
fn safe_destination(root: &Path, p: &str) -> Result<PathBuf> {
    relative(p)?;
    let parts: Vec<_> = p.split('/').collect();
    let mut current = root.to_path_buf();
    for (i, part) in parts.iter().enumerate() {
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(m) => {
                if m.file_type().is_symlink() || (i + 1 < parts.len() && !m.is_dir()) {
                    return Err(error("fileNotRegular", json!([p])));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(file_error(&current, e)),
        }
    }
    Ok(current)
}
pub fn digest_file(p: &Path) -> Result<String> {
    let mut file = fs::File::open(p).map_err(|e| file_error(p, e))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    loop {
        let n = file.read(&mut buffer).map_err(|e| file_error(p, e))?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(format!(
        "sha256:{}",
        hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    ))
}
pub fn verify_file(p: &Path, f: &Value) -> Result<()> {
    let name = p.file_name().unwrap_or_default().to_string_lossy();
    let info = fs::symlink_metadata(p).map_err(|_| error("fileMissing", json!([name])))?;
    if !info.is_file() {
        return Err(error("fileNotRegular", json!([name])));
    }
    if Some(info.len()) != f["size"].as_u64() {
        return Err(error(
            "fileSizeMismatch",
            json!([f["path"], f["size"], info.len()]),
        ));
    }
    let actual = digest_file(p)?;
    if actual != text(f, "digest") {
        return Err(error(
            "fileDigestMismatch",
            json!([f["path"], f["digest"], actual]),
        ));
    }
    Ok(())
}
fn sqlite(p: &Path, required: BTreeSet<String>, trusted: &[Value]) -> Result<()> {
    use rusqlite::{Connection, OpenFlags};
    let path = p.to_string_lossy();
    let db = Connection::open_with_flags(
        p,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| error("sqliteOpenFailed", json!([path, e.to_string()])))?;
    let integrity =
        |e: rusqlite::Error| error("sqliteIntegrityFailed", json!([path, e.to_string()]));
    let check: String = db
        .query_row("PRAGMA quick_check", [], |r| r.get(0))
        .map_err(integrity)?;
    if check != "ok" {
        return Err(error(
            "sqliteIntegrityFailed",
            json!([path, "PRAGMA quick_check 未返回 ok"]),
        ));
    }
    if db
        .prepare("PRAGMA foreign_key_check")
        .map_err(integrity)?
        .exists([])
        .map_err(integrity)?
    {
        return Err(error(
            "sqliteIntegrityFailed",
            json!([path, "PRAGMA foreign_key_check 返回了冲突行"]),
        ));
    }
    let mut statement = db
        .prepare("SELECT name FROM sqlite_master WHERE type='table'")
        .map_err(integrity)?;
    let tables: BTreeSet<String> = statement
        .query_map([], |r| r.get(0))
        .map_err(integrity)?
        .collect::<std::result::Result<_, _>>()
        .map_err(integrity)?;
    for t in required {
        if !tables.contains(&t) {
            return Err(error(
                "sqliteSchemaMismatch",
                json!([path, format!("缺少表 {t}")]),
            ));
        }
    }
    for requirement in trusted {
        let table = text(requirement, "table");
        if !tables.contains(table) {
            return Err(error(
                "sqliteSchemaMismatch",
                json!([path, format!("缺少可信引擎要求的表 {table}")]),
            ));
        }
        let mut statement = db
            .prepare(&format!(
                "PRAGMA table_info(\"{}\")",
                table.replace('"', "\"\"")
            ))
            .map_err(integrity)?;
        let columns: BTreeSet<String> = statement
            .query_map([], |r| r.get(1))
            .map_err(integrity)?
            .collect::<std::result::Result<_, _>>()
            .map_err(integrity)?;
        let mut missing: Vec<_> = requirement["columns"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|c| !columns.contains(*c))
            .collect();
        missing.sort();
        if !missing.is_empty() {
            return Err(error(
                "sqliteSchemaMismatch",
                json!([path, format!("表 {table} 缺少列 {}", missing.join(", "))]),
            ));
        }
    }
    Ok(())
}
pub fn verify_generation(root: &Path, m: &Value, e: &Value, complete: bool) -> Result<()> {
    validate(m)?;
    compatibility(m, e)?;
    let stored = fs::read(root.join("manifest.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<StoredManifest>(&b).ok());
    let expected = serde_json::from_value::<StoredManifest>(m.clone()).ok();
    if stored.is_none() || stored != expected {
        return Err(error(
            "generationCorrupt",
            json!(["manifest.json 与期望 manifest 不一致"]),
        ));
    }
    if complete
        && fs::read_to_string(root.join(".complete"))
            .ok()
            .map(|s| trim(&s) == text(m, "digest"))
            != Some(true)
    {
        return Err(error(
            "generationCorrupt",
            json!(["完整标记缺失或摘要不符"]),
        ));
    }
    let files = m["files"].as_array().ok_or("invalid_payload")?;
    for f in files {
        verify_file(&safe_file(root, text(f, "path"))?, f)?;
    }
    let mut by_role: BTreeMap<&str, Vec<Value>> = BTreeMap::new();
    for r in e["sqliteRequirements"].as_array().into_iter().flatten() {
        by_role
            .entry(text(r, "role"))
            .or_default()
            .extend(r["tables"].as_array().into_iter().flatten().cloned());
    }
    for (role, trusted) in &by_role {
        let f = files
            .iter()
            .find(|f| text(f, "role") == *role)
            .ok_or_else(|| error("missingEngineSQLiteFile", json!([role])))?;
        let required = f["requiredTables"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .chain(trusted.iter().map(|t| text(t, "table")))
            .map(str::to_owned)
            .collect();
        sqlite(&safe_file(root, text(f, "path"))?, required, trusted)?;
    }
    for f in files {
        if !by_role.contains_key(text(f, "role")) {
            let required: BTreeSet<String> = f["requiredTables"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            if !required.is_empty() {
                sqlite(&safe_file(root, text(f, "path"))?, required, &[])?;
            }
        }
    }
    Ok(())
}
pub fn dispatch(op: &str, a: Value) -> Result<Value> {
    let m = &a["manifest"];
    let e = &a["engine"];
    let p = Path::new(text(&a, "path"));
    match op {
        "resource_contract_configuration" => return configuration(&a),
        "resource_contract_volumes" => {
            if a["library"] != a["staging"] {
                return Err(error("differentVolumes", json!([])));
            }
        }
        "resource_contract_safe_destination" => {
            return Ok(json!(safe_destination(
                Path::new(text(&a, "root")),
                text(&a, "path")
            )?
            .to_string_lossy()))
        }
        "resource_contract_calculated" => return Ok(json!(calculated(m))),
        "resource_contract_digest" => return Ok(json!(digest_valid(text(&a, "digest")))),
        "resource_contract_package" => return Ok(json!(package_valid(text(&a, "package")))),
        "resource_contract_canonical" => return Ok(json!(serde_json::to_vec(m).unwrap())),
        "resource_contract_metadata" => metadata(m)?,
        "resource_contract_validate" => validate(m)?,
        "resource_contract_relative" => relative(text(&a, "path"))?,
        "resource_contract_compatibility" => compatibility(m, e)?,
        "resource_contract_file" => verify_file(p, &a["file"])?,
        "resource_contract_safe" => {
            return Ok(json!(safe_file(
                Path::new(text(&a, "root")),
                text(&a, "path")
            )?
            .to_string_lossy()))
        }
        "resource_contract_file_digest" => return Ok(json!(digest_file(p)?)),
        "resource_contract_generation" => verify_generation(p, m, e, a["complete"] == true)?,
        _ => return crate::resource_catalog::dispatch(op, a),
    }
    Ok(json!(true))
}
