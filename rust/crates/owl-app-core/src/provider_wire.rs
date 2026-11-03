//! Provider protocol decisions. All inputs are explicit AI calls; this module does no I/O.
use crate::foundation_text::{trim, trim_spaces};
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;

pub fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
fn nonempty(v: &Value) -> Option<&str> {
    v.as_str().filter(|v| !v.is_empty())
}
pub fn dialect(id: &str, model: &str, host: &str) -> Option<&'static str> {
    let (id, m, h) = (id.to_lowercase(), model.to_lowercase(), host.to_lowercase());
    if id == "qwen" || h.contains("dashscope") || h.contains("aliyuncs") {
        Some("qwen")
    } else if m.starts_with("doubao")
        && (id == "doubao" || h.contains("volces") || h.contains("volcengine"))
    {
        Some("ark")
    } else if (m == "deepseek-flash" || m.starts_with("deepseek-v4-flash"))
        && (id == "deepseek" || h.contains("deepseek"))
    {
        Some("deepseek")
    } else {
        None
    }
}
pub fn thinking(id: &str, model: &str) -> Value {
    let (id, m) = (id.to_lowercase(), model.to_lowercase());
    match id.as_str() {
        "deepseek" | "doubao" => return json!({"thinking":{"type":"disabled"}}),
        "qwen" => return json!({"enable_thinking":false}),
        "openai" | "gemini" => return json!({}),
        _ => {}
    }
    if m == "minimax-m3.1-flash" || m == "minimax-m3.1-flash-preview" {
        json!({"reasoning_effort":"low","reasoning_split":true})
    } else if m == "minimax-m3" {
        json!({"thinking":{"type":"disabled"},"reasoning_split":true})
    } else if m.starts_with("minimax-m2") {
        json!({"reasoning_split":true})
    } else if m.starts_with("deepseek") || m.starts_with("doubao") {
        json!({"thinking":{"type":"disabled"}})
    } else if m.starts_with("qwen") {
        json!({"enable_thinking":false})
    } else {
        json!({})
    }
}
pub fn input(role: &str, text: &str, d: &str) -> Value {
    if d == "qwen" {
        json!({"role":role,"content":text})
    } else {
        json!({"role":role,"content":[{"type":"input_text","text":text}]})
    }
}
pub fn body(a: &Value) -> Value {
    let d = s(a, "dialect");
    let messages = a["messages"].as_array().cloned().unwrap_or_default();
    let mut out = json!({"model":a["model"],"input":messages.iter().map(|m|input(s(m,"role"),s(m,"content"),d)).collect::<Vec<_>>(),"stream":a["stream"]});
    if !a["temperature"].is_null() {
        out["temperature"] = a["temperature"].clone();
    }
    let search = a["webSearch"] == true;
    match d {
        "qwen" => {
            out["store"] = json!(false);
            out["reasoning"] = json!({"effort":"none"});
            if search {
                out["tools"] = json!([{"type":"web_search"}]);
                out["tool_choice"] = json!("required");
            }
        }
        "ark" => {
            out["store"] = json!(false);
            out["thinking"] = json!({"type":"disabled"});
            if search {
                out["tools"] = json!([{"type":"web_search","max_keyword":2,"limit":3}]);
                out["max_tool_calls"] = json!(3);
            }
        }
        "openAI" => {
            if search {
                out["tools"] = json!([{"type":"web_search"}]);
            }
        }
        "deepseek" => {
            if search {
                out["tools"] = json!([{"type":"web_search"}]);
                out["tool_choice"] = json!("required");
            } else {
                out["reasoning"] = json!({"effort":"none"});
            }
            if a["jsonObject"] == true {
                out["text"] = json!({"format":{"type":"json_object"}});
            }
        }
        _ => {}
    }
    out
}
pub fn error_detail(root: &Value) -> Value {
    let r = if root.is_array() { &root[0] } else { root };
    if !r.is_object() {
        return Value::Null;
    }
    let f = if r["error"].is_object() {
        &r["error"]
    } else {
        r
    };
    let code = [&f["code"], &f["status"], &f["type"]]
        .into_iter()
        .find_map(nonempty);
    let message = nonempty(&f["message"]).or_else(|| nonempty(&r["error"]));
    if code.is_none() && message.is_none() {
        Value::Null
    } else {
        json!({"code":code,"message":message})
    }
}
fn collect_sources(v: &Value, out: &mut Vec<Value>) {
    if let Some(m) = v.as_object() {
        if let Some(url) = ["url", "link", "source_url", "uri"]
            .iter()
            .find_map(|k| m.get(*k))
            .and_then(Value::as_str)
            .filter(|u| u.starts_with("http"))
        {
            if !out.iter().any(|v| s(v, "url") == url) {
                let title = ["title", "name", "site_name"]
                    .iter()
                    .find_map(|k| m.get(*k))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                out.push(json!({"url":url,"title":title}));
            }
        }
        for child in m.values() {
            collect_sources(child, out);
        }
    } else if let Some(a) = v.as_array() {
        for child in a {
            collect_sources(child, out);
        }
    }
}
pub fn responses(root: &Value) -> Value {
    let text = nonempty(&root["output_text"])
        .map(str::to_owned)
        .unwrap_or_else(|| {
            root["output"]
                .as_array()
                .filter(|rows| rows.iter().all(Value::is_object))
                .into_iter()
                .flatten()
                .filter(|v| s(v, "type") == "message")
                .flat_map(|v| {
                    v["content"]
                        .as_array()
                        .filter(|rows| rows.iter().all(Value::is_object))
                        .into_iter()
                        .flatten()
                })
                .filter(|v| s(v, "type") == "output_text")
                .map(|v| s(v, "text"))
                .collect()
        });
    let raw = &root["usage"];
    let n = |key: &str| raw[key].as_i64().unwrap_or(0);
    let usage = if raw.is_object() {
        json!({"inputTokens":n("input_tokens"),"outputTokens":n("output_tokens"),"totalTokens":raw["total_tokens"].as_i64().unwrap_or(n("input_tokens")+n("output_tokens")),"cachedTokens":raw["input_tokens_details"]["cached_tokens"].as_i64().unwrap_or(0)})
    } else {
        Value::Null
    };
    let mut sources = vec![];
    collect_sources(root, &mut sources);
    json!({"text":trim(&text),"model":root["model"].as_str(),"usage":usage,"sources":sources})
}
pub fn refusal(code: &str) -> Option<&'static str> {
    match code.to_lowercase().as_str() {
        "invalidapikey" | "invalid_api_key" | "authenticationerror" | "authentication" => {
            Some("invalidKey")
        }
        "modelnotfound"
        | "model_not_found"
        | "model_not_supported"
        | "modelnotopen"
        | "invalidendpointormodel.notfound"
        | "invalidendpointormodel.modelidaccessdisabled" => Some("modelUnavailable"),
        "arrearage"
        | "accountoverdueerror"
        | "operationdenied.serviceoverdue"
        | "credit_balance_exhausted"
        | "payment_required" => Some("insufficientBalance"),
        "allocationquota.freetieronly"
        | "quotaexceeded"
        | "setlimitexceeded"
        | "quota_exceeded" => Some("quotaExhausted"),
        "throttling.ratequota"
        | "limit_requests"
        | "throttling.burstrate"
        | "ratelimitexceeded.endpointrpmexceeded"
        | "ratelimitexceeded.endpointtpmexceeded"
        | "rate_limit_exceeded"
        | "too_many_requests"
        | "slow_down" => Some("rateLimited"),
        "datainspectionfailed"
        | "data_inspection_failed"
        | "sensitivecontentdetected"
        | "inputtextsensitivecontentdetected"
        | "outputtextsensitivecontentdetected"
        | "inputtextriskdetection" => Some("contentBlocked"),
        _ => None,
    }
}
fn refusal_message(kind: &str) -> &'static str {
    match kind {
        "invalidKey" => "云端 AI 的 API Key 无效",
        "modelUnavailable" => "云端 AI 不提供这个型号，检查供应商档案里的型号",
        "insufficientBalance" => "云端 AI 账户余额不足",
        "quotaExhausted" => "云端 AI 的用量额度已用完",
        "rateLimited" => "云端 AI 请求过于频繁，请稍后再试",
        "contentBlocked" => "云端 AI 的内容审核拦下了这次请求",
        _ => "云端 AI 请求失败",
    }
}
pub fn rule(op: &str, a: Value) -> Value {
    match op {
        "curatedModels" => {
            let catalog: Value =
                serde_json::from_str(include_str!("provider_catalog.json")).expect("catalog");
            let mut values = match s(&a, "providerID") {
                "deepseek" => vec![json!("deepseek-flash"), json!("deepseek-v4-pro")],
                "qwen" => catalog["qwenModels"].as_array().unwrap().clone(),
                "grok" => catalog["grokModels"].as_array().unwrap().clone(),
                "minimax" => catalog["minimaxModels"].as_array().unwrap().clone(),
                id => catalog["presets"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|p| s(p, "id") == id)
                    .map(|p| vec![p["model"].clone()])
                    .unwrap_or_default(),
            };
            if !s(&a, "current").is_empty() {
                values.retain(|v| v != &a["current"]);
                values.insert(0, a["current"].clone());
            }
            json!(values)
        }

        "routing" => {
            let p = &a["profile"];
            json!({"providerID":crate::provider_store::inferred(p),"endpoint":if p.is_null(){&a["legacyEndpoint"]}else{&p["endpoint"]},"model":if s(p,"model").is_empty(){&a["legacyModel"]}else{&p["model"]},"secretName":p["secretName"],"authHeaderStyle":"bearer"})
        }
        "authPlan" => {
            json!({"source":if a["secretName"].is_string(){"profile"}else if a["hasLegacy"]==true{"legacy"}else{"none"},"missing":if a["hasProfile"]==true{"missingKey"}else{"unconfigured"}})
        }
        "authKey" => json!(trim(s(&a, "key"))),
        "canonicalModel" => json!(match trim(s(&a, "model")) {
            "" | "deepseek-chat" => "deepseek-flash",
            "deepseek-reasoner" => "deepseek-v4-pro",
            v => v,
        }),
        "modelsURL" => {
            let endpoint = s(&a, "endpoint");
            json!(endpoint
                .rfind("/chat/completions")
                .map(|i| (i, 17))
                .or_else(|| endpoint.rfind("/audio/transcriptions").map(|i| (i, 21)))
                .map(|(i, len)| {
                    let mut x = endpoint.to_owned();
                    x.replace_range(i..i + len, "/models");
                    x
                }))
        }
        "modelsParse" => {
            let bytes: Vec<u8> = serde_json::from_value(a["bytes"].clone()).unwrap_or_default();
            let root: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let mut out = vec![];
            if let Some(rows) = root["data"].as_array() {
                if rows.iter().all(|p| p["id"].is_string()) {
                    for p in rows {
                        if !s(p, "id").is_empty() && !out.contains(&p["id"]) {
                            out.push(p["id"].clone());
                        }
                    }
                }
            }
            json!(out)
        }
        "modelsMerge" => {
            let mut out = vec![];
            for v in a["values"].as_array().into_iter().flatten() {
                if v.as_str().is_some_and(|s| !s.is_empty()) && !out.contains(v) {
                    out.push(v.clone());
                }
            }
            json!(out)
        }
        "probeOutcome" => {
            let status = a["status"].as_i64();
            let bytes: Vec<u8> = serde_json::from_value(a["bytes"].clone()).unwrap_or_default();
            let root: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            if status.is_none() {
                json!({"kind":"malformed"})
            } else if !(200..=299).contains(&status.unwrap()) {
                json!({"kind":"rejected","detail":error_detail(&root)})
            } else {
                json!({"kind":if root.get("choices").is_some()||root.get("output").is_some(){"ok"}else{"malformed"}})
            }
        }
        "completionParse" => {
            let bytes: Vec<u8> = serde_json::from_value(a["bytes"].clone()).unwrap_or_default();
            let root: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let status = a["status"].as_i64().unwrap_or(200);
            if !(200..=299).contains(&status) {
                return json!({"error":"http","detail":error_detail(&root)});
            }
            if !root.is_object() {
                return json!({"error":"malformed"});
            }
            let d = a["responses"] == true;
            let r = if d { responses(&root) } else { root.clone() };
            let text = if d {
                r["text"].as_str()
            } else {
                r["choices"][0]["message"]["content"].as_str()
            };
            if !d
                && (!r["choices"].is_array()
                    || r["choices"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|c| !c["message"]["content"].is_string()))
            {
                return json!({"error":"malformed"});
            }
            let u = &r["usage"];
            let n = |key: &str| u[key].as_i64().unwrap_or(0);
            let model = r["model"].as_str().unwrap_or(s(&a, "model"));
            if !d
                && !u.is_null()
                && (!u.is_object()
                    || ["completion_tokens", "prompt_tokens", "total_tokens"]
                        .iter()
                        .any(|k| !u[*k].is_i64()))
            {
                return json!({"error":"malformed"});
            }
            let usage = if u.is_object() {
                if d {
                    json!({"model":model,"completionTokens":n("outputTokens"),"promptTokens":n("inputTokens"),"promptCacheHitTokens":n("cachedTokens"),"promptCacheMissTokens":(n("inputTokens")-n("cachedTokens")).max(0),"totalTokens":n("totalTokens")})
                } else {
                    json!({"model":model,"completionTokens":n("completion_tokens"),"promptTokens":n("prompt_tokens"),"promptCacheHitTokens":n("prompt_cache_hit_tokens"),"promptCacheMissTokens":n("prompt_cache_miss_tokens"),"totalTokens":n("total_tokens")})
                }
            } else {
                Value::Null
            };
            json!({"text":text,"usage":usage,"error":if text.is_none()||(d&&text==Some("")){Some("empty")}else{None}})
        }
        "catalog" => serde_json::from_str(include_str!("provider_catalog.json"))
            .expect("checked provider catalog"),
        "profileDefaults" => {
            crate::provider_store::normalize(a["profile"].clone()).unwrap_or(Value::Null)
        }
        "secretName" => json!(crate::provider_store::secret_name(s(&a, "id"))),
        "isHTTPS" => json!(s(&a, "scheme").to_lowercase() == "https"),
        "vendorKey" => json!(
            if s(&a, "providerID").is_empty() || s(&a, "providerID") == "custom" {
                format!("host:{}", s(&a, "host"))
            } else {
                format!("id:{}", s(&a, "providerID"))
            }
        ),
        "numberedRewrite" => {
            let text = trim(s(&a, "text"));
            let root: Value = serde_json::from_str(text).unwrap_or(Value::Null);
            let values = if root
                .as_array()
                .is_some_and(|v| v.iter().all(Value::is_string))
            {
                root.as_array()
                    .unwrap()
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            } else if root["candidates"]
                .as_array()
                .is_some_and(|v| v.iter().all(Value::is_string))
            {
                root["candidates"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            } else if text.starts_with(['[', '{']) {
                vec![]
            } else {
                crate::foundation_text::lines(text)
                    .map(|v| {
                        v.trim_matches(|c| "-*0123456789.、 \t".contains(c))
                            .to_owned()
                    })
                    .collect()
            };
            let mut out = vec![];
            let mut seen = std::collections::HashSet::new();
            for v in values {
                let t = trim(&v);
                let n = icu_normalizer::ComposingNormalizer::new_nfc()
                    .normalize(t)
                    .into_owned();
                if !t.is_empty() && seen.insert(n) {
                    out.push(t.to_owned());
                }
            }
            json!(out)
        }
        "searchPath" => json!("/v1/tools/search"),
        "withoutFragment" => json!(s(&a, "url").split('#').next().unwrap_or("")),
        "jsonMode" => json!(a["hasSplit"] != true),
        "formProvider" => {
            let id = crate::provider_store::inferred(&a["profile"]);
            json!(if crate::provider_store::known(&id) {
                id
            } else {
                "custom".into()
            })
        }
        "trim" => json!(trim(s(&a, "text"))),
        "known" => json!(crate::provider_store::known(s(&a, "id"))),
        "inferred" => json!(crate::provider_store::inferred(&a["profile"])),
        "dialect" => json!(dialect(s(&a, "providerID"), s(&a, "model"), s(&a, "host"))),
        "thinking" => thinking(s(&a, "providerID"), s(&a, "model")),
        "temperature" => {
            if s(&a, "model").to_lowercase() == "gemini-3.8-flash" {
                Value::Null
            } else {
                a["value"].clone()
            }
        }
        "searchChannel" => json!(if s(&a, "providerID").to_lowercase() == "deepseek"
            || s(&a, "host").to_lowercase().contains("deepseek")
        {
            "deepSeek"
        } else {
            "none"
        }),
        "responsesBody" => body(&a),
        "input" => input(s(&a, "role"), s(&a, "text"), s(&a, "dialect")),
        "responsesPath" => {
            let p = s(&a, "path");
            json!(if let Some(base) = p.strip_suffix("/chat/completions") {
                format!("{base}/responses")
            } else if p.ends_with("/responses") {
                p.to_owned()
            } else {
                format!(
                    "{}responses",
                    if p.ends_with('/') {
                        p.to_owned()
                    } else {
                        format!("{p}/")
                    }
                )
            })
        }
        "responsesParse" => {
            let bytes: Vec<u8> = serde_json::from_value(a["bytes"].clone()).unwrap_or_default();
            let root = serde_json::from_slice::<Value>(&bytes)
                .ok()
                .filter(Value::is_object);
            root.as_ref().map(responses).unwrap_or(Value::Null)
        }
        "errorDetail" => {
            let bytes: Vec<u8> = serde_json::from_value(a["bytes"].clone()).unwrap_or_default();
            error_detail(&serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null))
        }
        "refusal" => json!(refusal(s(&a, "code"))),
        "refusalMessage" => json!(refusal_message(s(&a, "kind"))),
        "errorMessage" => {
            if let Some(kind) = refusal(s(&a, "code")) {
                return json!(refusal_message(kind));
            }
            let status = a["status"].as_i64().unwrap_or(0);
            json!(match status {
                0 => "云端 AI 请求失败".to_owned(),
                400 => "云端 AI 拒绝了此请求".into(),
                401 => refusal_message("invalidKey").into(),
                402 => refusal_message("insufficientBalance").into(),
                403 => "云端 AI 拒绝访问，检查 API Key 的权限".into(),
                404 => "云端 AI 找不到这个型号或端点".into(),
                422 => "云端 AI 不支持的请求格式".into(),
                429 => refusal_message("rateLimited").into(),
                500 => "云端 AI 服务器错误，请稍后重试".into(),
                503 => "云端 AI 服务繁忙，请稍后重试".into(),
                _ => format!("云端 AI 请求失败（{status}）"),
            })
        }
        "sanitize" => {
            let mut t = s(&a, "message").to_owned();
            let key = s(&a, "key");
            if key.graphemes(true).count() >= 8 {
                t = t.replace(key, "***");
            }
            let regex =
                regex::Regex::new(r"(?i)\b(sk|ak|key)-[A-Za-z0-9*._-]{4,}").expect("fixed regex");
            t = regex.replace_all(&t, "***").into_owned();
            t = t.split_whitespace().collect::<Vec<_>>().join(" ");
            let limit = a["limit"].as_u64().unwrap_or(160) as usize;
            json!(if t.graphemes(true).count() > limit {
                t.graphemes(true).take(limit).collect::<String>() + "…"
            } else {
                t
            })
        }
        "retry" => json!(
            matches!(s(&a, "kind"), "empty" | "timeout" | "connectionLost")
                || (s(&a, "kind") == "http" && matches!(a["status"].as_i64(), Some(500 | 503)))
        ),
        "purpose" => json!(match s(&a, "purpose") {
            "interactiveRewrite" => json!({"timeout":8,"maxAttempts":2}),
            "drafting" => json!({"timeout":60,"maxAttempts":1}),
            _ => json!({"timeout":20,"maxAttempts":1}),
        }),
        "chatBody" => {
            let mut out = json!({"model":a["model"],"messages":a["messages"],"stream":a["stream"]});
            for (field, wire) in [
                ("temperature", "temperature"),
                ("responseFormat", "response_format"),
                ("thinking", "thinking"),
                ("enableThinking", "enable_thinking"),
                ("reasoningEffort", "reasoning_effort"),
                ("reasoningSplit", "reasoning_split"),
            ] {
                if !a[field].is_null() {
                    out[wire] = a[field].clone();
                }
            }
            out
        }
        "httpAccepted" => json!((200..=299).contains(&a["status"].as_i64().unwrap_or(0))),
        "retryDelay" => json!(400_000_000u64),
        "chatStreamPlan" => {
            let foundation_encoding = !thinking(s(&a, "providerID"), s(&a, "model"))
                .as_object()
                .unwrap()
                .is_empty();
            json!({"body":rule("chatStreamBody",a),"foundationEncoding":foundation_encoding})
        }
        "chatStreamBody" => {
            let mut out = json!({"model":a["model"],"messages":a["messages"],"stream":true});
            if s(&a, "model").to_lowercase() != "gemini-3.8-flash" {
                out["temperature"] = json!(0.2);
            }
            out.as_object_mut().unwrap().extend(
                thinking(s(&a, "providerID"), s(&a, "model"))
                    .as_object()
                    .unwrap()
                    .clone(),
            );
            out
        }
        "probeBody" => {
            if let Some(d) = dialect(s(&a, "providerID"), s(&a, "model"), s(&a, "host")) {
                return body(
                    &json!({"dialect":d,"model":a["model"],"messages":[{"role":"user","content":"ping"}],"stream":false}),
                );
            }
            let mut out = json!({"model":a["model"],"messages":[{"role":"user","content":"ping"}],"stream":false,"max_tokens":if s(&a,"model").to_lowercase()=="gemini-3.8-flash"{1024}else{16}});
            let extra = thinking(s(&a, "providerID"), s(&a, "model"));
            if !extra["reasoning_split"].is_null() {
                out.as_object_mut().unwrap().remove("max_tokens");
                out["max_completion_tokens"] = json!(if extra["thinking"].is_null() {
                    4096
                } else {
                    16
                });
            }
            out.as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            out
        }
        _ => crate::provider_search::rule(op, &a),
    }
}

/// One owned byte-stream parser. A UTF-8 scalar may cross any chunk boundary.
#[derive(Default)]
pub struct Stream {
    buffer: Vec<u8>,
    finished: bool,
    failure: Option<String>,
    responses: bool,
}
impl Stream {
    pub fn new(responses: bool) -> Self {
        Self {
            responses,
            ..Self::default()
        }
    }
    pub fn event(&mut self, event: &str, a: Value) -> Result<Value, String> {
        let mut deltas = vec![];
        if event == "cancel" {
            self.finished = true;
            self.buffer.clear();
        }
        if !self.finished {
            if event == "consume" {
                let bytes: Vec<u8> =
                    serde_json::from_value(a["bytes"].clone()).map_err(|_| "invalid_bytes")?;
                self.buffer.extend(bytes);
            }
            while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
                let line = self.buffer.drain(..=end).collect::<Vec<_>>();
                if let Some(d) = self.line(&line[..end]) {
                    deltas.push(d);
                }
                if self.finished {
                    self.buffer.clear();
                    break;
                }
            }
            if event == "finish" {
                let tail = std::mem::take(&mut self.buffer);
                if let Some(d) = self.line(&tail) {
                    deltas.push(d);
                }
            }
        }
        Ok(json!({"deltas":deltas,"isFinished":self.finished,"failure":self.failure}))
    }
    fn line(&mut self, bytes: &[u8]) -> Option<String> {
        let line = std::str::from_utf8(bytes)
            .ok()?
            .strip_suffix('\r')
            .unwrap_or(std::str::from_utf8(bytes).ok()?);
        let payload = trim_spaces(line).strip_prefix("data:")?;
        let payload = payload.strip_prefix(' ').unwrap_or(payload);
        if payload == "[DONE]" {
            self.finished = true;
            return None;
        }
        let object: Value = serde_json::from_str(payload).ok()?;
        if !self.responses {
            return nonempty(&object["choices"][0]["delta"]["content"]).map(str::to_owned);
        }
        match s(&object, "type") {
            "response.output_text.delta" => nonempty(&object["delta"]).map(str::to_owned),
            "response.completed" | "response.incomplete" => {
                self.finished = true;
                None
            }
            "response.failed" | "error" => {
                self.finished = true;
                self.failure = Some(
                    object["response"]["error"]["message"]
                        .as_str()
                        .or_else(|| object["error"]["message"].as_str())
                        .or_else(|| object["error"].as_str())
                        .unwrap_or("stream error")
                        .to_owned(),
                );
                None
            }
            _ => None,
        }
    }
}
