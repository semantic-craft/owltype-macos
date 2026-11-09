//! Raycast schema conversion and review decisions, sharing the library and parser owners.
use crate::{storage::*, template, template_library::*, template_transaction as tx};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    pub number: usize,
    pub original_title: String,
    pub original_body: Option<String>,
    pub field_errors: Vec<String>,
    pub unsupported_keys: Vec<String>,
    pub entry: Option<Entry>,
    pub selected: bool,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Preview {
    pub baseline: Library,
    pub rows: Vec<Row>,
}
#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Assessment {
    pub duplicates: BTreeMap<String, String>,
    pub conflicts: BTreeMap<String, Vec<String>>,
    pub selected_indices: Vec<usize>,
    pub pending_count: usize,
}
pub fn fingerprint(s: &ImportSource) -> String {
    let mut bytes = vec![];
    for v in [
        s.version.to_string(),
        s.original_name.clone(),
        s.original_body.clone(),
        s.original_keyword.clone().unwrap_or_default(),
    ] {
        bytes.extend(format!("{}:", v.len()).bytes());
        bytes.extend(v.bytes())
    }
    hash(&bytes)
}
fn parameter(p: template::Parameter) -> Parameter {
    Parameter {
        key: p.key,
        name: p.name,
        is_required: p.is_required,
        default_value: p.default_value,
        options: p.options,
    }
}
pub fn compatibility(e: &Entry) -> Vec<template::Diagnostic> {
    if e.body_type != BodyType::Template {
        return vec![];
    }
    let parsed = e.parsed(false);
    let mut issues = parsed.diagnostics;
    for d in &mut issues {
        if d.message == "未支持的字段将原样插入。" {
            d.message = "含尚未支持的字段，保留待处理，不能执行。".into()
        }
    }
    for p in parsed.parameters.into_iter().filter(|p| p.legacy) {
        issues.push(template::Diagnostic {
            severity: "error".into(),
            range: p.ranges.first().cloned().unwrap_or_default(),
            message: "双花括号与 Owltype 旧参数语法有歧义；请修正，或明确转为普通文本。".into(),
        })
    }
    issues
}
pub fn plain(e: &mut Entry) {
    e.body_type = BodyType::PlainText;
    e.parameters.clear();
    e.review_state = None
}
fn meaning(e: &Entry) -> String {
    let parameters: Vec<_> = e
        .parsed(false)
        .parameters
        .into_iter()
        .map(parameter)
        .collect();
    json!({"title":e.title,"body":e.body,"trigger":e.trigger.as_ref().filter(|v|!v.is_empty()),"bodyType":e.body_type,"syntax":if e.body_type==BodyType::PlainText{Syntax::Standard}else{e.syntax},"parameters":parameters}).to_string()
}
fn row<H: Host>(host: &mut H, v: &Value, number: usize) -> Result<Row> {
    let title = v["name"].as_str();
    let body = v["text"].as_str();
    let keyword = v["keyword"].as_str();
    let mut r = Row {
        id: uuid(host)?,
        number,
        original_title: title
            .map(str::to_owned)
            .unwrap_or(format!("第 {number} 项")),
        original_body: body.map(str::to_owned),
        field_errors: vec![],
        unsupported_keys: vec![],
        entry: None,
        selected: false,
    };
    let Some(object) = v.as_object() else {
        r.field_errors.push("记录必须是对象。".into());
        return Ok(r);
    };
    if title.is_none() {
        r.field_errors.push("name 必须是字符串。".into())
    }
    if body.is_none() {
        r.field_errors.push("text 必须是字符串。".into())
    }
    if object.contains_key("keyword") && keyword.is_none() {
        r.field_errors.push("keyword 必须是字符串或省略。".into())
    }
    r.unsupported_keys = object
        .keys()
        .filter(|k| !["name", "text", "keyword"].contains(&k.as_str()))
        .cloned()
        .collect();
    if let (Some(title), Some(body)) = (title, body) {
        if r.field_errors.is_empty() {
            let mut e = Entry::new(uuid(host)?, title.into(), body.into());
            e.trigger = keyword.filter(|s| !s.is_empty()).map(str::to_owned);
            e.import_source = Some(ImportSource {
                version: 1,
                original_name: title.into(),
                original_body: body.into(),
                original_keyword: keyword.map(str::to_owned),
            });
            e.body_type = BodyType::Template;
            let parsed = e.parsed(false);
            let dynamic = parsed
                .tokens
                .iter()
                .any(|t| !matches!(t.kind, template::Kind::Literal));
            e.parameters = parsed
                .parameters
                .into_iter()
                .map(|p| {
                    let mut p = parameter(p);
                    p.is_required = p.default_value.is_none();
                    p
                })
                .collect();
            if !compatibility(&e).is_empty() {
                e.review_state = Some(Review::Pending)
            } else if !dynamic {
                e.body_type = BodyType::PlainText;
                e.parameters.clear()
            }
            match validate(&Library {
                entries: vec![e.clone()],
                ..Library::default()
            }) {
                Ok(()) => r.entry = Some(e),
                Err(error) => r.field_errors.push(error),
            }
        }
    }
    Ok(r)
}
impl Preview {
    pub fn assessment(&self) -> Assessment {
        let mut result = Assessment::default();
        let mut meanings: BTreeSet<_> = self.baseline.entries.iter().map(meaning).collect();
        let mut sources: BTreeSet<_> = self
            .baseline
            .entries
            .iter()
            .filter_map(|e| e.import_source.as_ref().map(fingerprint))
            .collect();
        for (index, row) in self.rows.iter().enumerate() {
            let Some(e) = &row.entry else { continue };
            let m = meaning(e);
            let s = e.import_source.as_ref().map(fingerprint);
            if meanings.contains(&m) {
                result
                    .duplicates
                    .insert(index.to_string(), "identical".into());
            } else if s.as_ref().is_some_and(|s| sources.contains(s)) {
                result
                    .duplicates
                    .insert(index.to_string(), "alreadyImported".into());
            } else if row.selected {
                result.selected_indices.push(index);
                if e.review_state.is_some() {
                    result.pending_count += 1
                }
                meanings.insert(m);
                if let Some(s) = s {
                    sources.insert(s);
                }
            }
        }
        let active = self.baseline.entries.iter().chain(
            result
                .selected_indices
                .iter()
                .filter_map(|i| self.rows[*i].entry.as_ref()),
        );
        let mut codes: BTreeMap<String, usize> = BTreeMap::new();
        for e in active {
            for code in e
                .trigger
                .iter()
                .chain(&e.candidate_aliases)
                .map(|c| nfc(c))
                .collect::<BTreeSet<_>>()
            {
                *codes.entry(code).or_default() += 1
            }
        }
        for (i, row) in self.rows.iter().enumerate() {
            if result.duplicates.contains_key(&i.to_string()) {
                continue;
            }
            if let Some(trigger) = row
                .entry
                .as_ref()
                .and_then(|e| e.trigger.as_ref())
                .filter(|t| !t.is_empty())
            {
                if codes.get(&nfc(trigger)).copied().unwrap_or(0)
                    > usize::from(result.selected_indices.contains(&i))
                {
                    result
                        .conflicts
                        .insert(i.to_string(), vec![trigger.clone()]);
                }
            }
        }
        result
    }
    pub fn library(&self, a: &Assessment) -> Library {
        let mut l = self.baseline.clone();
        l.entries.extend(
            a.selected_indices
                .iter()
                .filter_map(|i| self.rows[*i].entry.clone()),
        );
        l
    }
    pub fn message(&self, a: &Assessment) -> Option<String> {
        for row in self.rows.iter().filter(|r| r.selected) {
            if !row.field_errors.is_empty() {
                return Some(format!("第 {} 项字段错误，请取消选择。", row.number));
            }
        }
        for i in &a.selected_indices {
            let row = &self.rows[*i];
            if a.conflicts.contains_key(&i.to_string()) {
                return Some(format!(
                    "第 {} 项触发词冲突，请改词、仅搜索或跳过。",
                    row.number
                ));
            }
            if row
                .entry
                .as_ref()
                .is_some_and(|e| e.review_state.is_none() && !compatibility(e).is_empty())
            {
                return Some(format!("第 {} 项语法需要处理。", row.number));
            }
        }
        validate(&self.library(a)).err()
    }
}
pub fn preview<H: Host>(host: &mut H, bytes: &[u8]) -> Result<Preview> {
    let v: Value =
        serde_json::from_slice(bytes).map_err(|_| "JSON 无法读取，请保留原文件并检查格式。")?;
    let objects = v.as_array().ok_or("Raycast 基础 JSON 须为条目数组。")?;
    let baseline = tx::current(host)?;
    let mut rows = vec![];
    for (i, v) in objects.iter().enumerate() {
        let mut r = row(host, v, i + 1)?;
        r.selected = r.entry.as_ref().is_some_and(|e| e.review_state.is_none());
        rows.push(r)
    }
    let mut preview = Preview { baseline, rows };
    let a = preview.assessment();
    for index in a.duplicates.keys() {
        preview.rows[index.parse::<usize>().unwrap()].selected = false
    }
    Ok(preview)
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "import_fingerprint" => Ok(json!(fingerprint(&decode(args["source"].clone())?))),
        "import_preview" => {
            let bytes: Vec<u8> = decode(args["bytes"].clone())?;
            Ok(json!(preview(host, &bytes)?))
        }
        "import_assessment" => {
            let p: Preview = decode(args["preview"].clone())?;
            Ok(json!(p.assessment()))
        }
        "import_library" => {
            let p: Preview = decode(args["preview"].clone())?;
            Ok(json!(p.library(&p.assessment())))
        }
        "import_message" => {
            let p: Preview = decode(args["preview"].clone())?;
            Ok(json!({"message":p.message(&p.assessment())}))
        }
        "import_compatibility" => {
            let e: Entry = decode(args["entry"].clone())?;
            Ok(json!(compatibility(&e)))
        }
        "import_plain" => {
            let mut e: Entry = decode(args["entry"].clone())?;
            plain(&mut e);
            Ok(json!(e))
        }
        "import_enable" => {
            let mut e: Entry = decode(args["entry"].clone())?;
            let mut enabled = false;
            if e.body_type == BodyType::Template {
                let mut inline = e.clone();
                inline.parameters.clear();
                let parsed = inline.parsed(false);
                let keys: BTreeSet<_> = parsed.parameters.iter().map(|p| nfc(&p.key)).collect();
                e.parameters.retain(|p| keys.contains(&nfc(&p.key)));
                for p in parsed.parameters {
                    if !e.parameters.iter().any(|v| nfc(&v.key) == nfc(&p.key)) {
                        let mut p = parameter(p);
                        p.is_required = p.default_value.is_none();
                        e.parameters.push(p)
                    }
                }
                if compatibility(&e).is_empty() {
                    enabled = true;
                    e.review_state = None
                }
            }
            Ok(json!({"enabled":enabled,"entry":e}))
        }
        "import_change" => {
            let mut p: Preview = decode(args["preview"].clone())?;
            let i = args["index"].as_u64().ok_or("invalid_payload")? as usize;
            let r = p.rows.get_mut(i).ok_or("invalid_payload")?;
            if let Some(e) = &mut r.entry {
                match args["action"].as_str() {
                    Some("plain") => {
                        plain(e);
                        r.selected = true
                    }
                    Some("search") => {
                        e.trigger = None;
                        e.candidate_aliases.clear();
                        e.invocation_mode = Invocation::SearchOnly
                    }
                    _ => {
                        let trigger = args["trigger"].as_str().unwrap_or("");
                        e.trigger = if trigger.is_empty() {
                            None
                        } else {
                            Some(trigger.into())
                        };
                        e.candidate_aliases.clear();
                        if trigger.is_empty() {
                            e.invocation_mode = Invocation::SearchOnly
                        }
                    }
                }
            }
            Ok(json!(p))
        }
        "import_commit" => {
            let p: Preview = decode(args["preview"].clone())?;
            let a = p.assessment();
            if let Some(message) = p.message(&a) {
                return Err(message);
            }
            locked(host, |host| {
                let existing = tx::load_unlocked(host)?;
                if !same(&existing, &p.baseline) {
                    return Err("changed_on_disk".into());
                }
                let next = p.library(&a);
                if !same(&next, &p.baseline) {
                    tx::save_unlocked(host, &next, None)?;
                }
                Ok(json!(next))
            })
        }
        _ => Err("unknown_operation".into()),
    }
}
