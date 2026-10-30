//! Strict legacy audit and durable migration plan. Source data is never edited.
use crate::{storage::*, template_library::*, template_transaction::*};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
pub const PLAN: &str = ".owl-template-migration/plan.json";
#[derive(Clone, Serialize, Deserialize)]
pub struct Issue {
    pub file: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub record: Option<usize>,
    pub message: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub version: u32,
    #[serde(deserialize_with = "decode_id")]
    pub id: String,
    pub sources: Vec<Snapshot>,
    pub entries: Vec<Entry>,
    pub existing_entries: Vec<Entry>,
    pub issues: Vec<Issue>,
    pub collapsed_rows: usize,
}
impl Plan {
    pub fn library(&self) -> Library {
        Library {
            format_version: 1,
            entries: self
                .existing_entries
                .iter()
                .chain(&self.entries)
                .cloned()
                .collect(),
        }
    }
    fn issue(&mut self, file: &str, record: Option<usize>, message: &str) {
        self.issues.push(Issue {
            file: file.into(),
            record,
            message: message.into(),
        })
    }
}
fn title(body: &str) -> String {
    body.split([
        '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
    ])
    .find(|s| {
        !s.trim_matches(|c: char| c.is_whitespace() && c != '\n')
            .is_empty()
    })
    .unwrap_or("")
    .replace('\t', " ")
    .trim()
    .into()
}
fn make<H: Host>(
    host: &mut H,
    code: String,
    title: String,
    body: String,
    prompt: bool,
    file: &str,
    position: usize,
) -> Result<Entry> {
    let mut e = Entry::new(uuid(host)?, title, body);
    e.trigger = Some(code.clone());
    e.invocation_mode = Invocation::Candidate;
    e.migration_source = Some(MigrationSource {
        source_file: file.into(),
        record: position,
        original_code: code.clone(),
    });
    if prompt {
        e.body_type = BodyType::Template;
        e.syntax = Syntax::LegacyDoubleBraces;
        e.category = Category::Prompt;
        e.candidate_aliases = vec![format!("v{code}")];
        e.parameters = e
            .parsed(false)
            .parameters
            .into_iter()
            .map(|p| Parameter {
                key: format!("n:{}", p.name),
                name: p.name,
                is_required: false,
                default_value: Some(String::new()),
                options: vec![],
            })
            .collect()
    }
    Ok(e)
}
fn append(plan: &mut Plan, e: Entry) {
    if let Some(source) = &e.migration_source {
        if !e.trigger.as_deref().is_some_and(code_valid) {
            plan.issue(
                &source.source_file,
                Some(source.record),
                "原编码无效，请改码或选择仅搜索。",
            )
        }
        let mut check = e.clone();
        check.trigger = None;
        check.candidate_aliases.clear();
        check.invocation_mode = Invocation::SearchOnly;
        if validate(&Library {
            entries: vec![check],
            ..Library::default()
        })
        .is_err()
        {
            plan.issue(
                &source.source_file,
                Some(source.record),
                "标题或正文无效，请修复原记录后重新检查。",
            )
        }
    }
    plan.entries.push(e)
}
fn audit_json<H: Host>(host: &mut H, file: &str, prompt: bool, plan: &mut Plan) -> Result<()> {
    let bytes = match read(host, file) {
        Ok(Some(b)) => b,
        _ => {
            plan.issue(file, None, "JSON 无法解析或读取；未使用派生表代替原件。");
            return Ok(());
        }
    };
    let value = match serde_json::from_slice::<Value>(&bytes) {
        Ok(v) => v,
        Err(_) => {
            plan.issue(file, None, "JSON 无法解析或读取；未使用派生表代替原件。");
            return Ok(());
        }
    };
    let Some(records) = value.as_array() else {
        plan.issue(file, None, "文件必须是 UTF-8 JSON 数组。");
        return Ok(());
    };
    for (index, value) in records.iter().enumerate() {
        let position = Some(index + 1);
        let Some(object) = value.as_object() else {
            plan.issue(file, position, "记录必须是对象。");
            continue;
        };
        let fields = if prompt {
            vec!["code", "title", "body", "category"]
        } else {
            vec!["code", "text"]
        };
        let wrong: Vec<_> = fields
            .iter()
            .filter(|f| !object.get(**f).is_some_and(Value::is_string))
            .collect();
        for field in &wrong {
            plan.issue(file, position, &format!("字段 {field} 缺失或不是文本。"))
        }
        if object.keys().any(|k| !fields.contains(&k.as_str())) {
            plan.issue(file, position, "记录包含未支持字段，请先核对原件。")
        }
        if !wrong.is_empty() {
            continue;
        }
        let body = object[if prompt { "body" } else { "text" }]
            .as_str()
            .unwrap();
        let title = if prompt {
            object["title"].as_str().unwrap().into()
        } else {
            title(body)
        };
        let mut e = make(
            host,
            object["code"].as_str().unwrap().into(),
            title,
            body.into(),
            prompt,
            file,
            index + 1,
        )?;
        if prompt {
            let category = object["category"].as_str().unwrap();
            if !category.is_empty() {
                e.tags = vec![category.into()]
            }
        }
        append(plan, e);
    }
    Ok(())
}
fn audit_table<H: Host>(host: &mut H, plan: &mut Plan) -> Result<()> {
    let file = "owl_quick_send.txt";
    let text = match text(host, file) {
        Ok(Some(t)) => t,
        _ => {
            plan.issue(file, None, "历史短语表无法读取。");
            return Ok(());
        }
    };
    let mut rows = vec![];
    for (index, line) in text
        .split([
            '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
        ])
        .enumerate()
    {
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let parts: Vec<_> = line.split('\t').collect();
        if !(2..=3).contains(&parts.len()) || (parts.len() == 3 && parts[2].parse::<i64>().is_err())
        {
            plan.issue(
                file,
                Some(index + 1),
                "历史记录必须是正文、编码及可选数字权重。",
            );
            continue;
        }
        rows.push(make(
            host,
            parts[1].into(),
            title(parts[0]),
            parts[0].into(),
            false,
            file,
            index + 1,
        )?);
    }
    let mut groups: BTreeMap<String, Vec<Entry>> = BTreeMap::new();
    for row in &rows {
        groups
            .entry(row.trigger.clone().unwrap_or_default())
            .or_default()
            .push(row.clone())
    }
    for row in rows {
        let code = row.trigger.as_deref().unwrap_or("");
        let bases = code.get(1..).and_then(|v| groups.get(v));
        if code.starts_with('v')
            && groups[code].len() == 1
            && bases.is_some_and(|b| b.len() == 1 && b[0].body.as_bytes() == row.body.as_bytes())
        {
            plan.collapsed_rows += 1
        } else {
            append(plan, row)
        }
    }
    Ok(())
}
pub fn prepare<H: Host>(host: &mut H) -> Result<Plan> {
    locked(host, |host| {
        recover(host)?;
        if mode(host)["kind"] == "unified" {
            return Err("migration_alreadyUnified".into());
        }
        if let Some(bytes) = read(host, PLAN)? {
            let previous: Plan = serde_json::from_slice(&bytes).map_err(|_| "invalid_plan")?;
            if previous.version == 1 && previous.sources.len() == SOURCES.len() {
                let mut valid = true;
                for s in &previous.sources {
                    valid &= matches(host, s)?
                }
                if valid {
                    return Ok(previous);
                }
            }
        }
        let mut plan = Plan {
            version: 1,
            id: uuid(host)?,
            sources: vec![],
            entries: vec![],
            existing_entries: vec![],
            issues: vec![],
            collapsed_rows: 0,
        };
        for name in SOURCES {
            match snapshot(host, name) {
                Ok(s) => plan.sources.push(s),
                Err(_) => plan.issue(name, None, "文件无法读取，请检查权限。"),
            }
        }
        if read(host, STATE)?.is_some() {
            plan.issue(STATE, None, "启用标记无效，不能用迁移覆盖已启用的库。")
        }
        if read(host, FILE)?.is_some() {
            match load(host) {
                Ok(l) => plan.existing_entries = l.entries,
                Err(_) => plan.issue(FILE, None, "已有新库无法严格读取，不能覆盖。"),
            }
        }
        if read(host, "owl_quick_send.json")?.is_some() {
            audit_json(host, "owl_quick_send.json", false, &mut plan)?
        } else if read(host, "owl_quick_send.txt")?.is_some() {
            audit_table(host, &mut plan)?
        }
        if read(host, "owl_prompts.json")?.is_some() {
            audit_json(host, "owl_prompts.json", true, &mut plan)?
        } else if read(host, "owl_prompts.txt")?.is_some() {
            match text(host, "owl_prompts.txt") {
                Ok(Some(text)) => {
                    if text
                        .lines()
                        .any(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
                    {
                        plan.issue(
                            "owl_prompts.txt",
                            None,
                            "仅有提示词候选表，缺少正文原件 owl_prompts.json。",
                        )
                    }
                }
                _ => plan.issue("owl_prompts.txt", None, "候选表无法读取。"),
            }
        }
        persist(host, PLAN, &plan)?;
        Ok(plan)
    })
}
fn verify<H: Host>(host: &mut H, plan: &Plan) -> Result<()> {
    if plan.version != 1 {
        return Err("migration_changed".into());
    }
    for s in &plan.sources {
        if !matches(host, s)? {
            return Err("migration_changed".into());
        }
    }
    let saved: Plan = serde_json::from_slice(&read(host, PLAN)?.ok_or("migration_changed")?)
        .map_err(|_| "invalid_plan")?;
    if serde_json::to_value(saved).ok() != serde_json::to_value(plan).ok() {
        return Err("migration_changed".into());
    }
    Ok(())
}
pub fn resolve<H: Host>(host: &mut H, plan: &Plan, id: &str, code: Option<String>) -> Result<Plan> {
    locked(host, |host| {
        verify(host, plan)?;
        let mut updated = plan.clone();
        let e = updated
            .entries
            .iter_mut()
            .find(|e| e.id.eq_ignore_ascii_case(id))
            .ok_or("migration_changed")?;
        e.trigger = code.clone();
        e.invocation_mode = if code.is_some() {
            Invocation::Candidate
        } else {
            Invocation::SearchOnly
        };
        e.candidate_aliases = if e.category == Category::Prompt {
            code.map(|s| vec![format!("v{s}")]).unwrap_or_default()
        } else {
            vec![]
        };
        validate(&Library {
            entries: vec![e.clone()],
            ..Library::default()
        })?;
        if let Some(source) = &e.migration_source {
            updated.issues.retain(|i| {
                !(i.file == source.source_file
                    && i.record == Some(source.record)
                    && i.message == "原编码无效，请改码或选择仅搜索。")
            })
        }
        persist(host, PLAN, &updated)?;
        Ok(updated)
    })
}
pub fn commit<H: Host>(
    host: &mut H,
    plan: &Plan,
    prepare_only: bool,
) -> Result<Vec<PreparedWrite>> {
    locked(host, |host| {
        recover(host)?;
        verify(host, plan)?;
        if !plan.issues.is_empty() {
            return Err("migration_issues".into());
        }
        let library = plan.library();
        if !conflicts(&library.entries).is_empty() {
            return Err("migration_conflict".into());
        }
        let mut writes = prepare_writes(host, &library)?;
        for w in &mut writes {
            if w.file_name == "rime_ice.custom.yaml" {
                for marker in [
                    "OWL MANAGED QUICK_SEND RIME_ICE PATCH v1",
                    "OWL MANAGED PROMPTS RIME_ICE PATCH v1",
                ] {
                    let begin = format!("  # >>> {marker}");
                    let end = format!("  # <<< {marker}");
                    match (w.contents.find(&begin), w.contents.find(&end)) {
                        (Some(a), Some(b)) if a < b + end.len() => {
                            w.contents.replace_range(a..b + end.len(), "");
                        }
                        (None, None) => {}
                        _ => return Err("migration_issues".into()),
                    }
                }
                if w.contents.contains("table_translator@owl_quick_send")
                    || w.contents.contains("table_translator@owl_prompts")
                {
                    return Err("migration_issues".into());
                }
            }
        }
        writes.last_mut().unwrap().contents = activation(&plan.id);
        let names: BTreeSet<_> = TARGETS.iter().chain(SOURCES).copied().collect();
        let mut snapshots = vec![];
        for name in names {
            checkpoint(host, &format!("snapshot:{name}"), "transaction")?;
            snapshots.push(snapshot(host, name)?)
        }
        let journal = Journal {
            version: 1,
            migration_id: plan.id.clone(),
            phase: "prepared".into(),
            snapshots,
            expected_writes: writes
                .iter()
                .map(|w| (w.file_name.clone(), STANDARD.encode(w.contents.as_bytes())))
                .collect(),
        };
        persist(host, JOURNAL, &journal)?;
        if !prepare_only {
            execute(host, journal, &writes, &library, &plan.sources)?
        }
        Ok(writes)
    })
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "migration_prepare" => Ok(json!(prepare(host)?)),
        "migration_resolve" => Ok(json!(resolve(
            host,
            &decode(args["plan"].clone())?,
            args["id"].as_str().ok_or("invalid_payload")?,
            decode(args["code"].clone())?
        )?)),
        "migration_commit" => Ok(json!(commit(
            host,
            &decode(args["plan"].clone())?,
            args["prepareOnly"].as_bool().unwrap_or(false)
        )?)),
        "migration_automatic" => {
            recover(host)?;
            if mode(host)["kind"] != "legacy" {
                return Ok(json!(false));
            }
            let plan = prepare(host)?;
            if !plan.issues.is_empty() || !conflicts(&plan.library().entries).is_empty() {
                return Ok(json!(false));
            }
            commit(host, &plan, false)?;
            Ok(json!(true))
        }
        _ => Err("unknown_operation".into()),
    }
}
