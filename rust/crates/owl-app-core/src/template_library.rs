//! The shared template model, validation and indexes. All UI and Agent consumers cross
//! this module. Foundation supplies comparison facts, never business ordering policy.
use crate::foundation_text::{is_whitespace_and_newline, trim};
use crate::{storage::*, template};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
pub const FILE: &str = "owl_templates.json";
pub fn nfc(s: &str) -> String {
    icu_normalizer::ComposingNormalizer::new_nfc()
        .normalize(s)
        .into_owned()
}
pub fn valid_id(value: &str) -> bool {
    regex::Regex::new(r"^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$")
        .unwrap()
        .is_match(value)
}
pub fn decode_id<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<String, D::Error> {
    let value = String::deserialize(decoder)?;
    if !valid_id(&value) {
        return Err(serde::de::Error::custom("invalid UUID"));
    }
    Ok(value.to_uppercase())
}
pub fn decode_optional_id<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Option<String>, D::Error> {
    let value = Option::<String>::deserialize(decoder)?;
    if value.as_ref().is_some_and(|v| !valid_id(v)) {
        return Err(serde::de::Error::custom("invalid UUID"));
    }
    Ok(value.map(|v| v.to_uppercase()))
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Parameter {
    pub key: String,
    pub name: String,
    pub is_required: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_value: Option<String>,
    pub options: Vec<String>,
}
impl Parameter {
    pub fn parser(&self) -> template::Parameter {
        template::Parameter {
            key: self.key.clone(),
            name: self.name.clone(),
            is_required: self.is_required,
            default_value: self.default_value.clone(),
            options: self.options.clone(),
            legacy: false,
            ranges: vec![],
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportSource {
    pub version: u32,
    pub original_name: String,
    pub original_body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_keyword: Option<String>,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BodyType {
    PlainText,
    Template,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Syntax {
    Standard,
    LegacyDoubleBraces,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    General,
    Prompt,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Invocation {
    SearchOnly,
    Candidate,
    Automatic,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Expansion {
    Immediate,
    DelimiterKeep,
    DelimiterDrop,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Review {
    Pending,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    #[serde(deserialize_with = "decode_id")]
    pub id: String,
    pub title: String,
    pub body: String,
    pub body_type: BodyType,
    pub syntax: Syntax,
    pub candidate_aliases: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger: Option<String>,
    pub tags: Vec<String>,
    pub is_pinned: bool,
    pub category: Category,
    pub parameters: Vec<Parameter>,
    pub invocation_mode: Invocation,
    pub expansion_mode: Expansion,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub import_source: Option<ImportSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub review_state: Option<Review>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exposed_to_agents: Option<bool>,
}
impl Entry {
    pub fn new(id: String, title: String, body: String) -> Self {
        Self {
            id,
            title,
            body,
            body_type: BodyType::PlainText,
            syntax: Syntax::Standard,
            candidate_aliases: vec![],
            trigger: None,
            tags: vec![],
            is_pinned: false,
            category: Category::General,
            parameters: vec![],
            invocation_mode: Invocation::SearchOnly,
            expansion_mode: Expansion::DelimiterDrop,
            import_source: None,
            review_state: None,
            exposed_to_agents: None,
        }
    }
    pub fn duplicated(self, new_id: String) -> Self {
        let mut copy = Self::new(new_id, self.title + " 副本", self.body);
        copy.body_type = self.body_type;
        copy.syntax = self.syntax;
        copy.tags = self.tags;
        copy.is_pinned = self.is_pinned;
        copy.category = self.category;
        copy.parameters = self.parameters;
        copy.review_state = self.review_state;
        copy
    }
    pub fn parsed(&self, review: bool) -> template::Parsed {
        template::parse(
            &self.body,
            self.body_type == BodyType::PlainText,
            self.syntax == Syntax::LegacyDoubleBraces,
            review && self.review_state.is_some(),
            self.parameters.iter().map(Parameter::parser).collect(),
        )
    }
    pub fn execution_issue(&self) -> Option<String> {
        self.parsed(true)
            .diagnostics
            .into_iter()
            .find(|d| d.severity == "error")
            .map(|d| d.message)
    }
    pub fn candidate(&self) -> String {
        format!("🦉[{}]{}", self.id.to_uppercase(), self.title)
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub format_version: u32,
    pub entries: Vec<Entry>,
}
impl Default for Library {
    fn default() -> Self {
        Self {
            format_version: 1,
            entries: vec![],
        }
    }
}
pub fn code_valid(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 32
        && b[0].is_ascii_lowercase()
        && b.iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}
pub fn automatic_valid(s: &str) -> bool {
    s.starts_with(";;")
        && s.len() > 2
        && s.as_bytes()[2..]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}
#[derive(Clone, Default, Serialize)]
pub struct AutomaticNode {
    pub(crate) children: BTreeMap<String, usize>,
    pub(crate) entry: Option<Entry>,
}
pub fn automatic_index(entries: &[Entry]) -> Result<Vec<AutomaticNode>> {
    let mut nodes = vec![AutomaticNode::default()];
    for e in entries
        .iter()
        .filter(|e| e.invocation_mode == Invocation::Automatic && e.review_state.is_none())
    {
        let trigger = e
            .trigger
            .as_deref()
            .filter(|s| automatic_valid(s))
            .ok_or("automatic_invalid")?;
        if let Some(issue) = e.execution_issue() {
            return Err(format!("automatic_template:{issue}"));
        }
        let mut cursor = 0;
        for byte in trigger.bytes() {
            if nodes[cursor]
                .entry
                .as_ref()
                .is_some_and(|e| e.expansion_mode == Expansion::Immediate)
            {
                return Err("automatic_prefix".into());
            }
            let key = byte.to_string();
            if let Some(next) = nodes[cursor].children.get(&key) {
                cursor = *next
            } else {
                let next = nodes.len();
                nodes.push(AutomaticNode::default());
                nodes[cursor].children.insert(key, next);
                cursor = next
            }
        }
        if nodes[cursor].entry.is_some() {
            return Err("automatic_duplicate".into());
        }
        if e.expansion_mode == Expansion::Immediate && !nodes[cursor].children.is_empty() {
            return Err("automatic_prefix".into());
        }
        nodes[cursor].entry = Some(e.clone());
    }
    Ok(nodes)
}
pub fn automatic_validate(entries: &[Entry]) -> Result<()> {
    automatic_index(entries).map(|_| ())
}
pub fn validate(library: &Library) -> Result<()> {
    if library.format_version != 1 {
        return Err("不支持的模板库版本。".into());
    }
    let mut ids = BTreeSet::new();
    let mut triggers = BTreeSet::new();
    for e in &library.entries {
        if !valid_id(&e.id) {
            return Err("invalid_uuid".into());
        }
        if !ids.insert(e.id.to_uppercase()) {
            return Err("条目 ID 重复。".into());
        }
        if trim(&e.title).is_empty()
            || e.title.chars().any(|c| {
                [
                    '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}', '\t',
                ]
                .contains(&c)
            })
        {
            return Err("标题不能为空，且不能包含换行或 Tab。".into());
        }
        if trim(&e.body).is_empty() {
            return Err("正文不能全部为空白。".into());
        }
        if e.review_state.is_none() {
            if let Some(issue) = e.execution_issue() {
                return Err(issue);
            }
        }
        if e.trigger
            .as_deref()
            .is_some_and(|s| s.is_empty() || s.chars().any(is_whitespace_and_newline))
        {
            return Err("触发词不能包含空白。".into());
        }
        if e.invocation_mode == Invocation::Candidate
            && !e.trigger.as_deref().is_some_and(code_valid)
        {
            return Err("候选编码须为小写字母开头的字母或数字，最多 32 位。".into());
        }
        for alias in &e.candidate_aliases {
            if e.invocation_mode != Invocation::Candidate
                || !alias.strip_prefix('v').is_some_and(code_valid)
                || !triggers.insert(nfc(alias))
            {
                return Err("候选别名无效或冲突。".into());
            }
        }
        if e.invocation_mode != Invocation::SearchOnly
            && !e
                .trigger
                .as_deref()
                .is_some_and(|v| triggers.insert(nfc(v)))
        {
            return Err("生效触发词缺失或重复。".into());
        }
        if e.import_source.as_ref().is_some_and(|s| s.version != 1) {
            return Err("不支持的导入来源版本。".into());
        }
        let mut keys = BTreeSet::new();
        if e.parameters
            .iter()
            .any(|p| p.key.is_empty() || p.name.is_empty() || !keys.insert(nfc(&p.key)))
        {
            return Err("参数名称或标识无效。".into());
        }
    }
    automatic_validate(&library.entries)
}
pub fn conflicts(entries: &[Entry]) -> Vec<String> {
    let mut codes: BTreeMap<String, (String, usize)> = BTreeMap::new();
    for e in entries
        .iter()
        .filter(|e| e.invocation_mode != Invocation::SearchOnly)
    {
        for code in e.trigger.iter().chain(e.candidate_aliases.iter()) {
            let v = codes.entry(nfc(code)).or_insert((code.clone(), 0));
            v.1 += 1;
        }
    }
    codes
        .into_values()
        .filter(|v| v.1 > 1)
        .map(|v| v.0)
        .collect()
}
pub fn encoded(library: &Library) -> Result<Vec<u8>> {
    serde_json::to_vec_pretty(library).map_err(|_| "invalid_payload".into())
}
pub fn same(a: &Library, b: &Library) -> bool {
    serde_json::to_value(a).ok() == serde_json::to_value(b).ok()
}
pub fn sorted<H: Host>(host: &mut H, entries: &[Entry]) -> Result<Vec<Entry>> {
    // Native comparator supplies only title order. Rust applies pin priority and ID ties.
    let ranks: Vec<usize> = decode(effect(
        host,
        "title_ranks",
        json!({"titles":entries.iter().map(|e|&e.title).collect::<Vec<_>>()}),
    )?)?;
    if ranks.len() != entries.len() {
        return Err("invalid_native_collation".into());
    }
    let mut order: Vec<_> = (0..entries.len()).collect();
    order.sort_by_key(|i| {
        (
            !entries[*i].is_pinned,
            ranks[*i],
            entries[*i].id.to_uppercase(),
        )
    });
    Ok(order.into_iter().map(|i| entries[i].clone()).collect())
}
pub fn projection<H: Host>(host: &mut H, library: &Library) -> Result<String> {
    let mut output =
        "# Rime table\n# coding: utf-8\n#@/db_name\towl_templates\n#@/db_type\ttabledb\n"
            .to_owned();
    for e in sorted(host, &library.entries)?
        .iter()
        .filter(|e| e.invocation_mode == Invocation::Candidate && e.review_state.is_none())
    {
        for code in std::iter::once(e.trigger.as_deref().unwrap_or(""))
            .chain(e.candidate_aliases.iter().map(String::as_str))
        {
            output.push_str(&format!("{}\t{code}\t100000\n", e.candidate()));
        }
    }
    Ok(output)
}
pub fn search_text(e: &Entry) -> String {
    let mut parts = vec![
        e.title.clone(),
        e.body.clone(),
        e.trigger.clone().unwrap_or_default(),
        e.import_source
            .as_ref()
            .and_then(|s| s.original_keyword.clone())
            .unwrap_or_default(),
    ];
    parts.extend(e.tags.clone());
    parts.extend(e.candidate_aliases.clone());
    parts.join("\n")
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    use crate::template_transaction as tx;
    let library = || decode::<Library>(args["library"].clone());
    let entries = || decode::<Vec<Entry>>(args["entries"].clone());
    let entry = || decode::<Entry>(args["entry"].clone());
    match operation {
        "library_validate" => {
            validate(&library()?)?;
            Ok(json!(true))
        }
        "automatic_index" => Ok(json!(automatic_index(&entries()?)?)),
        "automatic_validate" => {
            automatic_validate(&entries()?)?;
            Ok(json!(true))
        }
        "automatic_valid" => Ok(json!(automatic_valid(
            args["text"].as_str().ok_or("invalid_payload")?
        ))),
        "library_duplicate" => {
            let e = entry()?;
            let copy = e.duplicated(uuid(host)?);
            Ok(json!(copy))
        }
        "library_sorted" => Ok(json!(sorted(host, &entries()?)?)),
        "library_filtered" => {
            let query = trim(args["query"].as_str().unwrap_or(""));
            let tag = args["tag"].as_str();
            let prompt = args["promptOnly"].as_bool().unwrap_or(false);
            let mut output = vec![];
            for e in sorted(host, &entries()?)? {
                if prompt && e.category != Category::Prompt {
                    continue;
                }
                if let Some(tag) = tag {
                    let found: bool = decode(effect(
                        host,
                        "case_contains",
                        json!({"values":e.tags,"value":tag}),
                    )?)?;
                    if !found {
                        continue;
                    }
                }
                if !query.is_empty() {
                    let found: bool = decode(effect(
                        host,
                        "localized_contains",
                        json!({"text":search_text(&e),"query":query}),
                    )?)?;
                    if !found {
                        continue;
                    }
                }
                output.push(e);
            }
            Ok(json!(output))
        }
        "library_tags" => {
            let entries = entries()?;
            let mut tags: Vec<String> = vec![];
            for tag in entries.iter().flat_map(|e| &e.tags) {
                let equivalent: bool = decode(effect(
                    host,
                    "case_contains",
                    json!({"values":tags,"value":tag}),
                )?)?;
                if !equivalent {
                    tags.push(tag.clone());
                }
            }
            let ranks: Vec<usize> = decode(effect(host, "title_ranks", json!({"titles":tags}))?)?;
            if ranks.len() != tags.len() {
                return Err("invalid_native_collation".into());
            }
            let mut indices: Vec<_> = (0..tags.len()).collect();
            indices.sort_by_key(|i| ranks[*i]);
            Ok(json!(indices
                .into_iter()
                .map(|i| tags[i].clone())
                .collect::<Vec<_>>()))
        }
        "library_search_text" => Ok(json!(search_text(&entry()?))),
        "library_candidate" => Ok(json!(entry()?.candidate())),
        "library_candidate_id" => {
            let text = args["text"].as_str().unwrap_or("");
            let id = text
                .strip_prefix("🦉[")
                .and_then(|v| v.split_once(']'))
                .map(|v| v.0);
            let id = id.filter(|v| valid_id(v));
            Ok(json!({"id":id}))
        }
        "library_resolve" => {
            let text = args["text"].as_str().unwrap_or("");
            let code = args["code"].as_str().unwrap_or("");
            let code = code.strip_prefix('K').unwrap_or(code);
            Ok(
                json!({"entry":library()?.entries.into_iter().find(|e|e.review_state.is_none()&&e.invocation_mode==Invocation::Candidate&&(e.trigger.as_deref()==Some(code)||e.candidate_aliases.iter().any(|a|nfc(a)==nfc(code)))&&nfc(&e.candidate())==nfc(text))}),
            )
        }
        "library_projection" => Ok(json!(projection(host, &library()?)?)),
        "library_encode" => Ok(json!(encoded(&library()?)?)),
        "library_mode" => Ok(tx::mode(host)),
        "library_load" => Ok(json!(tx::load(host)?)),
        "library_save" => {
            let expected: Option<Library> = decode(args["expected"].clone())?;
            tx::save(host, &library()?, expected.as_ref())?;
            Ok(json!(true))
        }
        "library_delete" => {
            let id = args["id"].as_str().ok_or("invalid_payload")?;
            let expected: Library = decode(args["expected"].clone())?;
            Ok(json!(tx::delete(host, id, &expected)?))
        }
        "library_conflicts" => Ok(json!(conflicts(&entries()?))),
        "library_current" => Ok(json!(tx::current(host)?)),
        _ => Err("unknown_operation".into()),
    }
}
