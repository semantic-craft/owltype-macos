//! Provider profile storage and staged credential transactions. Secret values remain native;
//! only per-call references and digest facts cross the effect boundary.
use crate::{
    foundation_text::trim,
    provider_wire::s,
    storage::{self, Host, Result},
};
use serde_json::{json, Value};
fn effect<H: Host>(h: &mut H, op: &str, a: Value) -> Result<Value> {
    storage::effect(h, op, a)
}
pub fn secret_name(id: &str) -> String {
    format!("owltype.provider.{id}.apiKey")
}
pub fn inferred(p: &Value) -> String {
    if p.is_null() {
        return "deepseek".into();
    }
    if !s(p, "providerID").is_empty() {
        return s(p, "providerID").into();
    }
    let host = url::Url::parse(s(p, "endpoint"))
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .unwrap_or_default()
        .to_lowercase();
    let name = s(p, "displayName").to_lowercase();
    for (id, hosts, names) in [
        ("qwen", vec!["dashscope", "aliyuncs"], vec!["百炼", "qwen"]),
        ("doubao", vec!["volces", "volcengine"], vec!["豆包"]),
        ("deepseek", vec!["deepseek"], vec!["deepseek"]),
        ("minimax", vec!["minimax"], vec!["minimax"]),
        ("gemini", vec!["generativelanguage"], vec!["gemini"]),
        ("openai", vec!["api.openai.com"], vec!["openai"]),
    ] {
        if hosts.iter().any(|v| {
            if id == "openai" {
                host == *v
            } else {
                host.contains(v)
            }
        }) || names.iter().any(|v| name.contains(v))
        {
            return id.into();
        }
    }
    "custom".into()
}
pub fn known(id: &str) -> bool {
    matches!(
        id,
        "qwen" | "doubao" | "deepseek" | "minimax" | "gemini" | "openai" | "custom"
    )
}
fn sorted(mut p: Vec<Value>) -> Vec<Value> {
    p.sort_by(|a, b| {
        a["createdAt"]
            .as_f64()
            .unwrap_or(0.)
            .total_cmp(&b["createdAt"].as_f64().unwrap_or(0.))
            .then_with(|| s(a, "id").cmp(s(b, "id")))
    });
    p
}
pub fn normalize(raw: Value) -> Result<Value> {
    let mut p = raw.as_object().cloned().ok_or("malformed_profile")?;
    for key in ["id", "endpoint"] {
        if !p.get(key).is_some_and(Value::is_string) {
            return Err("malformed_profile".into());
        }
    }
    let id = p["id"].as_str().unwrap().to_owned();
    for (k, v) in [
        ("displayName", json!("Provider")),
        ("kind", json!("openai_compatible")),
        ("model", json!("")),
        ("secretName", json!(secret_name(&id))),
        ("isDefault", json!(false)),
        ("createdAt", json!(-978307200.0)),
    ] {
        if p.get(k).is_none_or(Value::is_null) {
            p.insert(k.into(), v);
        }
    }
    if p["kind"] != "openai_compatible"
        || !p["isDefault"].is_boolean()
        || !p["createdAt"].is_number()
        || ["displayName", "model", "secretName"]
            .iter()
            .any(|k| !p[*k].is_string())
        || p.get("providerID")
            .is_some_and(|v| !v.is_null() && !v.is_string())
    {
        return Err("malformed_profile".into());
    }
    p.retain(|k, _| {
        [
            "id",
            "endpoint",
            "displayName",
            "kind",
            "model",
            "secretName",
            "isDefault",
            "createdAt",
            "providerID",
        ]
        .contains(&k.as_str())
    });
    Ok(Value::Object(p))
}
fn read_file<H: Host>(h: &mut H) -> Result<Value> {
    let data = effect(h, "provider_read", json!({}))?;
    if data.is_null() {
        return Ok(json!({"schemaVersion":1,"profiles":[]}));
    }
    let bytes: Vec<u8> = storage::decode(data)?;
    let file: Value = serde_json::from_slice(&bytes).map_err(|_| "malformed_profile")?;
    if !file.is_object()
        || file
            .get("schemaVersion")
            .is_some_and(|v| !v.is_null() && !v.is_i64())
    {
        return Err("malformed_profile".into());
    }
    let mut out = vec![];
    if let Some(profiles) = file.get("profiles").filter(|v| !v.is_null()) {
        for raw in profiles.as_array().ok_or("malformed_profile")? {
            let mut p = raw.clone();
            if let Some(date) = p.get("createdAt").filter(|v| !v.is_null()) {
                p["createdAt"] = effect(h, "date_parse", json!({"text":date}))?;
            }
            let p = normalize(p)?;
            if effect(h, "url_facts", json!({"text":p["endpoint"]}))?.is_null() {
                return Err("malformed_profile".into());
            }
            out.push(p);
        }
    }
    Ok(json!({"schemaVersion":file["schemaVersion"].as_i64().unwrap_or(1),"profiles":out}))
}
fn read<H: Host>(h: &mut H) -> Result<Vec<Value>> {
    let file = read_file(h)?;
    Ok(file["profiles"].as_array().cloned().unwrap_or_default())
}
fn load<H: Host>(h: &mut H) -> Vec<Value> {
    read(h).unwrap_or_default()
}
fn write<H: Host>(h: &mut H, profiles: &[Value]) -> Result<()> {
    let mut out = profiles.to_vec();
    for p in &mut out {
        p["createdAt"] = effect(h, "date_format", json!({"value":p["createdAt"]}))?;
        if p["providerID"].is_null() {
            p.as_object_mut().unwrap().remove("providerID");
        }
    }
    let bytes = serde_json::to_vec_pretty(&json!({"schemaVersion":1,"profiles":out}))
        .map_err(|_| "invalid_profile")?;
    // Preserve Foundation's human-readable key separator without touching colons
    // inside endpoint URLs, names, or other JSON string values.
    let mut formatted = Vec::with_capacity(bytes.len());
    let (mut quoted, mut escaped) = (false, false);
    for byte in bytes {
        if !quoted && byte == b':' {
            formatted.push(b' ');
        }
        formatted.push(byte);
        if escaped {
            escaped = false;
        } else if quoted && byte == b'\\' {
            escaped = true;
        } else if byte == b'"' {
            quoted = !quoted;
        }
    }
    effect(h, "provider_write", json!({"bytes":formatted}))?;
    Ok(())
}
fn defaults(mut all: Vec<Value>, preferred: Option<String>) -> Vec<Value> {
    let id = preferred
        .or_else(|| {
            all.iter()
                .find(|p| p["isDefault"] == true)
                .map(|p| s(p, "id").to_owned())
        })
        .or_else(|| all.first().map(|p| s(p, "id").to_owned()));
    for p in &mut all {
        p["isDefault"] = json!(Some(s(p, "id")) == id.as_deref());
    }
    all
}
fn sanitize_profile<H: Host>(h: &mut H, mut p: Value) -> Result<Value> {
    if let Some(date) = p.get("createdAt").filter(|v| !v.is_null()) {
        if date.is_string() {
            p["createdAt"] = effect(h, "date_parse", json!({"text": date}))?;
        }
    }
    Ok(p)
}
fn mutate<H: Host>(h: &mut H, op: &str, a: &Value) -> Result<Vec<Value>> {
    let mut all = load(h);
    let p = &a["profile"];
    let id = s(a, "id");
    let mut preferred = None;
    match op {
        "add" => {
            let p = sanitize_profile(h, p.clone())?;
            all.retain(|item| {
                !a["replacing"]
                    .as_array()
                    .is_some_and(|ids| ids.contains(&item["id"]))
            });
            if p["isDefault"] == true || !all.iter().any(|item| item["isDefault"] == true) {
                preferred = Some(s(&p, "id").into());
            }
            all.push(p);
        }
        "update" => {
            let p = sanitize_profile(h, p.clone())?;
            let Some(i) = all.iter().position(|v| v["id"] == p["id"]) else {
                return Err(format!("provider_notFound:{}", s(&p, "id")));
            };
            all[i] = p.clone();
            if p["isDefault"] == true {
                preferred = Some(s(&p, "id").into());
            }
        }
        "batch" => {
            preferred = all
                .iter()
                .find(|p| p["isDefault"] == true)
                .map(|p| s(p, "id").into());
            let updates = a["profiles"].as_array().ok_or("invalid_profiles")?;
            for item in updates {
                let p = sanitize_profile(h, item.clone())?;
                let Some(i) = all.iter().position(|v| v["id"] == p["id"]) else {
                    return Err(format!("provider_notFound:{}", s(&p, "id")));
                };
                all[i] = p;
            }
            if updates.is_empty() {
                return Ok(all);
            }
        }
        "delete" => all.retain(|p| s(p, "id") != id),
        "default" => {
            if !all.iter().any(|p| s(p, "id") == id) {
                return Err(format!("provider_notFound:{id}"));
            }
            preferred = Some(id.into());
        }
        _ => return Err("invalid_operation".into()),
    }
    let all = defaults(all, preferred);
    write(h, &all)?;
    Ok(all)
}
fn facts<H: Host>(h: &mut H, url: &str) -> Value {
    effect(h, "url_facts", json!({"text":url})).unwrap_or(Value::Null)
}
fn origin(v: &Value) -> Value {
    let scheme = s(v, "scheme").to_lowercase();
    json!([
        scheme,
        s(v, "host").to_lowercase(),
        v["port"].as_i64().or(match scheme.as_str() {
            "https" => Some(443),
            "http" => Some(80),
            _ => None,
        })
    ])
}
fn replacement<H: Host>(h: &mut H, p: &Value, url: &str, key_empty: bool) -> bool {
    key_empty && origin(&facts(h, s(p, "endpoint"))) != origin(&facts(h, url))
}
fn vendor<H: Host>(h: &mut H, id: &str, url: &str) -> String {
    if id.is_empty() || id == "custom" {
        format!("host:{}", s(&facts(h, url), "host"))
    } else {
        format!("id:{id}")
    }
}
fn workspace<H: Host>(h: &mut H, raw: &str) -> Option<String> {
    let t = trim(raw).to_lowercase();
    if t.is_empty() {
        return None;
    }
    let suffix = ".cn-beijing.maas.aliyuncs.com";
    let host = if t.contains("://") {
        let f = facts(h, &t);
        if s(&f, "scheme") != "https"
            || f["hasUser"] == true
            || f["hasPassword"] == true
            || !f["port"].is_null()
        {
            return None;
        }
        s(&f, "host").to_owned()
    } else {
        if t.contains(['/', '@', ':']) {
            return None;
        }
        if t.contains('.') {
            t
        } else {
            t + suffix
        }
    };
    if !host.starts_with("ws-") || !host.ends_with(suffix) {
        return None;
    }
    let id = &host[..host.len() - suffix.len()];
    (id.len() > 3
        && id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-'))
    .then_some(host)
}
fn prepare_workspace<H: Host>(h: &mut H, raw: &str) -> Option<String> {
    if trim(raw).is_empty() {
        Some(String::new())
    } else {
        workspace(h, raw)
    }
}
fn endpoint(host: &str) -> String {
    if host.is_empty() {
        "https://dashscope.aliyuncs.com/compatible-mode/v1/responses".into()
    } else {
        format!("https://{host}/compatible-mode/v1/responses")
    }
}
fn settle<H: Host>(h: &mut H, staged: &[String], replaced: &[Value], saved: &[Value]) {
    for name in staged {
        let _ = effect(h, "verification_clear", json!({"name":name}));
    }
    for old in replaced {
        if !saved.iter().any(|p| p["secretName"] == old["secretName"]) {
            let _ = effect(h, "secret_delete", json!({"name":old["secretName"]}));
            let _ = effect(h, "verification_clear", json!({"name":old["secretName"]}));
        }
    }
}
enum Commit {
    Clean(Vec<Value>),
    Landed(Vec<Value>),
    Failed,
}
fn commit<H: Host>(
    h: &mut H,
    staging: &[String],
    expected: &[Value],
    replaced: &[Value],
    op: &str,
    args: Value,
) -> Commit {
    let mut staged = vec![];
    for name in staging {
        staged.push(name.clone());
        if effect(h, "secret_write", json!({"name":name,"reference":"typed"})).is_err() {
            for n in &staged {
                let _ = effect(h, "secret_delete", json!({"name":n}));
            }
            return Commit::Failed;
        }
    }
    match mutate(h, op, &args) {
        Ok(saved) => {
            settle(h, &staged, replaced, &saved);
            Commit::Clean(saved)
        }
        Err(_) => {
            let Ok(reread) = read(h) else {
                return Commit::Failed;
            };
            if expected.iter().all(|target| {
                reread.iter().any(|p| {
                    p["id"] == target["id"]
                        && p["endpoint"] == target["endpoint"]
                        && p["secretName"] == target["secretName"]
                })
            }) {
                return Commit::Landed(reread);
            }
            if replaced.iter().all(|old| {
                reread
                    .iter()
                    .find(|p| p["id"] == old["id"])
                    .is_some_and(|p| p["secretName"] == old["secretName"])
            }) && !reread
                .iter()
                .any(|p| staged.iter().any(|n| p["secretName"] == *n))
            {
                for n in &staged {
                    let _ = effect(h, "secret_delete", json!({"name":n}));
                }
            }
            Commit::Failed
        }
    }
}
fn apply_probe<H: Host>(h: &mut H, p: &Value, key_empty: bool) {
    let probe = effect(h, "probe_take", json!({})).unwrap_or(Value::Null);
    if probe.is_null() {
        return;
    }
    let reference = if key_empty {
        effect(h, "secret_read", json!({"name":p["secretName"]})).unwrap_or(Value::Null)
    } else {
        json!("typed")
    };
    if reference.is_null() {
        return;
    }
    if effect(
        h,
        "key_digest",
        json!({"reference":reference,"endpoint":p["endpoint"]}),
    )
    .ok()
        == Some(probe)
    {
        let _ = effect(h, "verification_mark", json!({"name":p["secretName"]}));
    }
}
fn change<H: Host>(h: &mut H, outcome: &str, profile: Value) -> Value {
    json!({"outcome":outcome,"profile":profile,"profiles":sorted(load(h))})
}
pub fn dispatch<H: Host>(h: &mut H, op: &str, a: Value) -> Result<Value> {
    let op = op.strip_prefix("provider_").unwrap_or(op);
    match op {
        "rule" => Ok(crate::provider_wire::rule(s(&a, "rule"), a["args"].clone())),
        "workspaceEndpoint" => Ok(workspace(h, s(&a, "input"))
            .map(|v| json!(endpoint(&v)))
            .unwrap_or(Value::Null)),
        "storedWorkspaceEndpoint" => Ok(json!(endpoint(
            &workspace(h, s(&a, "input")).unwrap_or_default()
        ))),
        "resolvedWorkspace" => Ok(prepare_workspace(h, s(&a, "input"))
            .map(|v| json!(endpoint(&v)))
            .unwrap_or(Value::Null)),
        "load" => Ok(read_file(h).unwrap_or(json!({"schemaVersion":1,"profiles":[]}))),
        "profiles" => Ok(json!(sorted(load(h)))),
        "readable" => Ok(json!(read(h).ok().map(sorted))),
        "defaultProfile" => Ok(load(h)
            .into_iter()
            .find(|p| p["isDefault"] == true)
            .filter(|p| known(&inferred(p)))
            .unwrap_or(Value::Null)),
        "profile" => Ok(load(h)
            .into_iter()
            .find(|p| p["id"] == a["id"])
            .unwrap_or(Value::Null)),
        "add" | "update" | "batch" | "delete" | "default" => Ok(json!(mutate(h, op, &a)?)),
        "workspace" => Ok(json!(workspace(h, s(&a, "input")))),
        "prepareWorkspace" => Ok(json!(prepare_workspace(h, s(&a, "input")))),
        "replacement" => Ok(json!(replacement(
            h,
            &a["profile"],
            s(&a, "endpoint"),
            a["keyEmpty"] == true
        ))),
        "vendor" => Ok(json!(vendor(h, s(&a, "providerID"), s(&a, "endpoint")))),
        "keyState" => {
            let name = &a["profile"]["secretName"];
            let state = match effect(h, "secret_read", json!({"name":name})) {
                Err(_) => "unreadable",
                Ok(v) if v.is_null() => "missing",
                Ok(_) => {
                    if effect(h, "verification_get", json!({"name":name}))?.is_null() {
                        "unverified"
                    } else {
                        "verified"
                    }
                }
            };
            Ok(json!(state))
        }
        "probeKey" => {
            if a["keyEmpty"] != true {
                return Ok(json!({"outcome":"key","reference":"typed"}));
            }
            if a["profile"].is_null() {
                return Ok(json!({"outcome":"missing"}));
            }
            let all = load(h);
            let p = all
                .iter()
                .find(|p| p["id"] == a["profile"]["id"])
                .unwrap_or(&a["profile"]);
            if replacement(h, p, s(&a, "endpoint"), true) {
                return Ok(json!({"outcome":"needsReplacementKey"}));
            }
            let reference =
                effect(h, "secret_read", json!({"name":p["secretName"]})).unwrap_or(Value::Null);
            Ok(
                json!({"outcome":if reference.is_null(){"missing"}else{"key"},"reference":reference}),
            )
        }
        "probeSucceeded" => {
            let digest = effect(
                h,
                "key_digest",
                json!({"reference":"typed","endpoint":a["endpoint"]}),
            )?;
            effect(h, "probe_set", json!({"digest":digest}))?;
            if let Some(p) = load(h)
                .into_iter()
                .find(|p| p["id"] == a["profile"]["id"] && p["endpoint"] == a["endpoint"])
            {
                if let Ok(reference) = effect(h, "secret_read", json!({"name":p["secretName"]})) {
                    if !reference.is_null()
                        && effect(
                            h,
                            "key_digest",
                            json!({"reference":reference,"endpoint":p["endpoint"]}),
                        )
                        .ok()
                            == Some(digest)
                    {
                        effect(h, "verification_mark", json!({"name":p["secretName"]}))?;
                    }
                }
            }
            Ok(json!(true))
        }
        "upsert" => {
            let form = &a["form"];
            let name = trim(s(form, "displayName"));
            if name.is_empty() {
                return Ok(change(h, "blankName", Value::Null));
            }
            let url = trim(s(form, "endpoint"));
            if s(&facts(h, url), "scheme").to_lowercase() != "https" {
                return Ok(change(h, "insecureEndpoint", Value::Null));
            }
            let ws = if s(form, "providerID") == "qwen" && form["qwenWorkspace"].is_string() {
                match prepare_workspace(h, s(form, "qwenWorkspace")) {
                    Some(v) => Some(v),
                    None => return Ok(change(h, "invalidWorkspace", Value::Null)),
                }
            } else {
                None
            };
            let id = storage::uuid(h)?;
            let p = json!({"id":id,"displayName":name,"kind":"openai_compatible","endpoint":facts(h,url)["absolute"],"model":trim(s(form,"model")),"providerID":if s(form,"providerID").is_empty(){Value::Null}else{form["providerID"].clone()},"secretName":secret_name(&id),"isDefault":a["makeDefault"],"createdAt":effect(h,"now",json!({}))?});
            let key_empty = a["keyEmpty"] == true;
            let v = vendor(h, s(form, "providerID"), url);
            let replaced: Vec<_> = sorted(load(h))
                .into_iter()
                .filter(|p| vendor(h, &inferred(p), s(p, "endpoint")) == v)
                .collect();
            let staging = if key_empty {
                vec![]
            } else {
                vec![s(&p, "secretName").into()]
            };
            if let Commit::Clean(saved) = commit(
                h,
                &staging,
                std::slice::from_ref(&p),
                &replaced,
                "add",
                json!({"profile":p,"replacing":replaced.iter().map(|p|p["id"].clone()).collect::<Vec<_>>()}),
            ) {
                let added = saved.into_iter().find(|v| v["id"] == p["id"]).unwrap_or(p);
                if let Some(ws) = ws {
                    effect(h, "workspace_write", json!({"host":ws}))?;
                }
                apply_probe(h, &added, key_empty);
                Ok(change(h, "added", added))
            } else {
                Ok(change(h, "failed", Value::Null))
            }
        }
        "replace" => {
            let Some(current) = load(h).into_iter().find(|p| p["id"] == a["profile"]["id"]) else {
                return Ok(change(h, "failed", Value::Null));
            };
            let url = trim(s(&a, "endpoint"));
            let f = facts(h, url);
            if f.is_null() {
                return Ok(change(h, "insecureEndpoint", Value::Null));
            }
            let empty = a["keyEmpty"] == true;
            if replacement(h, &current, url, empty) {
                return Ok(change(h, "needsReplacementKey", Value::Null));
            }
            if s(&f, "scheme").to_lowercase() != "https" {
                return Ok(change(h, "insecureEndpoint", Value::Null));
            }
            let ws = a["qwenWorkspace"]
                .as_str()
                .and_then(|raw| prepare_workspace(h, raw));
            let mut next = current.clone();
            if !known(&inferred(&current)) {
                next["providerID"] = json!("custom");
            }
            next["endpoint"] = f["absolute"].clone();
            next["model"] = json!(trim(s(&a, "model")));
            let mut staged = vec![];
            if !empty {
                next["secretName"] = json!(secret_name(&storage::uuid(h)?));
                staged.push(s(&next, "secretName").into());
            }
            let replaced = if empty { vec![] } else { vec![current] };
            if let Commit::Clean(_) = commit(
                h,
                &staged,
                std::slice::from_ref(&next),
                &replaced,
                "update",
                json!({"profile":next}),
            ) {
                if let Some(ws) = ws {
                    effect(h, "workspace_write", json!({"host":ws}))?;
                }
                apply_probe(h, &next, empty);
                Ok(change(h, "saved", next))
            } else {
                Ok(change(h, "failed", Value::Null))
            }
        }
        "applyWorkspace" => {
            let Some(ws) = prepare_workspace(h, s(&a, "input")) else {
                return Ok(change(h, "invalidInput", Value::Null));
            };
            let url = endpoint(&ws);
            let Ok(all) = read(h) else {
                return Ok(change(h, "failed", Value::Null));
            };
            let qwen: Vec<_> = all.into_iter().filter(|p| inferred(p) == "qwen").collect();
            if qwen
                .iter()
                .any(|p| replacement(h, p, &url, a["keyEmpty"] == true))
            {
                return Ok(change(h, "needsReplacementKey", Value::Null));
            }
            let changing: Vec<_> = qwen
                .iter()
                .filter(|p| replacement(h, p, &url, true))
                .cloned()
                .collect();
            let mut updated = vec![];
            let mut staging = vec![];
            for mut p in qwen {
                p["endpoint"] = json!(url);
                if changing.iter().any(|old| old["id"] == p["id"]) {
                    p["secretName"] = json!(secret_name(&storage::uuid(h)?));
                    staging.push(s(&p, "secretName").into());
                }
                updated.push(p);
            }
            let saved = match commit(
                h,
                &staging,
                &updated,
                &changing,
                "batch",
                json!({"profiles":updated}),
            ) {
                Commit::Clean(v) => v,
                Commit::Landed(v) => {
                    settle(h, &staging, &changing, &v);
                    v
                }
                Commit::Failed => return Ok(change(h, "failed", Value::Null)),
            };
            effect(h, "workspace_write", json!({"host":ws}))?;
            Ok(json!({"outcome":"saved","cleared":ws.is_empty(),"profiles":sorted(saved)}))
        }
        "setDefault" => {
            if !known(&inferred(&a["profile"])) {
                return Ok(change(h, "needsEdit", Value::Null));
            }
            let result = mutate(h, "default", &json!({"id":a["profile"]["id"]}));
            Ok(change(
                h,
                if result.is_ok() { "set" } else { "failed" },
                a["profile"].clone(),
            ))
        }
        "remove" => {
            if mutate(h, "delete", &json!({"id":a["profile"]["id"]})).is_err() {
                return Ok(change(h, "failed", Value::Null));
            }
            let remaining = load(h);
            settle(h, &[], std::slice::from_ref(&a["profile"]), &remaining);
            Ok(change(h, "deleted", a["profile"].clone()))
        }
        _ => Err("invalid_provider_operation".into()),
    }
}
