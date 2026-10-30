//! Stable Rime snapshot mapping. No journal is opened here; the input engine remains
//! the sole journal owner and receives the existing deterministic import request.
use crate::storage::*;
use crate::template_library::nfc;
use base64::Engine;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

fn native<H: Host>(h: &mut H, op: &str, args: Value) -> Result<Value> {
    effect(h, &format!("user_native_scan_{op}"), args)
}
fn source_digest(mut identities: Vec<(String, String)>) -> String {
    identities.sort_by(|a, b| nfc(&a.0).cmp(&nfc(&b.0)));
    let mut bytes = b"owlrime-userdb-source-v1".to_vec();
    for (p, v) in identities {
        for s in [p, v] {
            bytes.extend((s.len() as u64).to_be_bytes());
            bytes.extend(s.as_bytes());
        }
    }
    hash(&bytes)
}
fn parse(text: &str, path: &str) -> (Vec<Value>, Vec<Value>, Vec<Value>) {
    let mut metadata = Vec::new();
    let mut entries = Vec::new();
    let mut issues = Vec::new();
    let mut comments = true;
    let mut limit = false;
    for (offset, raw) in text
        .strip_prefix('\u{feff}')
        .unwrap_or(text)
        .split('\n')
        .enumerate()
    {
        let line = (offset + 1) as u64;
        if raw.len() > 64 * 1024 {
            issues.push(issue(
                "invalidEntry",
                path,
                Some(line),
                None,
                "单行超过 65536 字节".into(),
            ));
            continue;
        }
        let raw = raw.trim_end_matches(char::is_whitespace);
        if raw.is_empty() {
            continue;
        }
        if comments && raw.starts_with('#') {
            if let Some(body) = raw.strip_prefix("#@") {
                let f: Vec<_> = body.split('\t').collect();
                if f.len() == 2 {
                    metadata.push(json!({"key":f[0],"value":f[1]}));
                } else {
                    issues.push(issue(
                        "invalidMetadata",
                        path,
                        Some(line),
                        None,
                        "元数据必须恰有一个制表符".into(),
                    ));
                }
            } else if raw == "# no comment" {
                comments = false;
            }
            continue;
        }
        if entries.len() >= 500_000 {
            if !limit {
                issues.push(issue(
                    "recordLimit",
                    path,
                    Some(line),
                    None,
                    "每个快照最多读取 500000 条记录，其余记录未迁移".into(),
                ));
                limit = true;
            }
            continue;
        }
        let entry = (|| -> Option<Value> {
            let f: Vec<_> = raw.split('\t').collect();
            if f.len() != 3
                || f[0].is_empty()
                || f[1].is_empty()
                || f[0].len() > 512
                || f[1].len() > 4096
            {
                return None;
            }
            let (mut c, mut d, mut t) = (None, None, None);
            for token in f[2].split(' ').filter(|v| !v.is_empty()) {
                let (k, v) = token.split_once('=')?;
                match k {
                    "c" if c.is_none() => c = Some(v.parse::<i64>().ok()?),
                    "d" if d.is_none() => {
                        let parsed = v.parse::<f64>().ok()?;
                        if !parsed.is_finite() {
                            return None;
                        }
                        d = Some(parsed);
                    }
                    "t" if t.is_none() => t = Some(v.parse::<u64>().ok()?),
                    _ => return None,
                }
            }
            Some(json!({"code":f[0],"phrase":f[1],"commits":c?,"decay":d?,"tick":t?,"line":line}))
        })();
        if let Some(entry) = entry {
            entries.push(entry);
        } else {
            issues.push(issue(
                "invalidEntry",
                path,
                Some(line),
                None,
                "记录必须是 code、phrase、c/d/t 三列".into(),
            ));
        }
    }
    (metadata, entries, issues)
}
pub fn scan<H: Host>(h: &mut H) -> Result<Value> {
    let mut captures = Vec::new();
    let mut issues = Vec::new();
    let mut identities = Vec::new();
    let root = native(h, "kind", json!({"name":""}))?;
    if root != "missing" && root != "directory" {
        let code = if root == "symlink" {
            "sourceSymlink"
        } else {
            "sourceNotRegularFile"
        };
        issues.push(issue(
            code,
            "sync",
            None,
            None,
            "sync 必须是普通目录，未跟随该路径".into(),
        ));
        identities.push(("sync".into(), format!("rejected:{code}")));
    } else if root == "directory" {
        let installations: Vec<String> = decode(native(h, "list", json!({"name":""}))?)?;
        for installation in installations {
            let relative = format!("sync/{installation}");
            let kind = native(h, "kind", json!({"name":installation}))?;
            if kind != "directory" {
                let code = if kind == "symlink" {
                    "sourceSymlink"
                } else {
                    "sourceNotRegularFile"
                };
                issues.push(issue(
                    code,
                    &relative,
                    None,
                    None,
                    "安装目录不是普通目录，未读取".into(),
                ));
                identities.push((relative, format!("rejected:{code}")));
                continue;
            }
            let names: Vec<String> = decode(native(h, "list", json!({"name":installation}))?)?;
            for name in names.into_iter().filter(|v| v.ends_with(".userdb.txt")) {
                let name = format!("{installation}/{name}");
                let path = format!("sync/{name}");
                let kind = native(h, "kind", json!({"name":name}))?;
                if kind != "regularFile" {
                    let code = if kind == "symlink" {
                        "sourceSymlink"
                    } else {
                        "sourceNotRegularFile"
                    };
                    issues.push(issue(
                        code,
                        &path,
                        None,
                        None,
                        "同步快照不是普通文件，未读取".into(),
                    ));
                    identities.push((path, format!("rejected:{code}")));
                    continue;
                }
                let observed = native(h, "size", json!({"name":name}))?;
                if let Some(message) = observed["error"].as_str() {
                    issues.push(issue("sourceUnreadable", &path, None, None, message.into()));
                    identities.push((path, "rejected:unreadable".into()));
                    continue;
                }
                let size = observed["value"].as_u64().unwrap_or(0);
                if size > 64 * 1024 * 1024 {
                    issues.push(issue(
                        "sourceTooLarge",
                        &path,
                        None,
                        None,
                        format!("快照 {size} 字节，超过 67108864 字节上限"),
                    ));
                    identities.push((path, format!("rejected:size:{size}")));
                    continue;
                }
                let observed = native(h, "read", json!({"name":name}))?;
                if let Some(message) = observed["error"].as_str() {
                    issues.push(issue("sourceUnreadable", &path, None, None, message.into()));
                    identities.push((path, "rejected:unreadable".into()));
                    continue;
                }
                let encoded = observed["value"].clone();
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(encoded.as_str().unwrap_or(""))
                    .map_err(|_| "invalid_payload")?;
                let digest = hash(&bytes);
                identities.push((path.clone(), format!("sha256:{digest}")));
                let Ok(text) = std::str::from_utf8(&bytes) else {
                    issues.push(issue(
                        "sourceNotUTF8",
                        &path,
                        None,
                        None,
                        "同步快照不是 UTF-8，未解析".into(),
                    ));
                    continue;
                };
                let (metadata, entries, found) = parse(text, &path);
                issues.extend(found);
                let schema = name
                    .split('/')
                    .next_back()
                    .unwrap()
                    .strip_suffix(".userdb.txt")
                    .unwrap();
                captures.push(json!({"installation":installation,"schema":schema,"relativePath":path,"data":encoded,"sha256":digest,"metadata":metadata,"entries":entries}));
            }
        }
    }
    captures.sort_by(|a, b| a["relativePath"].as_str().cmp(&b["relativePath"].as_str()));
    issues.sort_by(|a, b| {
        a["source"].as_str().cmp(&b["source"].as_str()).then(
            a["line"]
                .as_u64()
                .unwrap_or(0)
                .cmp(&b["line"].as_u64().unwrap_or(0)),
        )
    });
    Ok(json!({"captures":captures,"issues":issues,"sourceDigest":source_digest(identities)}))
}

fn issue(
    code: &str,
    source: &str,
    line: Option<u64>,
    count: Option<usize>,
    message: String,
) -> Value {
    let mut value = json!({"code":code,"source":source,"message":message});
    if let Some(line) = line {
        value["line"] = json!(line);
    }
    if let Some(count) = count {
        value["count"] = json!(count);
    }
    value
}
// Existing stage files are compared byte-for-byte. Preserve Foundation's colon
// spacing and the blank line in empty arrays/objects, including nested values.
fn stage_json(value: &Value, depth: usize) -> String {
    let indent = "  ".repeat(depth);
    let child = "  ".repeat(depth + 1);
    match value {
        Value::Object(entries) => {
            let rows = entries
                .iter()
                .map(|(key, value)| {
                    format!(
                        "{child}{} : {}",
                        serde_json::to_string(key).unwrap(),
                        stage_json(value, depth + 1)
                    )
                })
                .collect::<Vec<_>>();
            format!("{{\n{}\n{indent}}}", rows.join(",\n"))
        }
        Value::Array(entries) => {
            let rows = entries
                .iter()
                .map(|value| format!("{child}{}", stage_json(value, depth + 1)))
                .collect::<Vec<_>>();
            format!("[\n{}\n{indent}]", rows.join(",\n"))
        }
        _ => serde_json::to_string(value).unwrap(),
    }
}

fn kind(schema: &str) -> Option<&'static str> {
    if schema == "rime_ice" || schema == "terra_pinyin" || schema.starts_with("luna_pinyin") {
        Some("pinyin")
    } else if schema.starts_with("wubi98") {
        Some("wubi98")
    } else if schema.starts_with("wubi86") {
        Some("wubi")
    } else {
        None
    }
}
pub fn plan(args: Value) -> Result<Value> {
    let scan = &args["scan"];
    let captures = scan["captures"].as_array().ok_or("invalid_payload")?;
    let mut issues = scan["issues"].as_array().cloned().unwrap_or_default();
    let mut pins = Vec::new();
    let mut seen = BTreeSet::new();
    let bytes: Vec<u8> = serde_json::from_value(args["pins"].clone()).unwrap_or_default();
    if !bytes.is_empty() {
        match serde_json::from_slice::<Vec<Value>>(&bytes) {
            Ok(values)
                if values.iter().all(|p| {
                    p["code"].is_string() && p["text"].is_string() && p["traditional"].is_boolean()
                }) =>
            {
                for p in values {
                    let code = p["code"].as_str().unwrap();
                    let text = p["text"].as_str().unwrap();
                    if code.is_empty()
                        || text.is_empty()
                        || code.contains(['\t', '\n', '\r'])
                        || text.contains(['\t', '\n', '\r'])
                    {
                        issues.push(issue(
                            "invalidPinnedWord",
                            "owl_pinned_words",
                            None,
                            None,
                            "有一条置顶含空字段或会破坏引擎属性格式的控制字符，未迁移".into(),
                        ));
                        continue;
                    }
                    let key = (nfc(code), nfc(text), p["traditional"] == true);
                    if !seen.insert(key) {
                        issues.push(issue(
                            "coalescedPin",
                            "owl_pinned_words",
                            None,
                            Some(2),
                            "重复置顶已按原有先后顺序合并".into(),
                        ));
                        continue;
                    }
                    pins.push(json!({"code":code,"text":text,"traditional":p["traditional"]}));
                }
            }
            _ => issues.push(issue(
                "invalidPinnedWords",
                "owl_pinned_words",
                None,
                None,
                format!(
                    "旧置顶 JSON 无法解码：{}",
                    args["pinsError"].as_str().unwrap_or("无效置顶数据")
                ),
            )),
        }
    }
    let mut mapped: BTreeMap<(u8, String, String), (Value, i64)> = BTreeMap::new();
    let mut sources = Vec::new();
    for capture in captures {
        let schema = capture["schema"].as_str().unwrap_or("");
        let path = capture["relativePath"].as_str().unwrap_or("");
        let entries = capture["entries"].as_array().ok_or("invalid_payload")?;
        sources.push(json!({"path":path,"installation":capture["installation"],"schema":schema,"sha256":capture["sha256"],"bytes":capture["bytes"],"entries":entries.len(),"metadata":capture["metadata"]}));
        let Some(kind) = kind(schema) else {
            issues.push(issue(
                "unsupportedSchema",
                path,
                None,
                Some(entries.len()),
                format!("方案 {schema} 没有已确认的 Rust 词库映射，跳过全部记录"),
            ));
            continue;
        };
        for entry in entries {
            let raw = entry["code"].as_str().unwrap_or("");
            let raw = raw.trim_matches(crate::foundation_text::is_whitespace);
            let code = if kind == "pinyin" {
                raw.split([' ', '\''])
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("'")
            } else {
                raw.to_owned()
            };
            let line = entry["line"].as_u64();
            if code.is_empty() || code.len() > 512 {
                issues.push(issue(
                    "invalidEntry",
                    path,
                    line,
                    None,
                    "编码去掉 Rime 分隔空格后为空或超过 512 字节".into(),
                ));
                continue;
            }
            let commits = entry["commits"].as_i64().ok_or("invalid_payload")?;
            let word = entry["phrase"].as_str().unwrap_or("");
            let key = (
                match kind {
                    "pinyin" => 0,
                    "wubi" => 1,
                    _ => 2,
                },
                nfc(&code),
                nfc(word),
            );
            let record = json!({"type":"overlay","deleted":commits<0,"data":{"kind":kind,"code":code,"word":word,"weight":if commits<0 {0} else {commits.clamp(1,100_000_000)},"user_inserted":false}});
            if let Some((_, previous)) = mapped.get(&key) {
                issues.push(issue(
                    "coalescedEntry",
                    path,
                    line,
                    Some(2),
                    format!("同一目标词条重复，按 commits 取大：{previous} 与 {commits}"),
                ));
                if commits <= *previous {
                    continue;
                }
            }
            mapped.insert(key, (record, commits));
        }
    }
    let records: Vec<_> = mapped.into_values().map(|v| v.0).collect();
    let mut record_data = Vec::new();
    for record in &records {
        record_data.extend(serde_json::to_vec(record).map_err(|_| "invalid_payload")?);
        record_data.push(b'\n');
    }
    let record_digest = hash(&record_data);
    let key = json!({"schemaVersion":1,"mapperVersion":"rime-userdb-v1","sourceDigest":scan["sourceDigest"],"recordDigest":record_digest,"pins":pins,"issues":issues});
    let request_id = format!(
        "owlrime-migrate-{}",
        hash(&serde_json::to_vec(&key).map_err(|_| "invalid_payload")?)
    );
    let mut manifest = key;
    manifest["requestID"] = json!(request_id);
    manifest["sources"] = json!(sources);
    manifest["limitations"] = serde_json::from_str(include_str!("user_migration_limitations.json"))
        .map_err(|_| "invalid_payload")?;
    let mut manifest_data = stage_json(&manifest, 0).into_bytes();
    manifest_data.push(b'\n');
    Ok(
        json!({"manifest":manifest,"records":records,"recordData":record_data,"manifestData":manifest_data}),
    )
}

fn stage_error(code: &str, detail: &str) -> String {
    format!("user_stage:{}", json!({"code":code,"detail":detail}))
}
pub fn stage<H: Host>(host: &mut H, args: Value) -> Result<Value> {
    let m = &args["manifest"];
    let request = m["requestID"].as_str().unwrap_or("");
    let records: Vec<u8> = decode(args["recordData"].clone())?;
    if m["schemaVersion"] != 1
        || m["mapperVersion"] != "rime-userdb-v1"
        || request.len() != 80
        || !request.starts_with("owlrime-migrate-")
        || !request.as_bytes()[16..]
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        || m["recordDigest"] != hash(&records)
    {
        return Err(stage_error(
            "invalidPlan",
            "manifest 版本、requestID 或 recordDigest 不匹配",
        ));
    }
    let effect = |h: &mut H, op: &str, a: Value| {
        crate::storage::effect(h, &format!("user_native_stage_{op}"), a)
    };
    if effect(host, "source_digest", json!({}))? != m["sourceDigest"] {
        return Err(stage_error("sourceChanged", ""));
    }
    let root = ".owl-user-migration";
    let destination = format!("{root}/{request}");
    match effect(host, "kind", json!({"name":root}))?
        .as_str()
        .unwrap_or("")
    {
        "missing" => {
            effect(host, "mkdir", json!({"name":root}))?;
        }
        "directory" => {
            effect(host, "chmod", json!({"name":root}))?;
        }
        _ => return Err(stage_error("invalidStagingPath", root)),
    }
    let marker = b"owlrime-user-migration-v1\n".to_vec();
    let manifest: Vec<u8> = decode(args["manifestData"].clone())?;
    let entries = [
        ("manifest.json", manifest),
        ("dictionary-state.ndjson", records),
        (".prepared", marker),
    ];
    let kind = effect(host, "kind", json!({"name":destination}))?;
    if kind != "missing" {
        if kind != "directory" {
            return Err(stage_error("requestIDCollision", request));
        }
        let names = effect(host, "list", json!({"name":destination}))
            .ok()
            .and_then(|v| serde_json::from_value::<Vec<String>>(v).ok())
            .ok_or_else(|| stage_error("requestIDCollision", request))?;
        let complete = entries.iter().all(|(n, _)| names.iter().any(|v| v == n));
        if complete {
            if names.len() != 3 {
                return Err(stage_error("requestIDCollision", request));
            }
            for (name, bytes) in &entries {
                let name = format!("{destination}/{name}");
                if effect(host, "kind", json!({"name":name}))? != "regularFile"
                    || effect(host, "read", json!({"name":name})).ok().as_ref()
                        != Some(&json!(bytes))
                {
                    return Err(stage_error("requestIDCollision", request));
                }
            }
            if effect(host, "source_digest", json!({}))? != m["sourceDigest"] {
                return Err(stage_error("sourceChanged", ""));
            }
            return Ok(json!({"disposition":"reused","directory":destination}));
        }
        effect(host, "remove", json!({"name":destination}))?;
    }
    if let Err(e) = effect(host, "mkdir", json!({"name":destination})) {
        return Err(
            if effect(host, "kind", json!({"name":destination}))? != "missing" {
                stage_error("requestIDCollision", request)
            } else {
                e
            },
        );
    }
    let result = (|| {
        for (name, bytes) in entries {
            effect(
                host,
                "write",
                json!({"name":format!("{destination}/{name}"),"bytes":bytes}),
            )?;
        }
        effect(host, "sync", json!({"name":destination}))?;
        effect(host, "sync", json!({"name":root}))?;
        if effect(host, "source_digest", json!({}))? != m["sourceDigest"] {
            return Err(stage_error("sourceChanged", ""));
        }
        Ok(json!({"disposition":"prepared","directory":destination}))
    })();
    if result.is_err() {
        let _ = effect(host, "remove", json!({"name":destination}));
    }
    result
}

fn import_error(code: &str, detail: &str) -> String {
    format!("user_import:{}", json!({"code":code,"detail":detail}))
}
pub fn import<H: Host>(host: &mut H, args: Value) -> Result<Value> {
    let effect = |h: &mut H, op: &str, a: Value| {
        crate::storage::effect(h, &format!("user_native_import_{op}"), a)
    };
    let active = effect(host, "active", json!({}))?;
    let mut warnings = Vec::new();
    if let Some(e) = active["error"].as_str() {
        warnings.push(json!(format!(
            "当前完整词库不可用，迁移与重新启动都回退到随包精简词库：{e}"
        )));
    }
    let generation = if !active["generation"].is_null() {
        active["generation"].clone()
    } else {
        let Some(shared) = args["sharedSupport"].as_str() else {
            return Err(import_error("bundledResourcesUnavailable", ""));
        };
        let resources = format!("{shared}/msime");
        let digest = effect(host, "digest", json!({"path":resources}))
            .map_err(|_| import_error("bundledResourcesUnavailable", ""))?;
        json!({"resourcesPath":resources,"contentID":format!("seed-{}",digest.as_str().ok_or("invalid_payload")?)})
    };
    let root = args["userRoot"].as_str().ok_or("invalid_payload")?;
    let user = format!("{root}/msime-user");
    let cache = format!("{root}/msime-cache");
    let parent = format!("{user}/dictionaries");
    let dictionaries = format!(
        "{parent}/{}",
        generation["contentID"].as_str().ok_or("invalid_payload")?
    );
    for path in [&user, &cache, &parent] {
        effect(host, "mkdir", json!({"path":path}))?;
    }
    let mut context = json!({"resources":generation["resourcesPath"],"user":user,"cache":cache,"contentID":generation["contentID"],"dictionaries":dictionaries,"requestID":args["manifest"]["requestID"]});
    effect(host, "prepare", context.clone())?;
    if effect(host, "is_directory", json!({"path":dictionaries}))? != true {
        return Err(import_error("runtimeDirectoryFailed", &dictionaries));
    }
    let report = effect(host, "report", std::mem::take(&mut context))?;
    if report["ok"] != true {
        return Err(import_error(
            "rejected",
            report["error"]
                .as_str()
                .unwrap_or("Rust importer returned ok=false without an error"),
        ));
    }
    let manifest = &args["manifest"];
    if report["request_id"] != manifest["requestID"] {
        return Err(import_error(
            "invalidReport",
            "request_id does not match the staged request",
        ));
    }
    if report["source_count"].as_u64() != manifest["sources"].as_array().map(|a| a.len() as u64)
        || report["issue_count"].as_u64() != manifest["issues"].as_array().map(|a| a.len() as u64)
        || report["record_count"] != args["recordCount"]
        || report["pins_total"].as_u64() != manifest["pins"].as_array().map(|a| a.len() as u64)
    {
        return Err(import_error(
            "invalidReport",
            "source, issue, record or pin count differs from the staged manifest",
        ));
    }
    warnings.extend(report["warnings"].as_array().into_iter().flatten().cloned());
    Ok(json!({"report":report,"generation":generation,"warnings":warnings}))
}
