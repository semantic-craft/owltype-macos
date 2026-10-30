//! Binary-owned compatible resource set, model metadata and active-generation resolution.
use crate::{resource_contract::*, storage::Result};
use serde_json::{json, Value};
use std::{fs, path::Path};
fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
pub fn catalog() -> Value {
    serde_json::from_str(include_str!("resource_catalog.json")).expect("bundled catalog")
}
fn file_error(p: &Path, e: impl std::fmt::Display) -> String {
    error(
        "fileOperationFailed",
        json!([p.to_string_lossy(), e.to_string()]),
    )
}
fn read(p: &Path) -> Result<Vec<u8>> {
    fs::read(p).map_err(|e| file_error(p, e))
}
pub fn validate_compatible(root: &Path, m: &Value, complete: bool) -> Result<()> {
    let c = catalog();
    let files = m["files"].as_array().ok_or("invalid_payload")?;
    for name in c["requiredFiles"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .chain(["compatibility.txt"])
    {
        let path = format!("files/{name}");
        if !files.iter().any(|f| s(f, "path") == path) {
            return Err(error("fileMissing", json!([path])));
        }
    }
    verify_generation(root, m, &c["nativeEngine"], complete)?;
    let resources = root.join("files");
    if read(&resources.join("compatibility.txt"))?
        != format!("{}\n", s(&c, "configurationVersion")).as_bytes()
    {
        return Err(error(
            "incompatibleEngine",
            json!(["resource configuration version differs from this binary"]),
        ));
    }
    if digest_file(&resources.join("msime-wubi.db"))? != s(&c, "wubiDictionaryDigest") {
        return Err(error(
            "incompatibleEngine",
            json!(["official Wubi tables differ from this binary"]),
        ));
    }
    for model in c["models"].as_array().unwrap() {
        if digest_file(&resources.join("models").join(s(model, "fileName")))?
            != format!("sha256:{}", s(model, "expectedSHA256"))
        {
            return Err(error(
                "incompatibleEngine",
                json!([format!(
                    "resource model differs from this binary: {}",
                    s(model, "kind")
                )]),
            ));
        }
    }
    Ok(())
}
fn entry(file: &Path, name: &str, role: &str) -> Result<Value> {
    Ok(
        json!({"path":format!("files/{name}"),"role":role,"mediaType":"application/octet-stream","size":fs::metadata(file).map_err(|e|file_error(file,e))?.len(),"digest":digest_file(file)?}),
    )
}
fn rows(file: &Path, prefix: &str) -> Result<i64> {
    let fail = |message: &str| error("buildSQLite", json!([message]));
    let db =
        rusqlite::Connection::open_with_flags(file, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|_| fail("cannot open resource"))?;
    let mut stmt = db
        .prepare("SELECT name FROM sqlite_master WHERE type='table'")
        .map_err(|_| fail("cannot list resource tables"))?;
    let tables = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|_| fail("cannot list resource tables"))?;
    let mut total = 0;
    for table in tables {
        let table = table.map_err(|_| fail("cannot list resource tables"))?;
        if table.starts_with(prefix) {
            total += db
                .query_row(
                    &format!("SELECT COUNT(*) FROM \"{}\"", table.replace('"', "\"\"")),
                    [],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(|_| fail("cannot count resource rows"))?;
        }
    }
    Ok(total)
}
pub fn build(shared: &Path, root: &Path, version: i64) -> Result<Value> {
    let c = catalog();
    let resources = shared.join("msime");
    let files = root.join("files");
    fs::create_dir_all(&files).map_err(|e| file_error(&files, e))?;
    let notices = c["notices"].as_array().unwrap();
    let mut entries = Vec::new();
    for value in c["requiredFiles"].as_array().unwrap().iter().chain(notices) {
        let name = value.as_str().unwrap();
        let notice = notices.contains(value);
        let source = safe_file(if notice { shared } else { &resources }, name)?;
        let dest = files.join(name);
        fs::create_dir_all(dest.parent().unwrap()).map_err(|e| file_error(&dest, e))?;
        // Foundation copyItem refuses an existing destination; do not overwrite a candidate.
        let mut input = fs::File::open(&source).map_err(|e| file_error(&source, e))?;
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&dest)
            .map_err(|e| file_error(&dest, e))?;
        std::io::copy(&mut input, &mut output).map_err(|e| file_error(&dest, e))?;
        let role = match name {
            "msime-pinyin.db" => "main-dictionary",
            "msime-wubi.db" => "wubi-dictionary",
            "msime-english.db" => "english-dictionary",
            "msime-bigram.bin" => "bigram",
            "msime-trigram.bin" => "trigram",
            _ => {
                if notice {
                    "license"
                } else {
                    "other"
                }
            }
        };
        entries.push(entry(&dest, name, role)?);
    }
    let marker = files.join("compatibility.txt");
    fs::write(&marker, format!("{}\n", s(&c, "configurationVersion")))
        .map_err(|e| file_error(&marker, e))?;
    entries.push(entry(&marker, "compatibility.txt", "other")?);
    entries.sort_by(|a, b| s(a, "path").cmp(s(b, "path")));
    let mut manifest = json!({"schemaVersion":1,"packageId":c["packageId"],"inputKind":"pinyin-wubi","version":version,"digest":"",
        "license":[
            {"identifier":"GPL-3.0-only","attribution":"Pinned MSIME dictionary sources and resource notices","files":notices.iter().map(|n|format!("files/{}",n.as_str().unwrap())).collect::<Vec<_>>()},
            {"identifier":"Apache-2.0","attribution":"Pinned chinese-ime-lm models and official Jidian Wubi base","files":["files/licenses/chinese-ime-lm.LICENSE","files/wubi86-jidian.LICENSE"]},
            {"identifier":"Unlicense","attribution":"Pinned 98wubi-tables original data","files":["files/licenses/Unlicense.txt"]},
            {"identifier":"WTFPL","attribution":"Pinned administrative-division names in phrase supplements","files":["files/licenses/Administrative-divisions-of-China-WTFPL.txt"]},
            {"identifier":"MIT","attribution":"Pinned static symbol tables and kaomoji sources","files":["files/licenses/msime-latex-symbols-MIT.txt","files/rime-kaomoji.LICENSE"]}],
        "engineCompatibility":{"minimumContractVersion":1,"maximumContractVersion":1,"requiredCapabilities":["pinyin-wubi-v1","persistent-user-journal-v1"]},"files":entries});
    manifest["digest"] = json!(calculated(&manifest));
    let path = root.join("manifest.json");
    fs::write(&path, serde_json::to_vec(&manifest).unwrap()).map_err(|e| file_error(&path, e))?;
    validate_compatible(root, &manifest, false)?;
    Ok(
        json!({"manifest":manifest,"stats":{"pinyinEntries":rows(&files.join("msime-pinyin.db"),"tbl_")?,"wubiEntries":rows(&files.join("msime-wubi.db"),"wubi86")?,"englishEntries":rows(&files.join("msime-english.db"),"english_words")?,"rejectedPinyinEntries":0,"rejectedWubiEntries":0,"rejectedEnglishEntries":0}}),
    )
}
pub fn active(state_root: &Path, kind: &str) -> Result<Value> {
    let p = state_root.join("active").join(format!("{kind}.json"));
    if !p.exists() {
        return Ok(Value::Null);
    }
    let state: Value = serde_json::from_slice(&read(&p)?).map_err(|_| {
        error(
            "activeStateInvalid",
            json!(["active pointer is unreadable"]),
        )
    })?;
    if state["schemaVersion"] != 1 || state["inputKind"] != kind {
        return Err(error(
            "activeStateInvalid",
            json!(["schema or inputKind mismatch"]),
        ));
    }
    Ok(state)
}
fn validated(library: &Path, r: &Value) -> Result<Value> {
    if r["digest"] != r["manifest"]["digest"]
        || s(r, "generationId")
            != format!(
                "sha256-{}",
                s(r, "digest").strip_prefix("sha256:").unwrap_or("")
            )
    {
        return Err(error(
            "activeStateInvalid",
            json!(["active generation identity is inconsistent"]),
        ));
    }
    let root = library
        .join(s(&r["manifest"], "packageId"))
        .join("generations")
        .join(s(r, "generationId"));
    validate_compatible(&root, &r["manifest"], true)?;
    Ok(json!({"resourcesPath":root.join("files").to_string_lossy(),"contentID":r["generationId"]}))
}
pub fn dispatch(op: &str, a: Value) -> Result<Value> {
    match op {
        "resource_contract_catalog" => Ok(catalog()),
        "resource_contract_build" => build(
            Path::new(s(&a, "sharedSupport")),
            Path::new(s(&a, "root")),
            a["version"].as_i64().unwrap_or(0),
        ),
        "resource_contract_compatible" => {
            validate_compatible(
                Path::new(s(&a, "root")),
                &a["manifest"],
                a["complete"] == true,
            )?;
            Ok(json!(true))
        }
        "resource_contract_active" => {
            Ok(json!({"state":active(Path::new(s(&a,"stateRoot")),s(&a,"inputKind"))?}))
        }
        "resource_contract_validated" => validated(Path::new(s(&a, "libraryRoot")), &a["record"]),
        "resource_contract_active_generation" => {
            let state = active(Path::new(s(&a, "stateRoot")), s(&a, "inputKind"))?;
            if state.is_null() {
                return Ok(json!({"generation":null}));
            }
            let result = validated(Path::new(s(&a, "libraryRoot")), &state["current"]);
            let generation = match result {
                Ok(v) => v,
                Err(e) => {
                    if state["previous"].is_null() {
                        return Err(e);
                    } else {
                        validated(Path::new(s(&a, "libraryRoot")), &state["previous"])?
                    }
                }
            };
            Ok(json!({"generation":generation}))
        }
        _ => Err("invalid_operation".into()),
    }
}
