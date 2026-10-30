//! Native backup validation, ID merge preview, export and journal-backed restore/delete.
use crate::{storage::*, template_library::*, template_transaction as tx};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    New,
    Identical,
    Update,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub entry: Entry,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current: Option<Entry>,
    pub kind: Kind,
    pub original_invocation_mode: Invocation,
    pub selected: bool,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Preview {
    pub baseline: Library,
    pub rows: Vec<Row>,
}
impl Preview {
    pub fn library(&self) -> Library {
        let mut library = self.baseline.clone();
        for row in self
            .rows
            .iter()
            .filter(|r| r.selected && r.kind != Kind::Identical)
        {
            if let Some(e) = library
                .entries
                .iter_mut()
                .find(|e| e.id.eq_ignore_ascii_case(&row.entry.id))
            {
                *e = row.entry.clone()
            } else {
                library.entries.push(row.entry.clone())
            }
        }
        library
    }
    pub fn change(&mut self, id: &str, code: Option<String>) {
        let Some((index, row)) = self
            .rows
            .iter_mut()
            .enumerate()
            .find(|(_, r)| r.entry.id.eq_ignore_ascii_case(id))
        else {
            return;
        };
        if row.entry.migration_source.is_none() {
            if let Some(trigger) = &row.entry.trigger {
                row.entry.migration_source = Some(MigrationSource {
                    source_file: "native-backup".into(),
                    record: index + 1,
                    original_code: trigger.clone(),
                })
            }
        }
        row.entry.trigger = code.clone().filter(|c| !c.is_empty());
        row.entry.invocation_mode = if row.entry.trigger.is_some() {
            row.original_invocation_mode
        } else {
            Invocation::SearchOnly
        };
        row.entry.candidate_aliases.clear();
    }
}
fn check_keys(value: &Value, allowed: &[&str]) -> Result<()> {
    if value
        .as_object()
        .is_some_and(|o| o.keys().any(|k| !allowed.contains(&k.as_str())))
    {
        Err("备份包含当前版本无法保留的字段，请使用支持该格式的版本。".into())
    } else {
        Ok(())
    }
}
pub fn decode_backup(bytes: &[u8]) -> Result<Library> {
    let v: Value = serde_json::from_slice(bytes)
        .map_err(|_| "原生备份无法完整读取；请保留原文件并核对格式。")?;
    if v["formatVersion"].as_u64() != Some(1) {
        return Err("不支持的原生备份版本或格式。".into());
    }
    check_keys(&v, &["formatVersion", "entries"])?;
    let entries = v["entries"].as_array().ok_or("备份条目必须是数组。")?;
    for e in entries {
        check_keys(
            e,
            &[
                "id",
                "title",
                "body",
                "bodyType",
                "syntax",
                "candidateAliases",
                "trigger",
                "tags",
                "isPinned",
                "category",
                "parameters",
                "invocationMode",
                "expansionMode",
                "migrationSource",
                "importSource",
                "reviewState",
                "exposedToAgents",
            ],
        )?;
        if let Some(params) = e["parameters"].as_array() {
            for p in params {
                check_keys(p, &["key", "name", "isRequired", "defaultValue", "options"])?
            }
        }
        check_keys(
            &e["migrationSource"],
            &["sourceFile", "record", "originalCode"],
        )?;
        check_keys(
            &e["importSource"],
            &["version", "originalName", "originalBody", "originalKeyword"],
        )?;
    }
    let library: Library =
        serde_json::from_value(v).map_err(|_| "原生备份无法完整读取；请保留原文件并核对格式。")?;
    let mut ids = BTreeSet::new();
    for e in &library.entries {
        if !ids.insert(e.id.to_uppercase()) {
            return Err("备份中有重复 ID。".into());
        }
        validate(&Library {
            entries: vec![e.clone()],
            ..Library::default()
        })?
    }
    Ok(library)
}
pub fn preview<H: Host>(host: &mut H, bytes: &[u8]) -> Result<Preview> {
    let incoming = decode_backup(bytes)?;
    let baseline = tx::current(host)?;
    let rows = incoming
        .entries
        .into_iter()
        .map(|entry| {
            let current = baseline
                .entries
                .iter()
                .find(|e| e.id.eq_ignore_ascii_case(&entry.id))
                .cloned();
            let kind = match &current {
                None => Kind::New,
                Some(current) => {
                    if serde_json::to_value(current).ok() == serde_json::to_value(&entry).ok() {
                        Kind::Identical
                    } else {
                        Kind::Update
                    }
                }
            };
            Row {
                original_invocation_mode: entry.invocation_mode,
                entry,
                current,
                kind,
                selected: kind == Kind::New,
            }
        })
        .collect();
    Ok(Preview { baseline, rows })
}
fn write_backup<H: Host>(host: &mut H, bytes: &[u8], name: &str) -> Result<()> {
    decode_backup(bytes)?;
    // Rust selects the temp name, verifies exact bytes and only then requests rename.
    let temporary = format!(".owl-native-{}", uuid(host)?);
    let temp: String = decode(effect(
        host,
        "sibling",
        json!({"name":name,"sibling":temporary}),
    )?)?;
    let result = (|| {
        write(host, &temp, bytes, None)?;
        if read(host, &temp)?.as_deref() != Some(bytes) {
            return Err("备份写入核对失败。".into());
        }
        effect(host, "rename", json!({"source":temp,"destination":name}))?;
        Ok(())
    })();
    let _ = remove(host, &temp);
    result
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub library: Library,
    #[serde(rename = "backupURL")]
    pub backup_url: Option<String>,
}
pub fn commit<H: Host>(host: &mut H, next: &Library, expected: &Library) -> Result<Outcome> {
    // The original public operation held the process lock across backup and the journal's
    // cross-process lock around commit. Holding both for the full operation also closes its
    // backup-to-stage race while preserving expected-library checks.
    locked(host, |host| {
        tx::recover(host)?;
        let current = tx::current(host)?;
        if !same(&current, expected) {
            return Err("changed_on_disk".into());
        }
        validate(next)?;
        if same(next, &current) {
            return Ok(Outcome {
                library: current,
                backup_url: None,
            });
        }
        let backup = format!(".owl-backup/templates-{}/{}", uuid(host)?, FILE);
        checkpoint(host, "backup", "transaction")?;
        let bytes = read(host, FILE)?.unwrap_or(encoded(&current)?);
        if !same(&decode_backup(&bytes)?, &current) {
            return Err("changed_on_disk".into());
        }
        write_backup(host, &bytes, &backup)?;
        checkpoint(host, "backupVerified", "transaction")?;
        if let Err(error) = tx::commit_library(host, next, expected, false) {
            tx::recover(host)?;
            if !same(&tx::current(host)?, next) {
                return Err(error);
            }
        }
        let path: String = decode(effect(host, "file_url", json!({"name":backup}))?)?;
        Ok(Outcome {
            library: next.clone(),
            backup_url: Some(path),
        })
    })
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "backup_decode" => {
            let bytes: Vec<u8> = decode(args["bytes"].clone())?;
            Ok(json!(decode_backup(&bytes)?))
        }
        "backup_preview" => {
            let bytes: Vec<u8> = decode(args["bytes"].clone())?;
            Ok(json!(preview(host, &bytes)?))
        }
        "backup_library" => {
            let p: Preview = decode(args["preview"].clone())?;
            Ok(json!(p.library()))
        }
        "backup_change" => {
            let mut p: Preview = decode(args["preview"].clone())?;
            p.change(
                args["id"].as_str().ok_or("invalid_payload")?,
                decode(args["code"].clone())?,
            );
            Ok(json!(p))
        }
        "backup_export" => {
            let library = tx::current(host)?;
            write_backup(
                host,
                &encoded(&library)?,
                args["destination"].as_str().ok_or("invalid_payload")?,
            )?;
            Ok(json!(true))
        }
        "backup_restore" => {
            let p: Preview = decode(args["preview"].clone())?;
            let next = p.library();
            if !conflicts(&next.entries).is_empty() {
                return Err("生效触发词或候选别名冲突，请先处理后恢复。".into());
            }
            Ok(json!(commit(host, &next, &p.baseline)?))
        }
        "backup_delete" => {
            let expected: Library = decode(args["expected"].clone())?;
            let mut next = expected.clone();
            let id = args["id"].as_str().ok_or("invalid_payload")?;
            next.entries.retain(|e| !e.id.eq_ignore_ascii_case(id));
            if next.entries.len() == expected.entries.len() {
                return Err("changed_on_disk".into());
            }
            Ok(json!(commit(host, &next, &expected)?))
        }
        "backup_commit" => Ok(json!(commit(
            host,
            &decode(args["library"].clone())?,
            &decode(args["expected"].clone())?
        )?)),
        _ => Err("unknown_operation".into()),
    }
}
