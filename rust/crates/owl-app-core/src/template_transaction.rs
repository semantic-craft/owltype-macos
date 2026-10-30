//! Durable migration/restore journal and ordinary editor batches. Journal phases and
//! before/after-image guards belong here, including rename-success/error ambiguity.
use crate::{config_writer, storage::*, template_library::*};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
pub const JOURNAL: &str = ".owl-template-migration/journal.json";
pub const SOURCES: &[&str] = &[
    "owl_quick_send.json",
    "owl_quick_send.txt",
    "owl_prompts.json",
    "owl_prompts.txt",
    FILE,
    STATE,
];
pub const TARGETS: &[&str] = &[
    FILE,
    DICT,
    "rime_ice.custom.yaml",
    STATE,
    config_writer::MANIFEST,
];
#[derive(Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permissions: Option<u32>,
}
impl Snapshot {
    pub fn raw(&self) -> Result<Option<Vec<u8>>> {
        self.bytes
            .as_ref()
            .map(|s| {
                STANDARD
                    .decode(s)
                    .map_err(|_| "migration_invalidJournal".into())
            })
            .transpose()
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Journal {
    pub version: u32,
    #[serde(rename = "migrationID", deserialize_with = "decode_id")]
    pub migration_id: String,
    pub phase: String,
    pub snapshots: Vec<Snapshot>,
    pub expected_writes: BTreeMap<String, String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Activation {
    pub format_version: u32,
    pub committed: bool,
    #[serde(
        rename = "transactionID",
        default,
        deserialize_with = "decode_optional_id",
        skip_serializing_if = "Option::is_none"
    )]
    pub transaction_id: Option<String>,
}
pub fn activation(id: &str) -> String {
    serde_json::to_string(&Activation {
        format_version: 1,
        committed: true,
        transaction_id: Some(id.into()),
    })
    .unwrap()
        + "\n"
}
pub fn snapshot<H: Host>(host: &mut H, name: &str) -> Result<Snapshot> {
    let bytes = read(host, name)?;
    let permissions = if bytes.is_some() {
        decode(effect(host, "permissions", json!({"name":name}))?)?
    } else {
        None
    };
    Ok(Snapshot {
        name: name.into(),
        digest: bytes.as_ref().map(|b| hash(b)),
        bytes: bytes.map(|b| STANDARD.encode(b)),
        permissions,
    })
}
pub fn matches<H: Host>(host: &mut H, s: &Snapshot) -> Result<bool> {
    Ok(read(host, &s.name)? == s.raw()?)
}
pub fn pending<H: Host>(host: &mut H) -> bool {
    match read(host, JOURNAL) {
        Ok(None) => false,
        Ok(Some(bytes)) => serde_json::from_slice::<Journal>(&bytes).map_or(true, |j| {
            j.version != 1 || !matches!(j.phase.as_str(), "committed" | "rolledBack")
        }),
        Err(_) => true,
    }
}
pub fn load_bytes<H: Host>(host: &mut H) -> Result<Library> {
    let bytes = read(host, FILE)?.ok_or("missing_library")?;
    let library: Library = serde_json::from_slice(&bytes).map_err(|_| "invalid_library")?;
    validate(&library)?;
    Ok(library)
}
pub fn load<H: Host>(host: &mut H) -> Result<Library> {
    if pending(host) {
        return Err("模板库操作尚未完成，请先恢复。".into());
    }
    load_bytes(host)
}
pub fn mode<H: Host>(host: &mut H) -> Value {
    if pending(host) {
        return json!({"kind":"unavailable","message":"模板库操作需要恢复，请到快捷片段设置中重试。"});
    }
    match read(host, STATE) {
        Ok(Some(bytes)) => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct State {
                format_version: u32,
                committed: bool,
            }
            let valid = serde_json::from_slice::<State>(&bytes).ok();
            if !valid.is_some_and(|v| v.format_version == 1 && v.committed) {
                return json!({"kind":"unavailable","message":"模板库启用状态无效，请恢复备份。"});
            }
            if load(host).is_ok() {
                return json!({"kind":"unified"});
            }
            return json!({"kind":"unavailable","message":"模板库无法读取，请保留原件并恢复备份。"});
        }
        Err(_) => {
            return json!({"kind":"unavailable","message":"模板库无法读取，请保留原件并恢复备份。"})
        }
        _ => {}
    }
    if read(host, FILE).ok().flatten().is_some() {
        return json!({"kind":"unavailable","message":"发现未完成写入的模板库，请恢复备份后继续。"});
    }
    let legacy = SOURCES[..4]
        .iter()
        .any(|name| read(host, name).ok().flatten().is_some());
    json!({"kind":if legacy{"legacy"}else{"empty"}})
}
pub fn current<H: Host>(host: &mut H) -> Result<Library> {
    let state = mode(host);
    match state["kind"].as_str() {
        Some("empty") => Ok(Library::default()),
        Some("unified") => load(host),
        Some("legacy") => Err("legacy_requires_migration".into()),
        _ => Err(state["message"]
            .as_str()
            .unwrap_or("invalid_library")
            .into()),
    }
}
pub fn batch<H: Host>(
    host: &mut H,
    writes: &[PreparedWrite],
    library: &Library,
    timestamp: &str,
    restore_on_failure: bool,
    originals: Option<&[Snapshot]>,
    sources: &[Snapshot],
) -> Result<()> {
    validate(library)?;
    let state = writes
        .last()
        .filter(|w| w.file_name == STATE)
        .and_then(|w| serde_json::from_str::<Activation>(&w.contents).ok());
    if !state.is_some_and(|s| s.format_version == 1 && s.committed)
        || writes
            .iter()
            .map(|w| &w.file_name)
            .collect::<BTreeSet<_>>()
            .len()
            != writes.len()
        || writes
            .iter()
            .any(|w| !config_writer::MANAGED.contains(&w.file_name.as_str()))
    {
        return Err("模板库写入计划无效。".into());
    }
    let names: Vec<_> = writes
        .iter()
        .map(|w| w.file_name.as_str())
        .chain(std::iter::once(config_writer::MANIFEST))
        .collect();
    let snapshots: Vec<_> = names
        .iter()
        .map(|n| snapshot(host, n))
        .collect::<Result<_>>()?;
    let result = (|| {
        for w in writes {
            if w.file_name == STATE && !same(&load_bytes(host)?, library) {
                return Err("写入核对失败。".into());
            }
            for source in sources {
                if !TARGETS.contains(&source.name.as_str()) && !matches(host, source)? {
                    return Err("migration_changed".into());
                }
            }
            if let Some(original) = originals.and_then(|s| s.iter().find(|s| s.name == w.file_name))
            {
                if !matches(host, original)? {
                    return Err("migration_changed".into());
                }
            }
            checkpoint(host, &w.file_name, "transaction")?;
            config_writer::apply_text(host, &w.file_name, &w.contents, &w.marker, timestamp)?;
            if read(host, &w.file_name)?.as_deref() != Some(w.contents.as_bytes()) {
                return Err("写入核对失败。".into());
            }
        }
        checkpoint(host, "completed", "transaction")
    })();
    if let Err(error) = result {
        if !restore_on_failure {
            return Err(error);
        }
        let mut failed = false;
        for s in snapshots {
            let r = match s.raw()? {
                Some(bytes) => write(host, &s.name, &bytes, None),
                None => remove(host, &s.name),
            };
            failed |= r.is_err();
        }
        return Err(if failed {
            "recovery_failed".into()
        } else {
            error
        });
    }
    Ok(())
}
pub fn save<H: Host>(host: &mut H, library: &Library, expected: Option<&Library>) -> Result<()> {
    locked(host, |host| {
        validate(library)?;
        let current = current(host)?;
        if expected.is_some_and(|e| !same(e, &current)) {
            return Err("changed_on_disk".into());
        }
        let writes = prepare_writes(host, library)?;
        let timestamp = format!("templates-{}", uuid(host)?);
        batch(host, &writes, library, &timestamp, true, None, &[])
    })
}
pub fn stage_library<H: Host>(
    host: &mut H,
    library: &Library,
    expected: &Library,
) -> Result<(Journal, Vec<PreparedWrite>)> {
    let current = current(host)?;
    if !same(&current, expected) {
        return Err("changed_on_disk".into());
    }
    let id = uuid(host)?;
    let mut snapshots = vec![];
    for name in TARGETS {
        checkpoint(host, &format!("snapshot:{name}"), "transaction")?;
        snapshots.push(snapshot(host, name)?)
    }
    let mut writes = prepare_writes(host, library)?;
    writes.last_mut().unwrap().contents = activation(&id);
    let reread = if current.entries.is_empty() && read(host, FILE)?.is_none() {
        Library::default()
    } else {
        load(host)?
    };
    if !same(&reread, expected) {
        return Err("changed_on_disk".into());
    }
    for s in &snapshots {
        if !matches(host, s)? {
            return Err("changed_on_disk".into());
        }
    }
    let journal = Journal {
        version: 1,
        migration_id: id,
        phase: "prepared".into(),
        snapshots,
        expected_writes: writes
            .iter()
            .map(|w| (w.file_name.clone(), STANDARD.encode(w.contents.as_bytes())))
            .collect(),
    };
    persist(host, JOURNAL, &journal)?;
    Ok((journal, writes))
}
pub fn execute<H: Host>(
    host: &mut H,
    mut journal: Journal,
    writes: &[PreparedWrite],
    library: &Library,
    sources: &[Snapshot],
) -> Result<()> {
    let result = checkpoint(host, "journal", "transaction").and_then(|_| {
        batch(
            host,
            writes,
            library,
            &format!("migration-{}", journal.migration_id),
            false,
            Some(&journal.snapshots),
            sources,
        )
    });
    if let Err(error) = result {
        restore(host, &mut journal)?;
        return Err(error);
    }
    journal.phase = "committed".into();
    persist(host, JOURNAL, &journal)
}
pub fn commit_library<H: Host>(
    host: &mut H,
    library: &Library,
    expected: &Library,
    prepare_only: bool,
) -> Result<Vec<PreparedWrite>> {
    locked(host, |host| {
        recover(host)?;
        let (journal, writes) = stage_library(host, library, expected)?;
        if !prepare_only {
            execute(host, journal, &writes, library, &[])?
        }
        Ok(writes)
    })
}
fn valid_journal(j: &Journal) -> bool {
    let allowed: BTreeSet<_> = TARGETS.iter().chain(SOURCES).copied().collect();
    let names: BTreeSet<_> = j.snapshots.iter().map(|s| s.name.as_str()).collect();
    j.expected_writes
        .values()
        .all(|v| STANDARD.decode(v).is_ok())
        && j.version == 1
        && ["prepared", "rollingBack", "committed", "rolledBack"].contains(&j.phase.as_str())
        && (names == allowed || names == TARGETS.iter().copied().collect())
        && names.len() == j.snapshots.len()
        && j.expected_writes
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>()
            == TARGETS
                .iter()
                .copied()
                .filter(|n| *n != config_writer::MANIFEST)
                .collect()
        && j.snapshots
            .iter()
            .all(|s| s.raw().is_ok_and(|b| s.digest == b.map(|b| hash(&b))))
}
pub fn recover<H: Host>(host: &mut H) -> Result<bool> {
    let settled = locked(host, |host| {
        let Some(bytes) = read(host, JOURNAL)? else {
            return Ok(false);
        };
        let mut journal: Journal =
            serde_json::from_slice(&bytes).map_err(|_| "migration_invalidJournal")?;
        if !valid_journal(&journal) {
            return Err("migration_invalidJournal".into());
        }
        if ["committed", "rolledBack"].contains(&journal.phase.as_str()) {
            return Ok(false);
        }
        if journal.phase == "rollingBack" {
            restore(host, &mut journal)?;
            return Ok(true);
        }
        let state = read(host, STATE)
            .ok()
            .flatten()
            .and_then(|b| serde_json::from_slice::<Activation>(&b).ok());
        if state.is_some_and(|s| {
            s.transaction_id.as_deref() == Some(&journal.migration_id)
                && s.committed
                && s.format_version == 1
        }) {
            for (name, bytes) in &journal.expected_writes {
                if read(host, name)?
                    != Some(
                        STANDARD
                            .decode(bytes)
                            .map_err(|_| "migration_invalidJournal")?,
                    )
                {
                    return Err("migration_changed".into());
                }
            }
            load_bytes(host)?;
            journal.phase = "committed".into();
            persist(host, JOURNAL, &journal)?;
            return Ok(true);
        }
        restore(host, &mut journal)?;
        Ok(true)
    })?;
    if settled {
        effect(host, "library_committed", json!({}))?;
    }
    Ok(settled)
}
fn owns_manifest<H: Host>(host: &mut H, journal: &Journal, original: &Snapshot) -> Result<bool> {
    let Some(bytes) = read(host, &original.name)? else {
        return Ok(original.bytes.is_none());
    };
    let current: config_writer::Manifest =
        serde_json::from_slice(&bytes).map_err(|_| "invalid_manifest")?;
    let before = original
        .raw()?
        .map(|b| {
            serde_json::from_slice::<config_writer::Manifest>(&b).map_err(|_| "invalid_manifest")
        })
        .transpose()?;
    let count = before.as_ref().map_or(0, |b| b.files.len());
    if current.files.len() < count {
        return Ok(false);
    }
    if let Some(before) = before {
        if serde_json::to_value(&current.files[..count]).ok()
            != serde_json::to_value(before.files).ok()
        {
            return Ok(false);
        }
    }
    Ok(current.files[count..].iter().all(|e| {
        e.ts == format!("migration-{}", journal.migration_id)
            && TARGETS.contains(&e.path.rsplit('/').next().unwrap_or(""))
    }))
}
pub fn restore<H: Host>(host: &mut H, journal: &mut Journal) -> Result<()> {
    for s in journal
        .snapshots
        .iter()
        .filter(|s| TARGETS.contains(&s.name.as_str()))
    {
        if matches(host, s)? {
            continue;
        }
        let owned = if s.name == config_writer::MANIFEST {
            owns_manifest(host, journal, s)?
        } else {
            match journal.expected_writes.get(&s.name) {
                Some(expected) => {
                    read(host, &s.name)?
                        == Some(
                            STANDARD
                                .decode(expected)
                                .map_err(|_| "migration_invalidJournal")?,
                        )
                }
                None => false,
            }
        };
        if !owned {
            return Err("migration_changed".into());
        }
    }
    journal.phase = "rollingBack".into();
    persist(host, JOURNAL, journal)?;
    let mut failed = false;
    for s in journal
        .snapshots
        .iter()
        .filter(|s| TARGETS.contains(&s.name.as_str()))
    {
        let result: Result<()> = (|| {
            checkpoint(host, &format!("restore:{}", s.name), "transaction")?;
            match s.raw()? {
                Some(bytes) => write(host, &s.name, &bytes, s.permissions)?,
                None => remove(host, &s.name)?,
            };
            if !matches(host, s)? {
                return Err("migration_recovery".into());
            }
            Ok(())
        })();
        failed |= result.is_err();
    }
    if failed {
        return Err("migration_recovery".into());
    }
    journal.phase = "rolledBack".into();
    persist(host, JOURNAL, journal)
}
