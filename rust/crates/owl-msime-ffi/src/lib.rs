#![allow(unsafe_code)]

use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use msime_engine::host::{
    check_shuangpin_custom_profile, prepare_options, Command, EngineOptions, HelpcodeKeymap,
    QuickPhraseEntry, Session as EngineSession,
};
use msime_engine::{
    ensure_english_schema, fuzzy_rule, is_complete_pinyin_input, reject_redirected_directory,
    roots_overlap, weakly_canonical, CandidateSource, FrequencyAdjustmentMode, SchemeSet,
    SchemeType, SentenceAssociationOptions, ShuangpinCustomTable, ShuangpinHelpcodeModes,
    ShuangpinProfileKind, WubiProfileKind,
};
use msime_input_runtime::{
    Action, CandidateId, CandidateOps, CandidateTransform, Runtime, TransformRow, View,
};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use tempfile::TempDir;

#[derive(Default)]
struct OwlPinnedState {
    words: HashMap<(String, bool), Vec<String>>,
    enabled: bool,
    traditional: bool,
    active_input: String,
    caret_at_end: bool,
    input_mode: String,
    pinyin_scheme: String,
    page_size: usize,
    wubi_single_first: bool,
    wubi_z_reverse_lookup: bool,
}

struct OwlPinnedTransform {
    state: Arc<Mutex<OwlPinnedState>>,
}

fn normalized_pinyin(value: &str) -> String {
    let mut cleaned = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch != '\'' && ch != ' ' {
            cleaned.push(ch);
        }
    }
    let mut result = cleaned.replace('ü', "v");
    for initial in ["j", "q", "x", "y"] {
        let from = format!("{initial}v");
        let to = format!("{initial}u");
        result = result.replace(&from, &to);
    }
    for initial in ["n", "l"] {
        let from = format!("{initial}ue");
        let to = format!("{initial}ve");
        result = result.replace(&from, &to);
    }
    result
}

impl CandidateTransform for OwlPinnedTransform {
    fn transform(
        &mut self,
        window: &[TransformRow<'_>],
        local_mode: &str,
        out: &mut Vec<CandidateOps>,
    ) {
        if local_mode != "none" || window.is_empty() {
            return;
        }
        let Ok(guard) = self.state.lock() else {
            return;
        };
        let mut ops = CandidateOps::default();
        fn push_unique(order: &mut Vec<u32>, seat: usize) {
            let seat_u32 = seat as u32;
            if !order.contains(&seat_u32) {
                order.push(seat_u32);
            }
        }

        // 1. User pinned words at the very top when composing full Quanpin input at end caret.
        if guard.enabled && guard.caret_at_end && !guard.active_input.is_empty() {
            if let Some(pins) = guard
                .words
                .get(&(guard.active_input.clone(), guard.traditional))
            {
                let target_norm = normalized_pinyin(&guard.active_input);
                for pin_word in pins {
                    if let Some((seat, _)) = window.iter().enumerate().find(|(_, row)| {
                        row.text == pin_word
                            && (row.code.is_empty() || normalized_pinyin(row.code) == target_norm)
                    }) {
                        let seat_u32 = seat as u32;
                        if !ops.order.contains(&seat_u32) {
                            ops.order.push(seat_u32);
                            ops.annotations.push((seat_u32, "置顶".to_owned()));
                        }
                    }
                }
            }
        }

        // 2. Host quick phrases / templates / prompts (CandidateSource::QuickPhrase == 5)
        //    appear at the top of page 0 (matching Owltype's initial_quality: 99 table translators).
        let quick_phrase_src = CandidateSource::QuickPhrase as u8;
        for (seat, row) in window.iter().enumerate() {
            if row.source == quick_phrase_src {
                push_unique(&mut ops.order, seat);
            }
        }

        // 3. Wubi single-character-first mode (#250): place single-character candidates ahead of phrases
        //    (except during z-prefix reverse lookup).
        let in_z_lookup = guard.input_mode == "wubi"
            && guard.pinyin_scheme != "wubi_pinyin"
            && guard.wubi_z_reverse_lookup
            && guard.active_input.starts_with('z');
        if guard.input_mode == "wubi" && guard.wubi_single_first && !in_z_lookup {
            for (seat, row) in window.iter().enumerate() {
                if row.text.chars().count() == 1 {
                    push_unique(&mut ops.order, seat);
                }
            }
            for (seat, _) in window.iter().enumerate() {
                push_unique(&mut ops.order, seat);
            }
        }

        // 4. Whole-syllable Chinese-first protection (#259 AC 1):
        //    When typing complete Quanpin syllables (e.g., `di`, `shi`, `nihao`, `you`), keep at least
        //    the first page of Chinese candidates ahead of mixed English dictionary rows.
        let english_src = CandidateSource::EnglishDictionary as u8;
        if guard.input_mode == "chinese"
            && guard.pinyin_scheme == "quanpin"
            && !guard.active_input.is_empty()
            && is_complete_pinyin_input(guard.active_input.trim_end_matches('\''))
            && window.iter().any(|r| r.source == english_src)
        {
            let page_sz = guard.page_size.max(5);
            let mut chinese_kept = 0usize;
            for (seat, row) in window.iter().enumerate() {
                if row.source != english_src {
                    push_unique(&mut ops.order, seat);
                    chinese_kept += 1;
                    if chinese_kept >= page_sz {
                        break;
                    }
                }
            }
            for (seat, row) in window.iter().enumerate() {
                if row.source == english_src {
                    push_unique(&mut ops.order, seat);
                }
            }
            for (seat, _) in window.iter().enumerate() {
                push_unique(&mut ops.order, seat);
            }
        }

        if !ops.order.is_empty() || !ops.annotations.is_empty() {
            out.push(ops);
        }
    }
}

pub struct OwlMsimeSession {
    runtime: Runtime<EngineSession>,
    options: EngineOptions,
    source_pinyin_path: PathBuf,
    staged_pinyin_path: PathBuf,
    page_size: u8,
    input_mode: String,
    pinyin_scheme: String,
    wubi_code_hint: bool,
    wubi_auto_clear: bool,
    wubi_candidate_mode: String,
    wubi_z_reverse_lookup: bool,
    wubi_english_channel: bool,
    wubi_user_dict_learning: bool,
    pinned_state: Arc<Mutex<OwlPinnedState>>,
    _temp_dir: Option<TempDir>,
}

#[derive(Debug, Deserialize)]
struct ActionPayload {
    op: String,
    #[serde(default)]
    ch: Option<String>,
    #[serde(default)]
    delta: Option<i32>,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    start: Option<usize>,
    #[serde(default)]
    count: Option<usize>,
    #[serde(default)]
    pos: Option<usize>,
    #[serde(default)]
    generation: Option<u64>,
    #[serde(default)]
    is_absolute: Option<bool>,
    #[serde(default)]
    ascii: Option<bool>,
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    scheme: Option<String>,
    #[serde(default)]
    custom_profile: Option<ShuangpinCustomTableDto>,
    #[serde(default)]
    page_size: Option<u32>,
    #[serde(default)]
    mask: Option<u32>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    value: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
struct ShuangpinCustomTableDto {
    initials: Vec<(String, String)>,
    finals: Vec<(String, String)>,
    zero_initials: Vec<(String, String)>,
}

impl From<ShuangpinCustomTableDto> for ShuangpinCustomTable {
    fn from(value: ShuangpinCustomTableDto) -> Self {
        Self {
            initials: value.initials,
            finals: value.finals,
            zero_initials: value.zero_initials,
        }
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CandidateDto {
    pub text: String,
    pub comment: Option<String>,
    pub kind: String,
    pub input_len: usize,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotResponseDto {
    pub ok: bool,
    pub error: Option<String>,
    pub consumed: bool,
    pub committed_text: Option<String>,
    pub cleared: bool,
    pub generation: u64,
    pub raw_input: String,
    pub preedit: String,
    pub caret_position: usize,
    pub preedit_caret_byte: usize,
    pub page: usize,
    pub page_size: usize,
    pub highlighted_index: usize,
    pub has_more_pages: bool,
    pub candidates: Vec<CandidateDto>,
}

fn clamp_page_size(page_size: u32) -> u8 {
    if page_size == 0 {
        5
    } else {
        page_size.clamp(1, 10) as u8
    }
}

fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    Some(c_str.to_string_lossy().into_owned())
}

fn into_c_string_ptr<T: Serialize>(value: &T) -> *mut c_char {
    let json = serde_json::to_string(value).unwrap_or_else(|err| {
        format!(
            "{{\"ok\":false,\"error\":{},\"consumed\":false,\"committed_text\":null,\"cleared\":false,\"generation\":0,\"raw_input\":\"\",\"preedit\":\"\",\"caret_position\":0,\"preedit_caret_byte\":0,\"page\":0,\"page_size\":5,\"highlighted_index\":0,\"has_more_pages\":false,\"candidates\":[]}}",
            serde_json::to_string(&err.to_string()).unwrap_or_else(|_| "\"serialization error\"".to_owned())
        )
    });
    match CString::new(json) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn error_response(message: impl Into<String>) -> SnapshotResponseDto {
    SnapshotResponseDto {
        ok: false,
        error: Some(message.into()),
        consumed: false,
        committed_text: None,
        cleared: false,
        generation: 0,
        raw_input: String::new(),
        preedit: String::new(),
        caret_position: 0,
        preedit_caret_byte: 0,
        page: 0,
        page_size: 5,
        highlighted_index: 0,
        has_more_pages: false,
        candidates: Vec::new(),
    }
}

fn map_caret_to_preedit_byte(
    editing_text: &str,
    phrase_prefix: &str,
    raw_preedit: &str,
    caret_pos: usize,
) -> usize {
    let clamped_caret = caret_pos.min(editing_text.len());
    if clamped_caret == 0 {
        return phrase_prefix.len();
    }
    if clamped_caret >= editing_text.len() {
        return phrase_prefix.len() + raw_preedit.len();
    }
    let raw_bytes = editing_text.as_bytes();
    let mut raw_idx = 0usize;
    let mut preedit_bytes = 0usize;
    for ch in raw_preedit.chars() {
        if raw_idx >= clamped_caret {
            break;
        }
        if ch == '\'' && raw_bytes.get(raw_idx) != Some(&b'\'') {
            preedit_bytes += 1;
            continue;
        }
        raw_idx += 1;
        preedit_bytes += ch.len_utf8();
    }
    phrase_prefix.len() + preedit_bytes
}

fn snapshot_from_view(
    view: View,
    consumed: bool,
    committed_text: Option<String>,
    cleared: bool,
    show_engine_annotation: bool,
    temp_english_backtick_prefix: bool,
) -> SnapshotResponseDto {
    let highlighted_index = view
        .candidates
        .iter()
        .position(|c| c.highlighted)
        .unwrap_or(0);
    let has_more_pages = view.page + 1 < view.page_count;
    let is_temp_eng = temp_english_backtick_prefix && view.local_mode == "temporary_english";
    let raw_input = if is_temp_eng {
        let suffix = view
            .editing_text
            .strip_prefix('Y')
            .unwrap_or(&view.editing_text);
        format!("`{suffix}")
    } else {
        view.editing_text.clone()
    };
    let input_len = raw_input.len();
    let caret_position = if is_temp_eng {
        view.caret_position.min(input_len)
    } else {
        view.caret_position.min(input_len)
    };
    let preedit = if is_temp_eng {
        raw_input.clone()
    } else if view.phrase_prefix.is_empty() {
        view.preedit.clone()
    } else {
        format!("{}{}", view.phrase_prefix, view.preedit)
    };
    let preedit_caret_byte = if is_temp_eng {
        caret_position
    } else {
        map_caret_to_preedit_byte(
            &view.editing_text,
            &view.phrase_prefix,
            &view.preedit,
            caret_position,
        )
    };
    let candidates = view
        .candidates
        .into_iter()
        .map(|c| {
            let comment = c.script_annotation.filter(|s| !s.is_empty()).or_else(|| {
                (show_engine_annotation && !c.annotation.is_empty()).then_some(c.annotation)
            });
            CandidateDto {
                text: c.text,
                comment,
                kind: "Phrase".to_owned(),
                input_len,
            }
        })
        .collect();
    SnapshotResponseDto {
        ok: true,
        error: None,
        consumed,
        committed_text,
        cleared,
        generation: view.generation,
        raw_input,
        preedit,
        caret_position,
        preedit_caret_byte,
        page: view.page,
        page_size: view.page_size,
        highlighted_index,
        has_more_pages,
        candidates,
    }
}

fn shuangpin_profile_for_name(name: &str) -> Option<ShuangpinProfileKind> {
    match name {
        "xiaohe" => Some(ShuangpinProfileKind::Xiaohe),
        "microsoft" => Some(ShuangpinProfileKind::Microsoft),
        "ziranma" => Some(ShuangpinProfileKind::Ziranma),
        "abc" => Some(ShuangpinProfileKind::SmartAbc),
        "shoudao" => Some(ShuangpinProfileKind::Shoudao),
        "custom" => Some(ShuangpinProfileKind::Custom),
        _ => None,
    }
}

fn is_known_pinyin_scheme(name: &str) -> bool {
    matches!(name, "quanpin" | "wubi" | "wubi_pinyin") || shuangpin_profile_for_name(name).is_some()
}

fn stage_file_if_needed(src: &Path, dst: &Path) -> std::io::Result<()> {
    let src_meta = fs::metadata(src)?;
    let src_len = src_meta.len();
    let src_mtime = src_meta.modified().ok();
    if let Ok(dst_meta) = fs::symlink_metadata(dst) {
        let dst_mtime = dst_meta.modified().ok();
        let mtime_ok = match (src_mtime, dst_mtime) {
            (Some(s), Some(d)) => d >= s,
            _ => true,
        };
        if dst_meta.is_file() && dst_meta.len() == src_len && mtime_ok {
            return Ok(());
        }
        let _ = fs::remove_file(dst);
    }
    fs::copy(src, dst)?;
    Ok(())
}

#[derive(Debug, Clone)]
struct SessionRoots {
    resources: PathBuf,
    user: PathBuf,
    cache: PathBuf,
    dictionaries: PathBuf,
}

fn absolute_explicit_root(raw: &str, label: &str) -> Result<PathBuf, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(format!("{label} is empty"));
    }
    let raw_path = PathBuf::from(trimmed);
    if raw_path.is_absolute() {
        Ok(raw_path)
    } else {
        Ok(std::env::current_dir()
            .map_err(|e| format!("failed to resolve {label} against cwd: {e}"))?
            .join(raw_path))
    }
}

fn resolved_explicit_root(absolute: &Path, label: &str) -> Result<PathBuf, String> {
    weakly_canonical(absolute)
        .map_err(|e| format!("failed to resolve {label} {}: {e}", absolute.display()))
}

fn prepare_explicit_roots(
    resources: &str,
    user: &str,
    cache: &str,
    dictionaries: &str,
) -> Result<SessionRoots, String> {
    let requested = [
        (
            "resources_dir",
            absolute_explicit_root(resources, "resources_dir")?,
        ),
        (
            "user_data_dir",
            absolute_explicit_root(user, "user_data_dir")?,
        ),
        ("cache_dir", absolute_explicit_root(cache, "cache_dir")?),
        (
            "dictionaries_dir",
            absolute_explicit_root(dictionaries, "dictionaries_dir")?,
        ),
    ];
    for (label, path) in &requested {
        reject_redirected_directory(path)
            .map_err(|e| format!("failed to validate {label} {}: {e}", path.display()))?;
    }
    let planned = SessionRoots {
        resources: resolved_explicit_root(&requested[0].1, requested[0].0)?,
        user: resolved_explicit_root(&requested[1].1, requested[1].0)?,
        cache: resolved_explicit_root(&requested[2].1, requested[2].0)?,
        dictionaries: resolved_explicit_root(&requested[3].1, requested[3].0)?,
    };
    validate_explicit_roots(&planned)?;

    let roots = SessionRoots {
        resources: materialize_explicit_root(&planned.resources, "resources_dir")?,
        user: materialize_explicit_root(&planned.user, "user_data_dir")?,
        cache: materialize_explicit_root(&planned.cache, "cache_dir")?,
        dictionaries: materialize_explicit_root(&planned.dictionaries, "dictionaries_dir")?,
    };
    for (label, path) in &requested {
        reject_redirected_directory(path).map_err(|e| {
            format!(
                "failed to revalidate {label} {} after creation: {e}",
                path.display()
            )
        })?;
    }
    // Re-check after following any symlink changes made between planning and creation.
    validate_explicit_roots(&roots)?;
    Ok(roots)
}

fn validate_explicit_roots(roots: &SessionRoots) -> Result<(), String> {
    for (left, right) in [
        (&roots.resources, &roots.user),
        (&roots.resources, &roots.cache),
        (&roots.resources, &roots.dictionaries),
        (&roots.user, &roots.cache),
        (&roots.user, &roots.dictionaries),
        (&roots.cache, &roots.dictionaries),
    ] {
        if roots_overlap(left, right) {
            return Err(format!(
                "session roots overlap: {} and {}",
                left.display(),
                right.display()
            ));
        }
    }
    Ok(())
}

fn materialize_explicit_root(path: &Path, label: &str) -> Result<PathBuf, String> {
    fs::create_dir_all(path)
        .map_err(|e| format!("failed to create {label} {}: {e}", path.display()))?;
    fs::canonicalize(path)
        .map_err(|e| format!("failed to canonicalize {label} {}: {e}", path.display()))
}

fn resolve_pinyin_source(raw: &str) -> Result<PathBuf, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("pinyin_db_path is empty".to_owned());
    }
    let source = fs::canonicalize(trimmed)
        .map_err(|e| format!("failed to resolve pinyin_db_path {trimmed}: {e}"))?;
    if !source.is_file() {
        return Err(format!(
            "pinyin_db_path is not a file: {}",
            source.display()
        ));
    }
    Ok(source)
}

fn reconcile_quick_phrases(
    source: &Path,
    staged: &Path,
    user_journal: &Path,
    only_when_tracking: bool,
) -> Result<bool, String> {
    if source == staged {
        return Ok(false);
    }
    let mut conn = Connection::open(staged)
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: open database: {e}"))?;
    let has_legacy_tracking: bool = conn
        .query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM sqlite_master
                 WHERE type='table' AND name='owl_host_quick_phrases'
             )",
            [],
            |row| row.get(0),
        )
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: inspect legacy tracking: {e}"))?;
    if only_when_tracking && !has_legacy_tracking {
        return Ok(false);
    }

    conn.execute(
        "ATTACH DATABASE ?1 AS owl_seed_source",
        [source.to_string_lossy().as_ref()],
    )
    .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: attach seed source: {e}"))?;
    if let Some(moved) = msime_engine::quarantine_corrupt_journal(user_journal)
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: quarantine user journal: {e}"))?
    {
        eprintln!(
            "msime: user dictionary journal is not a database, moved aside to {}",
            moved.display()
        );
    }
    let has_journal = user_journal.is_file();
    if has_journal {
        conn.execute(
            "ATTACH DATABASE ?1 AS personal_journal",
            [user_journal.to_string_lossy().as_ref()],
        )
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: attach user journal: {e}"))?;
    }
    let transaction = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: begin transaction: {e}"))?;
    transaction
        .execute_batch(
            "DROP TABLE IF EXISTS quick_parases_migrated;
             CREATE TABLE quick_parases_migrated (
                 \"key\" TEXT,
                 \"value\" TEXT,
                 \"weight\" INTEGER DEFAULT 0
             );
             INSERT INTO quick_parases_migrated (\"key\", \"value\", \"weight\")
             SELECT \"key\", \"value\", \"weight\"
             FROM owl_seed_source.quick_parases;",
        )
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: copy base rows: {e}"))?;

    let has_operations = if has_journal {
        transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM personal_journal.sqlite_master
                     WHERE type='table' AND name='user_dictionary_operations'
                 )",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: inspect user journal: {e}"))?
    } else {
        false
    };
    if has_operations {
        let operations = {
            let mut statement = transaction
                .prepare(
                    "SELECT \"key\", \"value\", \"operation\", \"weight\"
                     FROM personal_journal.user_dictionary_operations
                     WHERE dictionary='quick'
                     ORDER BY updated_at, rowid",
                )
                .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: read user journal: {e}"))?;
            let operations = statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, rusqlite::types::Value>(0)?,
                        row.get::<_, rusqlite::types::Value>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<i64>>(3)?.unwrap_or(0),
                    ))
                })
                .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: read user journal: {e}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: read user journal: {e}"))?;
            operations
        };
        for (key, value, operation, weight) in operations {
            match operation.as_str() {
                "delete" => {
                    transaction
                        .execute(
                            "DELETE FROM quick_parases_migrated
                             WHERE \"key\"=?1 AND \"value\"=?2",
                            rusqlite::params![key, value],
                        )
                        .map_err(|e| {
                            format!("HOST_PHRASE_CLEANUP_FAILED: replay user deletion: {e}")
                        })?;
                }
                "upsert" => {
                    let changed = transaction
                        .execute(
                            "UPDATE quick_parases_migrated SET \"weight\"=?1
                             WHERE \"key\"=?2 AND \"value\"=?3",
                            rusqlite::params![weight, key, value],
                        )
                        .map_err(|e| {
                            format!("HOST_PHRASE_CLEANUP_FAILED: replay user weight: {e}")
                        })?;
                    if changed == 0 {
                        transaction
                            .execute(
                                "INSERT INTO quick_parases_migrated
                                 (\"key\", \"value\", \"weight\") VALUES (?1, ?2, ?3)",
                                rusqlite::params![key, value, weight],
                            )
                            .map_err(|e| {
                                format!("HOST_PHRASE_CLEANUP_FAILED: replay user row: {e}")
                            })?;
                    }
                }
                _ => {}
            }
        }
    }
    transaction
        .execute_batch(
            "DROP TABLE quick_parases;
             ALTER TABLE quick_parases_migrated RENAME TO quick_parases;
             DROP TABLE IF EXISTS owl_host_quick_phrases;
             CREATE INDEX idx_quick_parases_key_weight
             ON quick_parases (\"key\", \"weight\" DESC);",
        )
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: replace base rows: {e}"))?;
    transaction
        .commit()
        .map_err(|e| format!("HOST_PHRASE_CLEANUP_FAILED: commit: {e}"))?;
    Ok(true)
}

fn product_engine_options(
    resources: &Path,
    user_data: &Path,
    cache: &Path,
    dictionaries: &Path,
    page_size: u8,
) -> EngineOptions {
    EngineOptions {
        resources: resources.to_string_lossy().into_owned(),
        user_data: user_data.to_string_lossy().into_owned(),
        cache: cache.to_string_lossy().into_owned(),
        dictionaries: dictionaries.to_string_lossy().into_owned(),
        scheme: SchemeType::Quanpin as u8,
        enabled_schemes: SchemeSet::ALL,
        shuangpin_profile: ShuangpinProfileKind::Xiaohe as u8,
        shuangpin_custom_profile: None,
        shuangpin_preedit_uses_raw: true,
        single_character_only: false,
        learning: true,
        learn_english_on_enter: true,
        autocorrect_transposition: true,
        autocorrect_neighbor: true,
        fuzzy_pinyin_rules: 0,
        wubi_mixed_pinyin: false,
        wubi_z_wildcard: false,
        wubi_profile: WubiProfileKind::Wubi86 as u8,
        helpcode: false,
        show_helpcode: false,
        shuangpin_helpcode_modes: ShuangpinHelpcodeModes::default(),
        helpcode_schema: "ziranma".to_owned(),
        helpcode_trigger_key: None,
        helpcode_table: Some(Arc::new(HelpcodeKeymap::default())),
        helpcode_fallback_resources: None,
        chinese_punctuation: true,
        paired_punctuation: true,
        punctuation_lock: 0,
        corner_quotes: false,
        hollow_brackets: false,
        enumeration_comma_backslash: true,
        enumeration_comma_slash: false,
        frequency_mode: FrequencyAdjustmentMode::Promote.name().to_owned(),
        frequency_trigger_count: 1,
        frequency_linear_step: 1,
        mixed_candidates: true,
        mixed_english: true,
        english_minimum_prefix: 2,
        english_first_page_count: 3,
        mixed_emoji: false,
        mixed_kaomoji: false,
        mixed_symbols: false,
        mixed_japanese: false,
        local_unicode: true,
        local_date_time: false,
        local_date_time_inline: false,
        local_date_time_menu: false,
        local_quick_phrase: true,
        local_emoji: false,
        local_kaomoji: false,
        local_super_jianpin: true,
        local_temporary_english: true,
        local_temporary_japanese: false,
        local_expression: false,
        local_command: false,
        local_mention: false,
        local_chaizi: false,
        local_symbol: false,
        local_shift_letter_entry: true,
        chaizi_traditional_output: false,
        command_table: Vec::new(),
        plugin_commands: Vec::new(),
        mention_entries: Vec::new(),
        quick_phrase_table: Vec::new(),
        quick_phrase_candidates: true,
        quick_phrase_frequency: true,
        sentence_association: SentenceAssociationOptions::default(),
        rescoring_context: String::new(),
        sentence_alternatives: false,
        first_page_rows: usize::from(page_size),
        vietnamese_input_method: 0,
        vietnamese_tone_style: 0,
        cantonese_dictionary: String::new(),
        zhuyin_dictionary: String::new(),
        stroke_dictionary: String::new(),
        japanese_dictionary: String::new(),
        wubi_dictionary: String::new(),
    }
}

impl OwlMsimeSession {
    pub fn create(
        pinyin_db_path: &str,
        english_db_path: &str,
        user_data_dir: &str,
        page_size: u32,
    ) -> Result<Self, String> {
        let pinyin_src = resolve_pinyin_source(pinyin_db_path)?;
        let (base_dir, temp_dir) = if user_data_dir.trim().is_empty() {
            let tmp = TempDir::new().map_err(|e| format!("failed to create temp dir: {e}"))?;
            let canonical = fs::canonicalize(tmp.path())
                .map_err(|e| format!("failed to canonicalize temp dir: {e}"))?;
            (canonical, Some(tmp))
        } else {
            let dir = PathBuf::from(user_data_dir.trim());
            fs::create_dir_all(&dir)
                .map_err(|e| format!("failed to create user_data_dir {}: {e}", dir.display()))?;
            let canonical = fs::canonicalize(&dir)
                .map_err(|e| format!("failed to canonicalize user_data_dir: {e}"))?;
            (canonical, None)
        };
        let roots = prepare_explicit_roots(
            &base_dir.join("msime-resources").to_string_lossy(),
            &base_dir.join("msime-user").to_string_lossy(),
            &base_dir.join("msime-cache").to_string_lossy(),
            &base_dir.join("msime-dicts").to_string_lossy(),
        )?;
        Self::create_with_prepared_roots(&pinyin_src, english_db_path, roots, page_size, temp_dir)
    }

    pub fn create_with_explicit_roots(
        pinyin_db_path: &str,
        english_db_path: &str,
        resources_dir: &str,
        user_data_dir: &str,
        cache_dir: &str,
        dictionaries_dir: &str,
        page_size: u32,
    ) -> Result<Self, String> {
        let pinyin_src = resolve_pinyin_source(pinyin_db_path)?;
        let roots =
            prepare_explicit_roots(resources_dir, user_data_dir, cache_dir, dictionaries_dir)?;
        Self::create_with_prepared_roots(&pinyin_src, english_db_path, roots, page_size, None)
    }

    pub fn create_with_generation(
        resources_dir: &str,
        user_data_dir: &str,
        cache_dir: &str,
        content_id: &str,
        page_size: u32,
    ) -> Result<Self, String> {
        for name in [
            msime_engine::assets::MAIN_DICTIONARY,
            msime_engine::assets::ENGLISH_DICTIONARY,
        ] {
            let path = Path::new(resources_dir).join(name);
            let metadata = fs::symlink_metadata(&path).map_err(|e| {
                format!(
                    "generation resource {name} is missing at {}: {e}",
                    path.display()
                )
            })?;
            if !metadata.file_type().is_file() {
                return Err(format!(
                    "generation resource {name} is not a regular file: {}",
                    path.display()
                ));
            }
        }

        let prepared = prepare_options(resources_dir, user_data_dir, cache_dir, content_id)
            .map_err(|e| format!("failed to prepare dictionary generation: {e}"))?;
        let resources = PathBuf::from(&prepared.resources);
        let user = PathBuf::from(&prepared.user_data);
        let cache = PathBuf::from(&prepared.cache);
        let dictionaries = PathBuf::from(&prepared.dictionaries);
        let source_pinyin = resources.join(msime_engine::assets::MAIN_DICTIONARY);
        let staged_pinyin = dictionaries.join(msime_engine::assets::MAIN_DICTIONARY);
        reconcile_quick_phrases(
            &source_pinyin,
            &staged_pinyin,
            &user.join(msime_engine::assets::USER_JOURNAL),
            false,
        )?;

        let page_size = clamp_page_size(page_size);
        let options = product_engine_options(&resources, &user, &cache, &dictionaries, page_size);
        Self::create_with_options(options, source_pinyin, staged_pinyin, page_size, None)
    }

    fn create_with_prepared_roots(
        pinyin_src: &Path,
        english_db_path: &str,
        roots: SessionRoots,
        page_size: u32,
        temp_dir: Option<TempDir>,
    ) -> Result<Self, String> {
        let staged_pinyin = roots.dictionaries.join("msime-pinyin.db");
        stage_file_if_needed(pinyin_src, &staged_pinyin)
            .map_err(|e| format!("failed to stage msime-pinyin.db: {e}"))?;
        let user_journal = roots.user.join(msime_engine::assets::USER_JOURNAL);
        reconcile_quick_phrases(pinyin_src, &staged_pinyin, &user_journal, false)?;

        let staged_english = roots.dictionaries.join("msime-english.db");
        let trimmed_english = english_db_path.trim();
        if !trimmed_english.is_empty() && Path::new(trimmed_english).is_file() {
            let english_src = fs::canonicalize(trimmed_english)
                .map_err(|e| format!("failed to resolve english_db_path: {e}"))?;
            stage_file_if_needed(&english_src, &staged_english)
                .map_err(|e| format!("failed to stage msime-english.db: {e}"))?;
        } else if !staged_english.is_file() {
            ensure_english_schema(&staged_english)
                .map_err(|e| format!("failed to initialize msime-english.db: {e}"))?;
        }

        let page_size = clamp_page_size(page_size);
        let options = product_engine_options(
            &roots.resources,
            &roots.user,
            &roots.cache,
            &roots.dictionaries,
            page_size,
        );
        Self::create_with_options(
            options,
            pinyin_src.to_path_buf(),
            staged_pinyin,
            page_size,
            temp_dir,
        )
    }

    fn create_with_options(
        options: EngineOptions,
        source_pinyin_path: PathBuf,
        staged_pinyin_path: PathBuf,
        page_size: u8,
        temp_dir: Option<TempDir>,
    ) -> Result<Self, String> {
        let engine_session = EngineSession::new(&options).map_err(|e| e.to_string())?;
        let mut runtime = Runtime::new(engine_session, page_size).map_err(|e| e.to_string())?;
        runtime.set_phrase_preedit(true);
        let _ = runtime.focus(true).map_err(|e| e.to_string())?;
        let pinned_state = Arc::new(Mutex::new(OwlPinnedState {
            words: HashMap::new(),
            enabled: true,
            traditional: false,
            active_input: String::new(),
            caret_at_end: true,
            input_mode: "chinese".to_owned(),
            pinyin_scheme: "quanpin".to_owned(),
            page_size: usize::from(page_size),
            wubi_single_first: false,
            wubi_z_reverse_lookup: true,
        }));
        runtime.set_candidate_transform(Some(Box::new(OwlPinnedTransform {
            state: Arc::clone(&pinned_state),
        })));

        Ok(Self {
            runtime,
            options,
            source_pinyin_path,
            staged_pinyin_path,
            page_size,
            input_mode: "chinese".to_owned(),
            pinyin_scheme: "quanpin".to_owned(),
            wubi_code_hint: false,
            wubi_auto_clear: false,
            wubi_candidate_mode: "normal".to_owned(),
            wubi_z_reverse_lookup: true,
            wubi_english_channel: false,
            wubi_user_dict_learning: false,
            pinned_state,
            _temp_dir: temp_dir,
        })
    }

    fn show_engine_annotation(&self, view: &View) -> bool {
        if self.input_mode == "wubi" {
            let in_z_lookup = !self.options.wubi_mixed_pinyin
                && self.wubi_z_reverse_lookup
                && view.editing_text.starts_with('z');
            in_z_lookup || self.wubi_code_hint
        } else {
            false
        }
    }

    fn temp_english_backtick(&self, view: &View) -> bool {
        self.input_mode == "wubi"
            && self.wubi_english_channel
            && view.local_mode == "temporary_english"
    }

    fn build_snapshot(
        &self,
        view: View,
        consumed: bool,
        committed_text: Option<String>,
        cleared: bool,
    ) -> SnapshotResponseDto {
        let show_ann = self.show_engine_annotation(&view);
        let backtick = self.temp_english_backtick(&view);
        snapshot_from_view(view, consumed, committed_text, cleared, show_ann, backtick)
    }

    pub fn snapshot(&self) -> SnapshotResponseDto {
        self.build_snapshot(self.runtime.view(), false, None, false)
    }

    fn sync_pinned_state_for_upcoming_input(&self, next_input: String, caret_at_end: bool) {
        if let Ok(mut guard) = self.pinned_state.lock() {
            guard.enabled = self.input_mode == "chinese" && self.pinyin_scheme == "quanpin";
            guard.active_input = next_input;
            guard.caret_at_end = caret_at_end;
            guard.input_mode = self.input_mode.clone();
            guard.pinyin_scheme = self.pinyin_scheme.clone();
            guard.page_size = usize::from(self.page_size);
            guard.wubi_single_first = self.wubi_candidate_mode == "single_first";
            guard.wubi_z_reverse_lookup = self.wubi_z_reverse_lookup;
        }
    }

    fn sync_pinned_state_from_view(&self, view: &View) {
        if let Ok(mut guard) = self.pinned_state.lock() {
            guard.enabled = self.input_mode == "chinese" && self.pinyin_scheme == "quanpin";
            guard.active_input = view.editing_text.clone();
            guard.caret_at_end =
                view.phrase_prefix.is_empty() && view.caret_position == view.editing_text.len();
            guard.input_mode = self.input_mode.clone();
            guard.pinyin_scheme = self.pinyin_scheme.clone();
            guard.page_size = usize::from(self.page_size);
            guard.wubi_single_first = self.wubi_candidate_mode == "single_first";
            guard.wubi_z_reverse_lookup = self.wubi_z_reverse_lookup;
        }
    }

    fn rebuild_engine_if_needed(&mut self) -> Result<(), String> {
        self.rebuild_engine_if_needed_with_force(false)
    }

    fn rebuild_engine_if_needed_with_force(&mut self, force: bool) -> Result<(), String> {
        let desired_scheme = if self.input_mode == "wubi" {
            SchemeType::Wubi as u8
        } else if shuangpin_profile_for_name(&self.pinyin_scheme).is_some() {
            SchemeType::Shuangpin as u8
        } else {
            SchemeType::Quanpin as u8
        };
        let desired_profile = shuangpin_profile_for_name(&self.pinyin_scheme)
            .unwrap_or(ShuangpinProfileKind::Xiaohe) as u8;
        let desired_wubi_mixed = self.input_mode == "wubi" && self.pinyin_scheme == "wubi_pinyin";
        let desired_single_only =
            self.input_mode == "wubi" && self.wubi_candidate_mode == "single_only";
        let desired_learning = if self.input_mode == "wubi" {
            self.wubi_user_dict_learning
        } else {
            true
        };

        if force
            || self.options.scheme != desired_scheme
            || self.options.shuangpin_profile != desired_profile
            || self.options.wubi_mixed_pinyin != desired_wubi_mixed
            || self.options.single_character_only != desired_single_only
            || self.options.learning != desired_learning
        {
            let _ = self.runtime.dispatch(Action::Command(Command::Cancel));
            self.options.scheme = desired_scheme;
            self.options.shuangpin_profile = desired_profile;
            self.options.wubi_mixed_pinyin = desired_wubi_mixed;
            self.options.single_character_only = desired_single_only;
            self.options.learning = desired_learning;
            self.options.first_page_rows = usize::from(self.page_size);
            let mut new_engine = EngineSession::new(&self.options).map_err(|e| e.to_string())?;
            new_engine.set_wubi_z_pinyin_lookup(self.wubi_z_reverse_lookup);
            self.runtime
                .replace_engine(new_engine, self.page_size)
                .map_err(|e| e.to_string())?;
        }
        let _ = self
            .runtime
            .set_wubi_z_pinyin_lookup(self.wubi_z_reverse_lookup);
        let dedicated_english = self.input_mode == "english";
        let _ = self
            .runtime
            .set_dedicated_english(dedicated_english)
            .map_err(|e| e.to_string())?;
        let view = self.runtime.view();
        self.sync_pinned_state_from_view(&view);
        Ok(())
    }

    fn force_rebuild_engine(&mut self) -> Result<(), String> {
        let _ = self.runtime.dispatch(Action::Command(Command::Cancel));
        self.options.first_page_rows = usize::from(self.page_size);
        let mut new_engine = EngineSession::new(&self.options).map_err(|e| e.to_string())?;
        new_engine.set_wubi_z_pinyin_lookup(self.wubi_z_reverse_lookup);
        self.runtime
            .replace_engine(new_engine, self.page_size)
            .map_err(|e| e.to_string())?;
        let view = self.runtime.view();
        self.sync_pinned_state_from_view(&view);
        Ok(())
    }

    pub fn handle_action_json(&mut self, action_json: &str) -> SnapshotResponseDto {
        let payload: ActionPayload = match serde_json::from_str(action_json) {
            Ok(p) => p,
            Err(err) => return error_response(format!("invalid action_json: {err}")),
        };

        match payload.op.as_str() {
            "insert" => {
                let Some(ch_str) = payload.ch.as_deref() else {
                    return error_response("insert requires ch");
                };
                let Some(ch) = ch_str.chars().next() else {
                    return error_response("insert ch is empty");
                };
                if !ch.is_ascii() {
                    return self.build_snapshot(self.runtime.view(), false, None, false);
                }
                if ch == '`'
                    && self.input_mode == "wubi"
                    && self.wubi_english_channel
                    && self.runtime.view().editing_text.is_empty()
                {
                    self.sync_pinned_state_for_upcoming_input(String::new(), true);
                    return match self.runtime.dispatch(Action::Character {
                        value: b'Y',
                        shift: true,
                    }) {
                        Ok(transition) => {
                            self.sync_pinned_state_from_view(&transition.view);
                            self.build_snapshot(
                                transition.view,
                                transition.handled,
                                transition.commit,
                                false,
                            )
                        }
                        Err(err) => error_response(err.to_string()),
                    };
                }
                let is_wubi_letter =
                    self.input_mode == "wubi" && ch.is_ascii_lowercase() && ch != 'z';
                let byte = ch as u8;
                let shift = byte.is_ascii_uppercase();
                let before = self.runtime.view();
                let caret = before.caret_position.min(before.editing_text.len());
                let mut next_input = before.editing_text.clone();
                next_input.insert(caret, ch);
                let next_caret_at_end =
                    before.phrase_prefix.is_empty() && (caret + 1 == next_input.len());
                self.sync_pinned_state_for_upcoming_input(next_input, next_caret_at_end);
                match self
                    .runtime
                    .dispatch(Action::Character { value: byte, shift })
                {
                    Ok(transition) => {
                        if is_wubi_letter
                            && self.wubi_auto_clear
                            && transition.commit.is_none()
                            && transition.view.local_mode == "none"
                            && transition.view.editing_text.len() == 4
                            && transition.view.candidates.is_empty()
                        {
                            self.sync_pinned_state_for_upcoming_input(String::new(), true);
                            if let Ok(cleared_t) =
                                self.runtime.dispatch(Action::Command(Command::Cancel))
                            {
                                self.sync_pinned_state_from_view(&cleared_t.view);
                                return self.build_snapshot(cleared_t.view, true, None, true);
                            }
                        }
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "backspace" => {
                let before = self.runtime.view();
                let caret = before.caret_position.min(before.editing_text.len());
                let mut next_input = before.editing_text.clone();
                let next_caret_at_end = if caret > 0 && caret <= next_input.len() {
                    next_input.remove(caret - 1);
                    before.phrase_prefix.is_empty() && (caret - 1 == next_input.len())
                } else {
                    false
                };
                self.sync_pinned_state_for_upcoming_input(next_input, next_caret_at_end);
                match self.runtime.dispatch(Action::Command(Command::Backspace)) {
                    Ok(transition) => {
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "punctuation" => {
                let Some(ch_str) = payload.ch.as_deref() else {
                    return error_response("punctuation requires ch");
                };
                let Some(ch) = ch_str.chars().next() else {
                    return error_response("punctuation ch is empty");
                };
                if !ch.is_ascii() {
                    return self.build_snapshot(self.runtime.view(), false, None, false);
                }
                let byte = ch as u8;
                let use_ascii = payload.ascii.unwrap_or(false) || !self.options.chinese_punctuation;
                let in_temp_eng = self.temp_english_backtick(&self.runtime.view());
                let action = if use_ascii {
                    Action::PunctuationAscii(byte)
                } else {
                    Action::Punctuation(byte)
                };
                match self.runtime.dispatch(action) {
                    Ok(mut transition) => {
                        if in_temp_eng {
                            if let Some(ref mut c) = transition.commit {
                                if let Some(stripped) = c.strip_prefix('Y') {
                                    *c = stripped.to_owned();
                                }
                            }
                        }
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "move_caret" => {
                let cmd = match payload.target.as_deref() {
                    Some("home") => Command::MoveHome,
                    Some("end") => Command::MoveEnd,
                    Some("left") => Command::MoveLeft,
                    Some("right") => Command::MoveRight,
                    _ => {
                        let delta = payload.delta.unwrap_or(0);
                        if delta < 0 {
                            Command::MoveLeft
                        } else if delta > 0 {
                            Command::MoveRight
                        } else {
                            return self.build_snapshot(self.runtime.view(), false, None, false);
                        }
                    }
                };
                let before = self.runtime.view();
                let next_caret = match cmd {
                    Command::MoveHome => 0,
                    Command::MoveEnd => before.editing_text.len(),
                    Command::MoveLeft => before.caret_position.saturating_sub(1),
                    Command::MoveRight => {
                        (before.caret_position + 1).min(before.editing_text.len())
                    }
                    _ => before.caret_position,
                };
                self.sync_pinned_state_for_upcoming_input(
                    before.editing_text.clone(),
                    before.phrase_prefix.is_empty() && next_caret == before.editing_text.len(),
                );
                match self.runtime.dispatch(Action::Command(cmd)) {
                    Ok(transition) => {
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "set_caret" => {
                let Some(pos) = payload.pos else {
                    return error_response("set_caret requires pos");
                };
                let before = self.runtime.view();
                let clamped = pos.min(before.editing_text.len());
                self.sync_pinned_state_for_upcoming_input(
                    before.editing_text.clone(),
                    before.phrase_prefix.is_empty() && clamped == before.editing_text.len(),
                );
                if clamped == before.editing_text.len() {
                    return match self.runtime.dispatch(Action::Command(Command::MoveEnd)) {
                        Ok(transition) => {
                            self.sync_pinned_state_from_view(&transition.view);
                            self.build_snapshot(transition.view, true, transition.commit, false)
                        }
                        Err(err) => error_response(err.to_string()),
                    };
                }
                match self.runtime.set_caret(Some(clamped)) {
                    Ok(()) => {
                        let view = self.runtime.view();
                        self.sync_pinned_state_from_view(&view);
                        self.build_snapshot(view, true, None, false)
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "commit_raw" => {
                let in_temp_eng = self.temp_english_backtick(&self.runtime.view());
                match self.runtime.dispatch(Action::Command(Command::CommitRaw)) {
                    Ok(mut transition) => {
                        if in_temp_eng {
                            if let Some(ref mut c) = transition.commit {
                                if let Some(stripped) = c.strip_prefix('Y') {
                                    *c = format!("`{stripped}");
                                }
                            }
                        }
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "space" => {
                let in_temp_eng = self.temp_english_backtick(&self.runtime.view());
                match self.runtime.dispatch(Action::SelectHighlighted) {
                    Ok(mut transition) => {
                        if in_temp_eng {
                            if let Some(ref mut c) = transition.commit {
                                if *c == "Y" {
                                    *c = "`".to_owned();
                                } else if let Some(stripped) = c.strip_prefix('Y') {
                                    *c = stripped.to_owned();
                                }
                            }
                        }
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "clear" => {
                let had_input = !self.runtime.view().editing_text.is_empty();
                self.sync_pinned_state_for_upcoming_input(String::new(), true);
                match self.runtime.dispatch(Action::Command(Command::Cancel)) {
                    Ok(transition) => self.build_snapshot(
                        transition.view,
                        transition.handled || had_input,
                        transition.commit,
                        true,
                    ),
                    Err(err) => error_response(err.to_string()),
                }
            }
            "move_highlight" => {
                let delta = payload.delta.unwrap_or(0);
                if delta == 0 {
                    return self.build_snapshot(self.runtime.view(), true, None, false);
                }
                let steps = delta.unsigned_abs() as usize;
                let mut last_transition = None;
                for _ in 0..steps {
                    let action = if delta > 0 {
                        Action::NextCandidate
                    } else {
                        Action::PreviousCandidate
                    };
                    match self.runtime.dispatch(action) {
                        Ok(t) => last_transition = Some(t),
                        Err(err) => return error_response(err.to_string()),
                    }
                }
                match last_transition {
                    Some(t) => self.build_snapshot(t.view, t.handled, t.commit, false),
                    None => self.build_snapshot(self.runtime.view(), false, None, false),
                }
            }
            "turn_page" => {
                let delta = payload.delta.unwrap_or(0);
                if delta == 0 {
                    return self.build_snapshot(self.runtime.view(), false, None, false);
                }
                let before_page = self.runtime.view().page;
                let steps = delta.unsigned_abs() as usize;
                let mut last_transition = None;
                for _ in 0..steps {
                    let action = if delta > 0 {
                        Action::NextPage
                    } else {
                        Action::PreviousPage
                    };
                    match self.runtime.dispatch(action) {
                        Ok(t) => last_transition = Some(t),
                        Err(err) => return error_response(err.to_string()),
                    }
                }
                match last_transition {
                    Some(t) => {
                        let moved = t.view.page != before_page;
                        self.build_snapshot(t.view, t.handled && moved, t.commit, false)
                    }
                    None => self.build_snapshot(self.runtime.view(), false, None, false),
                }
            }
            "select_visible" => {
                let Some(index) = payload.index else {
                    return error_response("select_visible requires index");
                };
                let view = self.runtime.view();
                let Some(candidate) = view.candidates.get(index) else {
                    return self.build_snapshot(view, false, None, false);
                };
                let id = candidate.id;
                match self.runtime.dispatch(Action::Select(id)) {
                    Ok(transition) => {
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "select_token" => {
                let Some(index) = payload.index else {
                    return error_response("select_token requires index");
                };
                let view = self.runtime.view();
                let token_gen = payload.generation.unwrap_or(view.generation);
                if payload.generation.is_some() && token_gen != view.generation {
                    return self.build_snapshot(view, false, None, false);
                }
                let is_absolute = payload.is_absolute.unwrap_or(false);
                let action = if is_absolute {
                    Action::SelectAnyCandidate(CandidateId {
                        session: view.session,
                        generation: token_gen,
                        index,
                    })
                } else {
                    let Some(candidate) = view.candidates.get(index) else {
                        return self.build_snapshot(view, false, None, false);
                    };
                    Action::Select(candidate.id)
                };
                match self.runtime.dispatch(action) {
                    Ok(transition) => {
                        self.sync_pinned_state_from_view(&transition.view);
                        self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(_) => self.build_snapshot(self.runtime.view(), false, None, false),
                }
            }
            "peek_candidates" => {
                let start = payload.start.unwrap_or(0);
                let count = payload.count.unwrap_or(0);
                let all = self.runtime.all_candidates_cached();
                let view = self.runtime.view();
                let show_ann = self.show_engine_annotation(&view);
                let input_len = view.editing_text.len();
                let mut dto = self.build_snapshot(view, true, None, false);
                dto.generation = all.generation;
                dto.candidates = all
                    .candidates
                    .into_iter()
                    .skip(start)
                    .take(count)
                    .map(|c| {
                        let comment = c.script_annotation.filter(|s| !s.is_empty()).or_else(|| {
                            (show_ann && !c.annotation.is_empty()).then_some(c.annotation)
                        });
                        CandidateDto {
                            text: c.text,
                            comment,
                            kind: "Phrase".to_owned(),
                            input_len,
                        }
                    })
                    .collect();
                dto
            }
            "set_pinned_words" => {
                let packed = payload.text.unwrap_or_default();
                let mut parsed: HashMap<(String, bool), Vec<String>> = HashMap::new();
                for line in packed.lines() {
                    let mut parts = line.splitn(3, '\t');
                    let (Some(code), Some(mode), Some(word)) =
                        (parts.next(), parts.next(), parts.next())
                    else {
                        continue;
                    };
                    if code.is_empty() || word.is_empty() {
                        continue;
                    }
                    let trad = mode == "1";
                    parsed
                        .entry((code.to_owned(), trad))
                        .or_default()
                        .push(word.to_owned());
                }
                if let Ok(mut guard) = self.pinned_state.lock() {
                    guard.words = parsed;
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_host_phrases" => {
                let packed = payload.text.unwrap_or_default();
                let mut seen = HashSet::new();
                let mut rows: Vec<(String, String, i64)> = Vec::new();
                for line in packed.lines() {
                    let trimmed = line.trim();
                    if trimmed.is_empty() || trimmed.starts_with('#') {
                        continue;
                    }
                    let parts: Vec<&str> = line.split('\t').collect();
                    if parts.len() < 2 {
                        continue;
                    }
                    let phrase = parts[0].trim();
                    let code = parts[1].trim().to_ascii_lowercase();
                    if phrase.is_empty()
                        || code.is_empty()
                        || !code.chars().all(|c| c.is_ascii_alphabetic())
                    {
                        continue;
                    }
                    let weight = parts
                        .get(2)
                        .and_then(|w| w.trim().parse::<i64>().ok())
                        .unwrap_or(1_000_000)
                        .max(1);
                    let row = (code, phrase.to_owned(), weight);
                    if seen.insert((row.0.clone(), row.1.clone())) {
                        rows.push(row);
                    }
                }

                // Host phrases are merged from EngineOptions at query time. Importing them into
                // quick_parases loses provenance and can delete or duplicate identical base rows.
                // Migrate rows written by the earlier implementation, then keep the host table
                // solely in runtime state.
                let user_journal =
                    Path::new(&self.options.user_data).join(msime_engine::assets::USER_JOURNAL);
                if let Err(err) = reconcile_quick_phrases(
                    &self.source_pinyin_path,
                    &self.staged_pinyin_path,
                    &user_journal,
                    true,
                ) {
                    return error_response(err);
                }
                let previous_table = std::mem::replace(
                    &mut self.options.quick_phrase_table,
                    rows.iter()
                        .map(|(code, text, _)| QuickPhraseEntry {
                            key: code.clone(),
                            text: text.clone(),
                        })
                        .collect(),
                );
                if let Err(err) = self.force_rebuild_engine() {
                    self.options.quick_phrase_table = previous_table;
                    let _ = self.force_rebuild_engine();
                    return error_response(err);
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_fuzzy_rules" => {
                let mask = payload.mask.unwrap_or(0) & fuzzy_rule::ALL;
                if self.options.fuzzy_pinyin_rules != mask {
                    self.options.fuzzy_pinyin_rules = mask;
                    if let Err(err) = self.force_rebuild_engine() {
                        return error_response(err);
                    }
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_wubi_candidate_mode" => {
                let Some(mode) = payload.mode else {
                    return error_response("set_wubi_candidate_mode requires mode");
                };
                self.wubi_candidate_mode = match mode.as_str() {
                    "singleFirst" | "single_first" => "single_first",
                    "singleOnly" | "single_only" => "single_only",
                    _ => "normal",
                }
                .to_owned();
                if let Err(err) = self.rebuild_engine_if_needed() {
                    return error_response(err);
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_input_mode" => {
                let Some(mode) = payload.mode else {
                    return error_response("set_input_mode requires mode");
                };
                self.input_mode = mode;
                if let Err(err) = self.rebuild_engine_if_needed() {
                    return error_response(err);
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_pinyin_scheme" => {
                let Some(scheme) = payload.scheme else {
                    return error_response("set_pinyin_scheme requires scheme");
                };
                if !is_known_pinyin_scheme(&scheme) {
                    return error_response(format!("UNKNOWN_PINYIN_SCHEME: {scheme}"));
                }
                let custom_profile = if scheme == "custom" {
                    let Some(table) = payload.custom_profile else {
                        return error_response("INVALID_CUSTOM_SHUANGPIN_PROFILE: missing table");
                    };
                    let table = ShuangpinCustomTable::from(table);
                    if let Err(error) = check_shuangpin_custom_profile(&table) {
                        return error_response(format!(
                            "INVALID_CUSTOM_SHUANGPIN_PROFILE: {error}"
                        ));
                    }
                    Some(table)
                } else {
                    None
                };
                let previous_scheme = self.pinyin_scheme.clone();
                let previous_profile = self.options.shuangpin_profile;
                let previous_custom = self.options.shuangpin_custom_profile.clone();
                self.pinyin_scheme = scheme;
                self.options.shuangpin_custom_profile = custom_profile;
                let rebuild = self.rebuild_engine_if_needed_with_force(
                    previous_custom != self.options.shuangpin_custom_profile,
                );
                if let Err(err) = rebuild {
                    self.pinyin_scheme = previous_scheme;
                    self.options.shuangpin_profile = previous_profile;
                    self.options.shuangpin_custom_profile = previous_custom;
                    let _ = self.rebuild_engine_if_needed();
                    return error_response(err);
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_page_size" => {
                let Some(ps) = payload.page_size else {
                    return error_response("set_page_size requires page_size");
                };
                let clamped = clamp_page_size(ps);
                self.page_size = clamped;
                self.options.first_page_rows = usize::from(clamped);
                let _ = self.runtime.set_page_size(clamped);
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            "set_option" => {
                let Some(name) = payload.name.as_deref() else {
                    return error_response("set_option requires name");
                };
                let value = payload.value.unwrap_or(false);
                match name {
                    "ascii_punct" => {
                        self.options.chinese_punctuation = !value;
                        let _ = self.runtime.set_chinese_punctuation_enabled(!value);
                    }
                    "emoji_suggestion" => {
                        self.options.mixed_emoji = value;
                        self.options.local_emoji = value;
                    }
                    "traditional" | "traditionalization" | "zh_trad" | "transcription" => {
                        if let Ok(mut guard) = self.pinned_state.lock() {
                            guard.traditional = value;
                        }
                    }
                    "simplification" => {
                        if let Ok(mut guard) = self.pinned_state.lock() {
                            guard.traditional = !value;
                        }
                    }
                    "vertical" => {
                        self.runtime.set_vertical_candidates(value);
                    }
                    "linear" => {
                        self.runtime.set_vertical_candidates(!value);
                    }
                    "wubi_code_hint" => {
                        self.wubi_code_hint = value;
                    }
                    "wubi_auto_clear" => {
                        self.wubi_auto_clear = value;
                    }
                    "wubi_z_reverse_lookup" => {
                        self.wubi_z_reverse_lookup = value;
                        let _ = self.runtime.set_wubi_z_pinyin_lookup(value);
                        self.sync_pinned_state_from_view(&self.runtime.view());
                    }
                    "wubi_english_channel" => {
                        self.wubi_english_channel = value;
                    }
                    "wubi_user_dict_learning" => {
                        self.wubi_user_dict_learning = value;
                        let _ = self.rebuild_engine_if_needed();
                    }
                    "pinyin_autocorrect" => {
                        if self.options.autocorrect_transposition != value
                            || self.options.autocorrect_neighbor != value
                        {
                            self.options.autocorrect_transposition = value;
                            self.options.autocorrect_neighbor = value;
                            if let Err(err) = self.force_rebuild_engine() {
                                return error_response(err);
                            }
                        }
                    }
                    _ => {}
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            other => error_response(format!("unsupported op: {other}")),
        }
    }
}

fn live_sessions() -> &'static Mutex<HashSet<usize>> {
    static LIVE: OnceLock<Mutex<HashSet<usize>>> = OnceLock::new();
    LIVE.get_or_init(|| Mutex::new(HashSet::new()))
}

fn is_live_session(ptr: *const OwlMsimeSession) -> bool {
    if ptr.is_null() {
        return false;
    }
    live_sessions()
        .lock()
        .map(|set| set.contains(&(ptr as usize)))
        .unwrap_or(false)
}

fn store_ffi_error(error_out: *mut *mut c_char, message: &str) {
    if error_out.is_null() {
        return;
    }
    let message = CString::new(message)
        .unwrap_or_else(|_| CString::new("session creation failed").expect("static C string"));
    unsafe {
        *error_out = message.into_raw();
    }
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create(
    pinyin_db_path: *const c_char,
    english_db_path: *const c_char,
    user_data_dir: *const c_char,
    page_size: u32,
) -> *mut OwlMsimeSession {
    catch_unwind(AssertUnwindSafe(|| {
        let pinyin = cstr_to_string(pinyin_db_path).unwrap_or_default();
        let english = cstr_to_string(english_db_path).unwrap_or_default();
        let user = cstr_to_string(user_data_dir).unwrap_or_default();
        match OwlMsimeSession::create(&pinyin, &english, &user, page_size) {
            Ok(session) => {
                let raw = Box::into_raw(Box::new(session));
                if let Ok(mut set) = live_sessions().lock() {
                    set.insert(raw as usize);
                }
                raw
            }
            Err(_) => ptr::null_mut(),
        }
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create_with_roots(
    pinyin_db_path: *const c_char,
    english_db_path: *const c_char,
    resources_dir: *const c_char,
    user_data_dir: *const c_char,
    cache_dir: *const c_char,
    dictionaries_dir: *const c_char,
    page_size: u32,
    error_out: *mut *mut c_char,
) -> *mut OwlMsimeSession {
    if !error_out.is_null() {
        unsafe {
            *error_out = ptr::null_mut();
        }
    }
    let created = catch_unwind(AssertUnwindSafe(|| {
        let pinyin = cstr_to_string(pinyin_db_path).unwrap_or_default();
        let english = cstr_to_string(english_db_path).unwrap_or_default();
        let resources = cstr_to_string(resources_dir).unwrap_or_default();
        let user = cstr_to_string(user_data_dir).unwrap_or_default();
        let cache = cstr_to_string(cache_dir).unwrap_or_default();
        let dictionaries = cstr_to_string(dictionaries_dir).unwrap_or_default();
        OwlMsimeSession::create_with_explicit_roots(
            &pinyin,
            &english,
            &resources,
            &user,
            &cache,
            &dictionaries,
            page_size,
        )
    }));
    match created {
        Ok(Ok(session)) => {
            let raw = Box::into_raw(Box::new(session));
            if let Ok(mut set) = live_sessions().lock() {
                set.insert(raw as usize);
            }
            raw
        }
        Ok(Err(message)) => {
            store_ffi_error(error_out, &message);
            ptr::null_mut()
        }
        Err(_) => {
            store_ffi_error(error_out, "panic in session creation with explicit roots");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create_with_generation(
    resources_dir: *const c_char,
    user_data_dir: *const c_char,
    cache_dir: *const c_char,
    content_id: *const c_char,
    page_size: u32,
    error_out: *mut *mut c_char,
) -> *mut OwlMsimeSession {
    if !error_out.is_null() {
        unsafe {
            *error_out = ptr::null_mut();
        }
    }
    let created = catch_unwind(AssertUnwindSafe(|| {
        let resources = cstr_to_string(resources_dir).unwrap_or_default();
        let user = cstr_to_string(user_data_dir).unwrap_or_default();
        let cache = cstr_to_string(cache_dir).unwrap_or_default();
        let content_id = cstr_to_string(content_id).unwrap_or_default();
        OwlMsimeSession::create_with_generation(&resources, &user, &cache, &content_id, page_size)
    }));
    match created {
        Ok(Ok(session)) => {
            let raw = Box::into_raw(Box::new(session));
            if let Ok(mut set) = live_sessions().lock() {
                set.insert(raw as usize);
            }
            raw
        }
        Ok(Err(message)) => {
            store_ffi_error(error_out, &message);
            ptr::null_mut()
        }
        Err(_) => {
            store_ffi_error(error_out, "panic in session creation with generation");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn owl_msime_session_destroy(session: *mut OwlMsimeSession) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !session.is_null() {
            let was_live = live_sessions()
                .lock()
                .map(|mut set| set.remove(&(session as usize)))
                .unwrap_or(false);
            if was_live {
                unsafe {
                    drop(Box::from_raw(session));
                }
            }
        }
    }));
}

#[no_mangle]
pub extern "C" fn owl_msime_session_handle_action_json(
    session: *mut OwlMsimeSession,
    action_json: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if !is_live_session(session) {
            return into_c_string_ptr(&error_response("session is null or destroyed"));
        }
        let Some(action_str) = cstr_to_string(action_json) else {
            return into_c_string_ptr(&error_response("action_json is null"));
        };
        let session_ref = unsafe { &mut *session };
        let response = session_ref.handle_action_json(&action_str);
        into_c_string_ptr(&response)
    }))
    .unwrap_or_else(|_| into_c_string_ptr(&error_response("panic in handle_action_json")))
}

#[no_mangle]
pub extern "C" fn owl_msime_session_snapshot_json(session: *const OwlMsimeSession) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if !is_live_session(session) {
            return into_c_string_ptr(&error_response("session is null or destroyed"));
        }
        let session_ref = unsafe { &*session };
        let response = session_ref.snapshot();
        into_c_string_ptr(&response)
    }))
    .unwrap_or_else(|_| into_c_string_ptr(&error_response("panic in snapshot_json")))
}

#[no_mangle]
pub extern "C" fn owl_msime_string_free(ptr: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !ptr.is_null() {
            unsafe {
                drop(CString::from_raw(ptr));
            }
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use msime_engine::host::shuangpin_builtin_table;
    use rusqlite::Connection;

    fn build_minimal_test_pinyin_db(path: &Path) {
        let conn = Connection::open(path).expect("open test sqlite db");
        conn.execute_batch(
            "CREATE TABLE tbl_1_n (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE INDEX idx_key_1_n ON tbl_1_n (\"key\");
             CREATE INDEX idx_jp_1_n ON tbl_1_n (\"jp\");
             INSERT INTO tbl_1_n (\"key\", \"jp\", \"value\", \"weight\") VALUES
               ('ni', 'n', '你', 5000),
               ('ni', 'n', '尼', 3000),
               ('ni', 'n', '泥', 2000),
               ('xin', 'x', '新', 2000),
               ('ping', 'p', '平', 2000);

             CREATE TABLE tbl_1_h (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE INDEX idx_key_1_h ON tbl_1_h (\"key\");
             CREATE INDEX idx_jp_1_h ON tbl_1_h (\"jp\");
             INSERT INTO tbl_1_h (\"key\", \"jp\", \"value\", \"weight\") VALUES
               ('hao', 'h', '好', 5000),
               ('hao', 'h', '号', 3000);

             CREATE TABLE tbl_2_n (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE INDEX idx_key_2_n ON tbl_2_n (\"key\");
             CREATE INDEX idx_jp_2_n ON tbl_2_n (\"jp\");
             INSERT INTO tbl_2_n (\"key\", \"jp\", \"value\", \"weight\") VALUES
               ('ni''hao', 'nh', '你好', 9000),
               ('ni''hao', 'nh', '你号', 4000),
               ('ni''hao', 'nh', '尼豪', 3000),
               ('ni''hao', 'nh', '泥嚎', 2000),
               ('ni''hao', 'nh', '拟好', 1500),
               ('ni''hao', 'nh', '逆号', 1200),
               ('ni''hao', 'nh', '昵号', 1000),
               ('ping''ping', 'pp', '平平', 9000);

             CREATE TABLE tbl_1_s (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE INDEX idx_key_1_s ON tbl_1_s (\"key\");
             CREATE INDEX idx_jp_1_s ON tbl_1_s (\"jp\");
             INSERT INTO tbl_1_s (\"key\", \"jp\", \"value\", \"weight\") VALUES
               ('shi', 's', '是', 9000),
               ('shi', 's', '事', 8000),
               ('shi', 's', '时', 7000),
               ('shi', 's', '十', 6000),
               ('shi', 's', '使', 5000),
               ('shi', 's', '世', 4000),
               ('shi', 's', '市', 3000),
               ('shi', 's', '式', 2000);

             CREATE TABLE quick_parases (\"key\" TEXT, \"value\" TEXT, \"weight\" INTEGER);
             CREATE INDEX idx_quick_parases_key_weight ON quick_parases (\"key\", \"weight\" DESC);",
        )
        .expect("populate test sqlite db");
    }

    fn build_minimal_test_resources(root: &Path) -> PathBuf {
        fs::create_dir_all(root).unwrap();
        let pinyin = root.join(msime_engine::assets::MAIN_DICTIONARY);
        build_minimal_test_pinyin_db(&pinyin);
        ensure_english_schema(&root.join(msime_engine::assets::ENGLISH_DICTIONARY)).unwrap();
        root.to_path_buf()
    }

    fn shuangpin_table_json(kind: ShuangpinProfileKind) -> serde_json::Value {
        let table = shuangpin_builtin_table(kind).expect("built-in shuangpin table");
        serde_json::json!({
            "initials": table.initials,
            "finals": table.finals,
            "zero_initials": table.zero_initials,
        })
    }

    fn call_action(session: *mut OwlMsimeSession, json: &str) -> SnapshotResponseDto {
        let c_req = CString::new(json).unwrap();
        let raw = owl_msime_session_handle_action_json(session, c_req.as_ptr());
        assert!(!raw.is_null());
        let resp_str = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        owl_msime_string_free(raw);
        serde_json::from_str(&resp_str).expect("valid response json")
    }

    fn call_snapshot(session: *const OwlMsimeSession) -> SnapshotResponseDto {
        let raw = owl_msime_session_snapshot_json(session);
        assert!(!raw.is_null());
        let resp_str = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        owl_msime_string_free(raw);
        serde_json::from_str(&resp_str).expect("valid snapshot json")
    }

    fn select_visible_text(session: *mut OwlMsimeSession, expected: &str) -> SnapshotResponseDto {
        loop {
            let frame = call_snapshot(session);
            if let Some(index) = frame
                .candidates
                .iter()
                .position(|candidate| candidate.text == expected)
            {
                return call_action(
                    session,
                    &format!(r#"{{"op":"select_visible","index":{index}}}"#),
                );
            }
            assert!(
                frame.has_more_pages,
                "candidate {expected:?} was not in the loaded pages"
            );
            call_action(session, r#"{"op":"turn_page","delta":1}"#);
        }
    }

    fn staged_pinyin_path(session: *const OwlMsimeSession) -> PathBuf {
        assert!(!session.is_null());
        unsafe { (*session).staged_pinyin_path.clone() }
    }

    fn host_phrase_texts(session: *const OwlMsimeSession) -> Vec<String> {
        assert!(!session.is_null());
        unsafe {
            (*session)
                .options
                .quick_phrase_table
                .iter()
                .map(|entry| entry.text.clone())
                .collect()
        }
    }

    fn create_with_explicit_roots(
        pinyin: &Path,
        resources: &Path,
        user: &Path,
        cache: &Path,
        dictionaries: &Path,
    ) -> (*mut OwlMsimeSession, Option<String>) {
        let c_pinyin = CString::new(pinyin.to_string_lossy().as_bytes()).unwrap();
        let c_empty = CString::new("").unwrap();
        let c_resources = CString::new(resources.to_string_lossy().as_bytes()).unwrap();
        let c_user = CString::new(user.to_string_lossy().as_bytes()).unwrap();
        let c_cache = CString::new(cache.to_string_lossy().as_bytes()).unwrap();
        let c_dictionaries = CString::new(dictionaries.to_string_lossy().as_bytes()).unwrap();
        let mut error = ptr::null_mut();
        let session = owl_msime_session_create_with_roots(
            c_pinyin.as_ptr(),
            c_empty.as_ptr(),
            c_resources.as_ptr(),
            c_user.as_ptr(),
            c_cache.as_ptr(),
            c_dictionaries.as_ptr(),
            5,
            &mut error,
        );
        let message = if error.is_null() {
            None
        } else {
            let value = unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned();
            owl_msime_string_free(error);
            Some(value)
        };
        (session, message)
    }

    fn create_with_generation(
        resources: &Path,
        user: &Path,
        cache: &Path,
        content_id: &str,
    ) -> (*mut OwlMsimeSession, Option<String>) {
        let c_resources = CString::new(resources.to_string_lossy().as_bytes()).unwrap();
        let c_user = CString::new(user.to_string_lossy().as_bytes()).unwrap();
        let c_cache = CString::new(cache.to_string_lossy().as_bytes()).unwrap();
        let c_content_id = CString::new(content_id).unwrap();
        let mut error = ptr::null_mut();
        let session = owl_msime_session_create_with_generation(
            c_resources.as_ptr(),
            c_user.as_ptr(),
            c_cache.as_ptr(),
            c_content_id.as_ptr(),
            5,
            &mut error,
        );
        let message = if error.is_null() {
            None
        } else {
            let value = unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned();
            owl_msime_string_free(error);
            Some(value)
        };
        (session, message)
    }

    fn session_options(session: *const OwlMsimeSession) -> &'static EngineOptions {
        assert!(!session.is_null());
        unsafe { &(*session).options }
    }

    fn assertion_journal_count(journal: &Path) -> i64 {
        Connection::open(journal)
            .unwrap()
            .query_row(
                "SELECT selection_count
                 FROM candidate_selection_state
                 WHERE context_key='codex-boundary' AND entry_key='ni' AND value='你'",
                [],
                |row| row.get(0),
            )
            .unwrap()
    }

    fn directory_tree(root: &Path) -> Vec<String> {
        fn visit(base: &Path, directory: &Path, entries: &mut Vec<String>) {
            let mut children: Vec<PathBuf> = fs::read_dir(directory)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            children.sort();
            for child in children {
                let relative = child.strip_prefix(base).unwrap().display();
                let metadata = fs::symlink_metadata(&child).unwrap();
                if metadata.is_dir() {
                    entries.push(format!("dir:{relative}"));
                    visit(base, &child, entries);
                } else if metadata.file_type().is_symlink() {
                    entries.push(format!("link:{relative}"));
                } else {
                    entries.push(format!("file:{relative}:{}", metadata.len()));
                }
            }
        }

        let mut entries = Vec::new();
        visit(root, root, &mut entries);
        entries
    }

    fn file_contents(root: &Path) -> Vec<(String, Vec<u8>)> {
        fn visit(base: &Path, directory: &Path, entries: &mut Vec<(String, Vec<u8>)>) {
            let mut children: Vec<PathBuf> = fs::read_dir(directory)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            children.sort();
            for child in children {
                let relative = child.strip_prefix(base).unwrap().display().to_string();
                let metadata = fs::symlink_metadata(&child).unwrap();
                if metadata.is_dir() {
                    visit(base, &child, entries);
                } else if metadata.file_type().is_symlink() {
                    entries.push((format!("link:{relative}"), Vec::new()));
                } else {
                    entries.push((format!("file:{relative}"), fs::read(&child).unwrap()));
                }
            }
        }

        let mut entries = Vec::new();
        visit(root, root, &mut entries);
        entries
    }

    #[test]
    fn explicit_roots_keep_session_runtime_separate_from_the_shared_user_journal() {
        let tmp = TempDir::new().unwrap();
        let pinyin = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&pinyin);
        let user = tmp.path().join("persistent-user");
        fs::create_dir_all(&user).unwrap();
        let journal = user.join(msime_engine::assets::USER_JOURNAL);
        Connection::open(&journal)
            .unwrap()
            .execute_batch(
                "CREATE TABLE candidate_selection_state(
                     context_key TEXT NOT NULL,
                     entry_key TEXT NOT NULL,
                     value TEXT NOT NULL,
                     selection_count INTEGER NOT NULL DEFAULT 0,
                     PRIMARY KEY(context_key,entry_key,value)
                 );
                 INSERT INTO candidate_selection_state
                     (context_key,entry_key,value,selection_count)
                 VALUES ('codex-boundary','ni','你',7);",
            )
            .unwrap();

        let runtime_a = tmp.path().join("runtime-a");
        let runtime_b = tmp.path().join("runtime-b");
        let resources_a = runtime_a.join("resources");
        let cache_a = runtime_a.join("cache");
        let dictionaries_a = runtime_a.join("dictionaries");
        let resources_b = runtime_b.join("resources");
        let cache_b = runtime_b.join("cache");
        let dictionaries_b = runtime_b.join("dictionaries");

        let (session_a, error_a) =
            create_with_explicit_roots(&pinyin, &resources_a, &user, &cache_a, &dictionaries_a);
        assert!(error_a.is_none(), "{error_a:?}");
        assert!(!session_a.is_null());
        let (session_b, error_b) =
            create_with_explicit_roots(&pinyin, &resources_b, &user, &cache_b, &dictionaries_b);
        assert!(error_b.is_none(), "{error_b:?}");
        assert!(!session_b.is_null());

        let options_a = session_options(session_a);
        let options_b = session_options(session_b);
        assert_eq!(
            Path::new(&options_a.resources),
            fs::canonicalize(&resources_a).unwrap()
        );
        assert_eq!(
            Path::new(&options_a.cache),
            fs::canonicalize(&cache_a).unwrap()
        );
        assert_eq!(
            Path::new(&options_a.dictionaries),
            fs::canonicalize(&dictionaries_a).unwrap()
        );
        assert_eq!(
            Path::new(&options_b.resources),
            fs::canonicalize(&resources_b).unwrap()
        );
        assert_eq!(
            Path::new(&options_a.user_data),
            Path::new(&options_b.user_data)
        );
        assert_ne!(options_a.resources, options_b.resources);
        assert_ne!(options_a.cache, options_b.cache);
        assert_ne!(options_a.dictionaries, options_b.dictionaries);
        assert!(!resources_a.join("msime-resources").exists());
        assert!(!user.join("msime-user").exists());
        assert!(dictionaries_a.join("msime-pinyin.db").is_file());
        assert!(dictionaries_a.join("msime-english.db").is_file());
        assert_eq!(assertion_journal_count(&journal), 7);

        for session in [session_a, session_b] {
            for ch in ['n', 'i'] {
                let typed = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
                assert!(typed.ok);
            }
            assert!(call_snapshot(session)
                .candidates
                .iter()
                .any(|candidate| candidate.text == "你"));
        }

        owl_msime_session_destroy(session_a);
        fs::remove_dir_all(&runtime_a).unwrap();
        assert!(journal.is_file());
        assert_eq!(assertion_journal_count(&journal), 7);

        owl_msime_session_destroy(session_b);
        fs::remove_dir_all(&runtime_b).unwrap();
        assert!(journal.is_file());
        assert_eq!(assertion_journal_count(&journal), 7);

        let runtime_c = tmp.path().join("runtime-c");
        let (reopened, error_c) = create_with_explicit_roots(
            &pinyin,
            &runtime_c.join("resources"),
            &user,
            &runtime_c.join("cache"),
            &runtime_c.join("dictionaries"),
        );
        assert!(error_c.is_none(), "{error_c:?}");
        assert!(!reopened.is_null());
        assert_eq!(assertion_journal_count(&journal), 7);
        for ch in ['n', 'i'] {
            let typed = call_action(reopened, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            assert!(typed.ok);
        }
        assert!(call_snapshot(reopened)
            .candidates
            .iter()
            .any(|candidate| candidate.text == "你"));
        owl_msime_session_destroy(reopened);
    }

    #[test]
    fn explicit_roots_reject_overlap_and_report_creation_errors() {
        let tmp = TempDir::new().unwrap();
        let pinyin = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&pinyin);

        let future_user = tmp.path().join("future-user");
        let before = directory_tree(tmp.path());
        let (session, error) = create_with_explicit_roots(
            &pinyin,
            &tmp.path().join("future-runtime/resources"),
            &future_user,
            &future_user.join("cache"),
            &tmp.path().join("future-runtime/dictionaries"),
        );
        assert!(session.is_null());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("session roots overlap")));
        assert_eq!(
            directory_tree(tmp.path()),
            before,
            "a future nested root must be rejected before creating any directory"
        );

        let existing_user = tmp.path().join("existing-user");
        fs::create_dir_all(&existing_user).unwrap();
        fs::write(existing_user.join("sentinel.txt"), b"keep").unwrap();
        let before = directory_tree(tmp.path());
        let (session, error) = create_with_explicit_roots(
            &pinyin,
            &tmp.path().join("existing-runtime/resources"),
            &existing_user,
            &existing_user.join("cache"),
            &tmp.path().join("existing-runtime/dictionaries"),
        );
        assert!(session.is_null());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("session roots overlap")));
        assert_eq!(
            directory_tree(tmp.path()),
            before,
            "an existing user tree must be unchanged when the requested cache root is nested"
        );

        let missing_pinyin = tmp.path().join("missing-pinyin.db");
        let (session, error) = create_with_explicit_roots(
            &missing_pinyin,
            &tmp.path().join("resources-2"),
            &tmp.path().join("user-2"),
            &tmp.path().join("cache-2"),
            &tmp.path().join("dictionaries-2"),
        );
        assert!(session.is_null());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("pinyin_db_path")));
    }

    #[cfg(unix)]
    #[test]
    fn explicit_roots_reject_redirected_directories_before_creation() {
        use std::os::unix::fs::symlink;

        for redirected in ["resources", "user", "cache", "dictionaries"] {
            let tmp = TempDir::new().unwrap();
            let outside = TempDir::new().unwrap();
            let pinyin = tmp.path().join("test-pinyin.db");
            build_minimal_test_pinyin_db(&pinyin);
            let linked = tmp.path().join(redirected);
            symlink(outside.path(), &linked).unwrap();

            let root = |name: &str| {
                if name == redirected {
                    linked.clone()
                } else {
                    tmp.path().join(name)
                }
            };
            let (session, error) = create_with_explicit_roots(
                &pinyin,
                &root("resources"),
                &root("user"),
                &root("cache"),
                &root("dictionaries"),
            );
            assert!(session.is_null(), "{redirected}");
            assert!(
                error
                    .as_deref()
                    .is_some_and(|message| message.contains("symbolic-link ancestor")),
                "{redirected}: {error:?}"
            );
            assert_eq!(
                fs::read_dir(outside.path()).unwrap().count(),
                0,
                "{redirected} must be rejected without writing through the link"
            );
        }
    }

    #[test]
    fn upstream_generation_matches_explicit_roots_and_keeps_product_defaults() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        Connection::open(resources.join(msime_engine::assets::MAIN_DICTIONARY))
            .unwrap()
            .execute(
                "INSERT INTO quick_parases VALUES ('ni', '基础短语', 1000000)",
                [],
            )
            .unwrap();
        let resources_before = file_contents(&resources);

        let (explicit, explicit_error) = create_with_explicit_roots(
            &resources.join(msime_engine::assets::MAIN_DICTIONARY),
            &resources,
            &tmp.path().join("explicit-user"),
            &tmp.path().join("explicit-cache"),
            &tmp.path().join("explicit-dictionaries"),
        );
        assert!(explicit_error.is_none(), "{explicit_error:?}");
        assert!(!explicit.is_null());

        let user = tmp.path().join("msime-user");
        let cache = tmp.path().join("msime-cache");
        let (generated, generated_error) =
            create_with_generation(&resources, &user, &cache, "seed-fixture");
        assert!(generated_error.is_none(), "{generated_error:?}");
        assert!(!generated.is_null());
        assert!(user
            .join("dictionaries/seed-fixture")
            .join(msime_engine::assets::GENERATION_READY)
            .is_file());

        let options = session_options(generated);
        assert!(options.learning);
        assert!(options.autocorrect_transposition);
        assert!(options.autocorrect_neighbor);
        assert!(options.mixed_english);
        assert_eq!(options.english_minimum_prefix, 2);
        assert_eq!(options.english_first_page_count, 3);
        assert!(options.quick_phrase_candidates);
        assert_eq!(options.first_page_rows, 5);
        assert!(!options.helpcode);

        let mut frames = Vec::new();
        for session in [explicit, generated] {
            for ch in ['n', 'i'] {
                call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            }
            frames.push(call_snapshot(session));
        }
        assert_eq!(frames[0].raw_input, frames[1].raw_input);
        assert_eq!(frames[0].preedit, frames[1].preedit);
        assert_eq!(
            frames[0]
                .candidates
                .iter()
                .map(|candidate| candidate.text.as_str())
                .collect::<Vec<_>>(),
            frames[1]
                .candidates
                .iter()
                .map(|candidate| candidate.text.as_str())
                .collect::<Vec<_>>()
        );
        assert_eq!(frames[0].candidates[0].text, "基础短语");

        call_action(generated, r#"{"op":"clear"}"#);
        let host = call_action(
            generated,
            r#"{"op":"set_host_phrases","text":"主机短语\tni"}"#,
        );
        assert!(host.ok);
        call_action(generated, r#"{"op":"insert","ch":"n"}"#);
        call_action(generated, r#"{"op":"insert","ch":"i"}"#);
        assert!(
            call_snapshot(generated)
                .candidates
                .iter()
                .any(|candidate| candidate.text == "主机短语"),
            "host phrases/templates must remain first-page candidates through the generation seam"
        );
        assert_eq!(file_contents(&resources), resources_before);

        owl_msime_session_destroy(explicit);
        owl_msime_session_destroy(generated);
    }

    #[test]
    fn raw_commit_suppresses_a_production_autocorrect_candidate() {
        let tmp = TempDir::new().unwrap();
        let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let pinyin = repository.join("data/owl-rime/msime/msime-pinyin.db");
        assert!(
            pinyin.is_file(),
            "missing production seed at {}",
            pinyin.display()
        );
        let resources = tmp.path().join("resources");
        fs::create_dir_all(&resources).unwrap();
        let user = tmp.path().join("user");
        let cache = tmp.path().join("cache");
        let dictionaries = tmp.path().join("dictionaries");
        let (session, error) =
            create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
        assert!(session.is_null() || error.is_none(), "{error:?}");
        assert!(!session.is_null());

        for ch in ['n', 'i', 'h', 's', 'o'] {
            let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(response.ok, "{:?}", response.error);
        }
        let initial = unsafe { (*session).runtime.all_candidates() };
        let initial_rows = initial
            .candidates
            .iter()
            .filter(|candidate| candidate.text == "你好")
            .collect::<Vec<_>>();
        assert_eq!(initial_rows.len(), 1);
        assert!(initial_rows[0].corrected);
        assert_eq!(initial_rows[0].annotation, "nihso");
        let raw = call_action(session, r#"{"op":"commit_raw"}"#);
        assert_eq!(raw.committed_text.as_deref(), Some("nihso"));

        let journal = user.join(msime_engine::assets::USER_JOURNAL);
        let suppressions: Vec<String> = Connection::open(&journal)
            .unwrap()
            .prepare("SELECT input FROM pinyin_autocorrect_suppressions ORDER BY input")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(suppressions, vec!["nihso"]);

        for ch in ['n', 'i', 'h', 's', 'o'] {
            let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(response.ok, "{:?}", response.error);
        }
        let repeated = unsafe { (*session).runtime.all_candidates() };
        let repeated_rows = repeated
            .candidates
            .iter()
            .filter(|candidate| candidate.text == "你好")
            .collect::<Vec<_>>();
        assert_eq!(repeated_rows.len(), 1);
        assert!(!repeated_rows[0].corrected);
        assert!(repeated_rows[0].annotation.is_empty());
        owl_msime_session_destroy(session);
    }

    #[test]
    fn pure_wubi_fifth_key_tops_an_ambiguous_four_code() {
        let tmp = TempDir::new().unwrap();
        let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let pinyin = repository.join("data/owl-rime/msime/msime-pinyin.db");
        assert!(
            pinyin.is_file(),
            "missing production seed at {}",
            pinyin.display()
        );
        let resources = tmp.path().join("resources");
        fs::create_dir_all(&resources).unwrap();
        let user = tmp.path().join("user");
        let cache = tmp.path().join("cache");
        let dictionaries = tmp.path().join("dictionaries");
        let (session, error) =
            create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
        assert!(session.is_null() || error.is_none(), "{error:?}");
        assert!(!session.is_null());

        let wubi_mode = call_action(session, r#"{"op":"set_input_mode","mode":"wubi"}"#);
        assert!(wubi_mode.ok, "{:?}", wubi_mode.error);
        let wubi_scheme = call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"wubi"}"#);
        assert!(wubi_scheme.ok, "{:?}", wubi_scheme.error);

        for ch in ['a', 'a', 'a', 'a'] {
            let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(response.ok, "{:?}", response.error);
        }
        let before = call_snapshot(session);
        assert_eq!(before.committed_text, None);
        assert_eq!(before.raw_input, "aaaa");
        assert_eq!(
            before
                .candidates
                .first()
                .map(|candidate| candidate.text.as_str()),
            Some("工")
        );

        let topped = call_action(session, r#"{"op":"insert","ch":"x"}"#);
        assert!(topped.ok, "{:?}", topped.error);
        assert_eq!(topped.committed_text.as_deref(), Some("工"));
        assert_eq!(topped.raw_input, "x");
        owl_msime_session_destroy(session);
    }

    #[test]
    fn upstream_generation_keeps_the_journal_at_user_root_and_replays_learning() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        let user = tmp.path().join("msime-user");
        let cache = tmp.path().join("msime-cache");

        let (first, error) = create_with_generation(&resources, &user, &cache, "seed-first");
        assert!(error.is_none(), "{error:?}");
        assert!(!first.is_null());
        for ch in ['n', 'i'] {
            call_action(first, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        assert_eq!(
            select_visible_text(first, "泥").committed_text.as_deref(),
            Some("泥")
        );
        msime_engine::flush_personal_learning();
        owl_msime_session_destroy(first);

        let journal = user.join(msime_engine::assets::USER_JOURNAL);
        assert!(
            journal.is_file(),
            "journal must live directly under user_data"
        );
        let journal_weight: i64 = Connection::open(&journal)
            .unwrap()
            .query_row(
                "SELECT weight FROM user_dictionary_operations
                 WHERE dictionary='pinyin' AND key='ni' AND value='泥'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(journal_weight > 2000, "{journal_weight}");

        let (second, error) = create_with_generation(&resources, &user, &cache, "seed-replayed");
        assert!(error.is_none(), "{error:?}");
        assert!(!second.is_null());
        let replayed_weight: i64 = Connection::open(
            user.join("dictionaries/seed-replayed")
                .join(msime_engine::assets::MAIN_DICTIONARY),
        )
        .unwrap()
        .query_row(
            "SELECT weight FROM tbl_1_n WHERE key='ni' AND value='泥'",
            [],
            |row| row.get(0),
        )
        .unwrap();
        assert_eq!(
            replayed_weight, journal_weight,
            "a new generation must replay the learning journal"
        );
        owl_msime_session_destroy(second);
    }

    #[test]
    fn upstream_generations_switch_without_discarding_journal_learning() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        let user = tmp.path().join("msime-user");
        let cache = tmp.path().join("msime-cache");

        let (session_a, error_a) = create_with_generation(&resources, &user, &cache, "content-a");
        assert!(error_a.is_none(), "{error_a:?}");
        assert!(!session_a.is_null());
        call_action(session_a, r#"{"op":"insert","ch":"n"}"#);

        let (session_b, error_b) = create_with_generation(&resources, &user, &cache, "content-b");
        assert!(error_b.is_none(), "{error_b:?}");
        assert!(!session_b.is_null());
        assert!(user
            .join("dictionaries/content-a")
            .join(msime_engine::assets::GENERATION_READY)
            .is_file());
        assert!(user
            .join("dictionaries/content-b")
            .join(msime_engine::assets::GENERATION_READY)
            .is_file());

        let continued = call_action(session_a, r#"{"op":"insert","ch":"i"}"#);
        assert_eq!(continued.raw_input, "ni");
        assert!(
            call_snapshot(session_a)
                .candidates
                .iter()
                .any(|candidate| candidate.text == "你"),
            "preparing a second content id must not disturb the live first session"
        );

        for ch in ['n', 'i'] {
            call_action(session_b, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        assert_eq!(
            select_visible_text(session_b, "泥")
                .committed_text
                .as_deref(),
            Some("泥")
        );
        msime_engine::flush_personal_learning();
        owl_msime_session_destroy(session_a);
        owl_msime_session_destroy(session_b);

        let (reopened_a, error) = create_with_generation(&resources, &user, &cache, "content-a");
        assert!(error.is_none(), "{error:?}");
        assert!(!reopened_a.is_null());
        let weight: i64 = Connection::open(
            user.join("dictionaries/content-a")
                .join(msime_engine::assets::MAIN_DICTIONARY),
        )
        .unwrap()
        .query_row(
            "SELECT weight FROM tbl_1_n WHERE key='ni' AND value='泥'",
            [],
            |row| row.get(0),
        )
        .unwrap();
        assert!(
            weight > 2000,
            "switching back to content-a must keep learning written while content-b was active"
        );
        owl_msime_session_destroy(reopened_a);
    }

    #[test]
    fn upstream_generation_rejects_invalid_inputs_before_user_writes() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));

        let overlap_resources = build_minimal_test_resources(&tmp.path().join("overlap-resources"));
        let before = directory_tree(tmp.path());
        let (session, error) = create_with_generation(
            &overlap_resources,
            &overlap_resources.join("user"),
            &tmp.path().join("overlap-cache"),
            "v1",
        );
        assert!(session.is_null());
        assert!(error.is_some());
        assert_eq!(directory_tree(tmp.path()), before);

        let before = directory_tree(tmp.path());
        let (session, error) = create_with_generation(
            &resources,
            Path::new("relative-user"),
            &tmp.path().join("relative-cache"),
            "v1",
        );
        assert!(session.is_null());
        assert!(error.is_some());
        assert_eq!(directory_tree(tmp.path()), before);

        let before = directory_tree(tmp.path());
        let (session, error) = create_with_generation(
            &resources,
            &tmp.path().join("invalid-id-user"),
            &tmp.path().join("invalid-id-cache"),
            "../escape",
        );
        assert!(session.is_null());
        assert!(error.is_some());
        assert_eq!(directory_tree(tmp.path()), before);

        let missing_english = tmp.path().join("missing-english");
        fs::create_dir_all(&missing_english).unwrap();
        build_minimal_test_pinyin_db(&missing_english.join(msime_engine::assets::MAIN_DICTIONARY));
        let before = directory_tree(tmp.path());
        let (session, error) = create_with_generation(
            &missing_english,
            &tmp.path().join("missing-english-user"),
            &tmp.path().join("missing-english-cache"),
            "v1",
        );
        assert!(session.is_null());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("msime-english.db")));
        assert_eq!(directory_tree(tmp.path()), before);

        let missing_pinyin = tmp.path().join("missing-pinyin");
        fs::create_dir_all(&missing_pinyin).unwrap();
        ensure_english_schema(&missing_pinyin.join(msime_engine::assets::ENGLISH_DICTIONARY))
            .unwrap();
        let before = directory_tree(tmp.path());
        let (session, error) = create_with_generation(
            &missing_pinyin,
            &tmp.path().join("missing-pinyin-user"),
            &tmp.path().join("missing-pinyin-cache"),
            "v1",
        );
        assert!(session.is_null());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("msime-pinyin.db")));
        assert_eq!(directory_tree(tmp.path()), before);
    }

    #[test]
    fn upstream_generation_reports_replay_failure_without_publishing() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        let user = tmp.path().join("msime-user");
        fs::create_dir_all(user.join("dictionaries")).unwrap();
        let journal = user.join(msime_engine::assets::USER_JOURNAL);
        Connection::open(&journal)
            .unwrap()
            .execute_batch(
                "CREATE TABLE user_dictionary_operations(bad INTEGER);
                 INSERT INTO user_dictionary_operations VALUES (1);",
            )
            .unwrap();
        let user_before = file_contents(&user);

        let (session, error) = create_with_generation(
            &resources,
            &user,
            &tmp.path().join("msime-cache"),
            "broken-replay",
        );
        assert!(session.is_null());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("dictionary generation")));
        assert!(!user.join("dictionaries/broken-replay").exists());
        assert!(!user.join("dictionaries/broken-replay.incoming").exists());
        assert_eq!(
            file_contents(&user),
            user_before,
            "a failed replay must not rewrite the journal or user files"
        );
    }

    #[test]
    fn ffi_quanpin_typing_pagination_and_editing() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&db_path);

        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());

        let initial = call_snapshot(session);
        assert!(initial.ok);
        assert_eq!(initial.raw_input, "");
        assert_eq!(initial.page_size, 5);

        for ch in ['n', 'i', 'h', 'a', 'o'] {
            let snap = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            assert!(snap.ok);
            assert!(snap.consumed);
        }

        let snap = call_snapshot(session);
        assert_eq!(snap.raw_input, "nihao");
        assert_eq!(snap.preedit, "ni'hao");
        assert_eq!(snap.page, 0);
        assert_eq!(snap.highlighted_index, 0);
        assert!(snap.has_more_pages);
        assert_eq!(snap.candidates[0].text, "你好");

        // Move highlight down and back up
        let moved = call_action(session, "{\"op\":\"move_highlight\",\"delta\":1}");
        assert!(moved.ok);
        assert_eq!(moved.highlighted_index, 1);
        let moved_back = call_action(session, "{\"op\":\"move_highlight\",\"delta\":-1}");
        assert_eq!(moved_back.highlighted_index, 0);

        // Turn page forward and backward
        let page1 = call_action(session, "{\"op\":\"turn_page\",\"delta\":1}");
        assert!(page1.ok);
        assert!(page1.consumed);
        assert_eq!(page1.page, 1);
        let page0 = call_action(session, "{\"op\":\"turn_page\",\"delta\":-1}");
        assert!(page0.ok);
        assert!(page0.consumed);
        assert_eq!(page0.page, 0);

        // Space commits highlighted candidate ("你好")
        let committed = call_action(session, "{\"op\":\"space\"}");
        assert!(committed.ok);
        assert_eq!(committed.committed_text.as_deref(), Some("你好"));
        assert_eq!(committed.raw_input, "");

        // Type "nihao" again and select 2nd visible candidate via select_visible
        for ch in ['n', 'i', 'h', 'a', 'o'] {
            let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        let second_text = call_snapshot(session).candidates[1].text.clone();
        let selected = call_action(session, "{\"op\":\"select_visible\",\"index\":1}");
        assert!(selected.ok);
        assert_eq!(
            selected.committed_text.as_deref(),
            Some(second_text.as_str())
        );
        assert_eq!(selected.raw_input, "");

        // Backspace and commit_raw
        let _ = call_action(session, "{\"op\":\"insert\",\"ch\":\"n\"}");
        let _ = call_action(session, "{\"op\":\"insert\",\"ch\":\"i\"}");
        let after_bs = call_action(session, "{\"op\":\"backspace\"}");
        assert_eq!(after_bs.raw_input, "n");
        let raw_commit = call_action(session, "{\"op\":\"commit_raw\"}");
        assert_eq!(raw_commit.committed_text.as_deref(), Some("n"));
        assert_eq!(raw_commit.raw_input, "");

        // Clear composition
        let _ = call_action(session, "{\"op\":\"insert\",\"ch\":\"h\"}");
        let _ = call_action(session, "{\"op\":\"insert\",\"ch\":\"a\"}");
        let _ = call_action(session, "{\"op\":\"insert\",\"ch\":\"o\"}");
        let cleared = call_action(session, "{\"op\":\"clear\"}");
        assert!(cleared.ok);
        assert!(cleared.cleared);
        assert_eq!(cleared.committed_text, None);
        assert_eq!(cleared.raw_input, "");

        owl_msime_session_destroy(session);
        // Idempotent second destroy and post-destroy calls return ok=false rather than UAF
        owl_msime_session_destroy(session);
        let post_destroy_snap = call_snapshot(session);
        assert!(!post_destroy_snap.ok);
        let post_destroy_act = call_action(session, "{\"op\":\"space\"}");
        assert!(!post_destroy_act.ok);
    }

    #[test]
    fn ffi_partial_phrase_selection_stays_in_preedit_until_the_phrase_ends() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&db_path);
        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());

        for ch in ['n', 'i', 'h', 'a', 'o'] {
            call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        let held = select_visible_text(session, "你");
        assert!(held.consumed);
        assert_eq!(
            held.committed_text, None,
            "a candidate that consumes only the first syllable must stay in the composition"
        );
        assert_eq!(held.raw_input, "hao");
        assert_eq!(held.preedit, "你hao");
        assert_eq!(held.preedit_caret_byte, "你hao".len());

        // Continuing and then editing the remaining spelling must keep the chosen piece held.
        let continued = call_action(session, r#"{"op":"insert","ch":"n"}"#);
        assert_eq!(continued.committed_text, None);
        assert_eq!(continued.raw_input, "haon");
        assert_eq!(continued.preedit, "你hao'n");
        let edited = call_action(session, r#"{"op":"backspace"}"#);
        assert_eq!(edited.committed_text, None);
        assert_eq!(edited.raw_input, "hao");
        assert_eq!(edited.preedit, "你hao");

        // Ordinary Backspace retreats the latest selection when the tail reaches one character.
        let shorter = call_action(session, r#"{"op":"backspace"}"#);
        assert_eq!(shorter.committed_text, None);
        assert_eq!(shorter.preedit, "你ha");
        let shorter = call_action(session, r#"{"op":"backspace"}"#);
        assert_eq!(shorter.committed_text, None);
        assert_eq!(shorter.preedit, "你h");
        let restored = call_action(session, r#"{"op":"backspace"}"#);
        assert_eq!(restored.committed_text, None);
        assert_eq!(restored.raw_input, "ni");
        assert_eq!(restored.preedit, "ni");

        // Select the same piece again and finish the phrase; the pieces go out as one commit.
        for ch in ['h', 'a', 'o'] {
            call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        select_visible_text(session, "你");
        let committed = select_visible_text(session, "好");
        assert_eq!(committed.committed_text.as_deref(), Some("你好"));
        assert!(committed.raw_input.is_empty());
        assert!(committed.preedit.is_empty());

        // Escape discards both the unfinished spelling and the held piece.
        for ch in ['n', 'i', 'h', 'a', 'o'] {
            call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        select_visible_text(session, "你");
        let cancelled = call_action(session, r#"{"op":"clear"}"#);
        assert!(cancelled.cleared);
        assert_eq!(cancelled.committed_text, None);
        assert!(cancelled.raw_input.is_empty());
        assert!(cancelled.preedit.is_empty());

        owl_msime_session_destroy(session);
    }

    #[test]
    fn peek_preserves_published_generation_and_selection_with_withheld_candidates() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&db_path);
        let conn = Connection::open(&db_path).unwrap();
        for index in 0..60 {
            let word = char::from_u32(0x4e00 + index).unwrap().to_string();
            conn.execute(
                "INSERT INTO tbl_1_n (key, jp, value, weight) VALUES ('ni', 'n', ?1, ?2)",
                rusqlite::params![word, 10000 - index],
            )
            .unwrap();
        }
        drop(conn);
        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());
        call_action(session, r#"{"op":"insert","ch":"n"}"#);
        call_action(session, r#"{"op":"turn_page","delta":1}"#);
        let before = call_snapshot(session);
        let expected = before.candidates[0].text.clone();
        let peek = call_action(session, r#"{"op":"peek_candidates","start":10,"count":20}"#);
        let after = call_snapshot(session);
        assert_eq!(
            peek.generation, before.generation,
            "passive prefetch must not expand or retag displayed rows"
        );
        assert_eq!(after.generation, before.generation);
        assert_eq!(after.page, before.page);
        assert_eq!(after.candidates[0].text, expected);
        let selected = call_action(
            session,
            &format!(
                r#"{{"op":"select_token","index":0,"generation":{}}}"#,
                before.generation
            ),
        );
        assert_eq!(selected.committed_text.as_deref(), Some(expected.as_str()));
        // The passive read must not permanently hide the withheld tail: real paging still releases it.
        call_action(session, r#"{"op":"insert","ch":"n"}"#);
        for _ in 0..6 {
            call_action(session, r#"{"op":"turn_page","delta":1}"#);
        }
        let tail = call_snapshot(session);
        assert!(
            tail.page >= 5,
            "paging must reach beyond the initial 24 candidates"
        );
        let tail_text = tail.candidates[0].text.clone();
        let absolute = call_action(
            session,
            &format!(
                r#"{{"op":"select_token","index":{},"is_absolute":true,"generation":{}}}"#,
                tail.page * tail.page_size,
                tail.generation
            ),
        );
        assert_eq!(absolute.committed_text.as_deref(), Some(tail_text.as_str()));
        owl_msime_session_destroy(session);
    }

    #[test]
    fn supports_tokens_peek_pinned_words_punctuation_and_caret() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&db_path);
        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();

        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());

        // Pin "拟好" to the front for "ni hao"
        let pin_res = call_action(
            session,
            r#"{"op":"set_pinned_words","text":"nihao\t0\t拟好"}"#,
        );
        assert!(pin_res.ok);

        for ch in ['n', 'i', 'h', 'a', 'o'] {
            let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }

        let snap = call_snapshot(session);
        assert!(snap.ok);
        assert_eq!(snap.raw_input, "nihao");
        assert_eq!(snap.preedit, "ni'hao");
        assert_eq!(snap.caret_position, 5);
        assert_eq!(snap.preedit_caret_byte, 6);
        assert!(snap.generation > 0);
        assert_eq!(snap.candidates[0].text, "拟好");
        assert_eq!(snap.candidates[0].comment.as_deref(), Some("置顶"));

        // Peek candidates across pages
        let peeked = call_action(session, r#"{"op":"peek_candidates","start":0,"count":6}"#);
        assert!(peeked.ok);
        assert_eq!(peeked.candidates.len(), 6);
        assert_eq!(peeked.candidates[0].text, "拟好");
        assert_eq!(peeked.candidates[5].text, "逆号");

        // Move caret left and home, then end
        let moved_left = call_action(session, r#"{"op":"move_caret","target":"left"}"#);
        assert!(moved_left.ok);
        assert!(moved_left.consumed);
        assert_eq!(moved_left.caret_position, 4);
        assert_eq!(moved_left.preedit_caret_byte, 5);

        let moved_home = call_action(session, r#"{"op":"move_caret","target":"home"}"#);
        assert_eq!(moved_home.caret_position, 0);
        assert_eq!(moved_home.preedit_caret_byte, 0);

        let set_caret = call_action(session, r#"{"op":"set_caret","pos":5}"#);
        assert_eq!(set_caret.caret_position, 5);
        assert_eq!(set_caret.preedit_caret_byte, 6);

        // Stale generation token must be rejected without committing
        let stale_gen = snap.generation + 999;
        let stale = call_action(
            session,
            &format!(
                r#"{{"op":"select_token","index":0,"is_absolute":false,"generation":{stale_gen}}}"#
            ),
        );
        assert!(stale.ok);
        assert!(!stale.consumed);
        assert!(stale.committed_text.is_none());

        // Valid token selects pinned candidate ("拟好")
        let cur_gen = call_snapshot(session).generation;
        let selected_pinned = call_action(
            session,
            &format!(
                r#"{{"op":"select_token","index":0,"is_absolute":false,"generation":{cur_gen}}}"#
            ),
        );
        assert!(selected_pinned.ok);
        assert!(selected_pinned.consumed);
        assert_eq!(selected_pinned.committed_text.as_deref(), Some("拟好"));

        // Absolute token across pages (index 5 -> "逆号")
        for ch in ['n', 'i', 'h', 'a', 'o'] {
            let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        let gen2 = call_snapshot(session).generation;
        let selected_abs = call_action(
            session,
            &format!(r#"{{"op":"select_token","index":5,"is_absolute":true,"generation":{gen2}}}"#),
        );
        assert!(selected_abs.ok);
        assert!(selected_abs.consumed);
        assert_eq!(selected_abs.committed_text.as_deref(), Some("逆号"));

        // Chinese punctuation while composing commits highlighted candidate + full-width punctuation
        for ch in ['n', 'i', 'h', 'a', 'o'] {
            let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        let punct_cn = call_action(session, r#"{"op":"punctuation","ch":",","ascii":false}"#);
        assert!(punct_cn.ok);
        assert!(punct_cn.consumed);
        assert_eq!(punct_cn.committed_text.as_deref(), Some("拟好，"));

        owl_msime_session_destroy(session);
    }

    #[test]
    fn host_phrase_sync_preserves_base_rows_and_removes_only_legacy_imports() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&db_path);
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "INSERT INTO quick_parases VALUES
               ('base', 'BaseHigh', 950000),
               ('same', 'Same', 10),
               ('same', 'Same', 100000);",
        )
        .unwrap();
        drop(conn);

        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());

        let staged = staged_pinyin_path(session);
        let conn = Connection::open(&staged).unwrap();
        conn.execute_batch(
            "INSERT INTO quick_parases VALUES
               ('same', 'Same', 100000),
               ('host', 'HostOnly', 100000),
               ('same', 'Same', 100000),
               ('host', 'HostOnly', 100000),
               ('host', 'HostOnly', 100000);
             CREATE TABLE owl_host_quick_phrases(key TEXT NOT NULL, value TEXT NOT NULL);
             INSERT INTO owl_host_quick_phrases VALUES
               ('same', 'Same'),
               ('host', 'HostOnly'),
               ('host', 'HostOnly');",
        )
        .unwrap();
        drop(conn);

        let response = call_action(
            session,
            "{\"op\":\"set_host_phrases\",\"text\":\"HostNew\\thost\\t100000\\nHostNew\\thost\\t10\"}",
        );
        assert!(response.ok);
        assert_eq!(host_phrase_texts(session), vec!["HostNew"]);

        let conn = Connection::open(&staged).unwrap();
        let rows: Vec<(String, String, i64)> = conn
            .prepare("SELECT key, value, weight FROM quick_parases ORDER BY key, value, weight")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            rows,
            vec![
                ("base".to_owned(), "BaseHigh".to_owned(), 950000),
                ("same".to_owned(), "Same".to_owned(), 10),
                ("same".to_owned(), "Same".to_owned(), 100000),
            ],
            "the legacy host row must be removed without touching identical or high-weight base rows"
        );
        let tracking_table_count: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='owl_host_quick_phrases'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tracking_table_count, 0);
        drop(conn);

        for ch in ['h', 'o', 's', 't'] {
            call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        let snapshot = call_snapshot(session);
        assert!(
            snapshot
                .candidates
                .iter()
                .any(|candidate| candidate.text == "HostNew"),
            "host phrases must remain available from runtime state"
        );

        let cleared = call_action(session, "{\"op\":\"set_host_phrases\",\"text\":\"\"}");
        assert!(cleared.ok);
        assert!(host_phrase_texts(session).is_empty());
        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        let quick_count: i64 = conn
            .query_row("SELECT count(*) FROM quick_parases", [], |row| row.get(0))
            .unwrap();
        assert_eq!(
            quick_count, 3,
            "clearing host phrases must not remove base rows"
        );

        owl_msime_session_destroy(session);
    }

    #[test]
    fn host_phrase_cleanup_failure_is_reported_and_atomic() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&db_path);
        let conn = Connection::open(&db_path).unwrap();
        conn.execute(
            "INSERT INTO quick_parases VALUES ('base', 'BaseHigh', 950000)",
            [],
        )
        .unwrap();
        drop(conn);

        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());
        let old = call_action(
            session,
            "{\"op\":\"set_host_phrases\",\"text\":\"HostOld\\thost\"}",
        );
        assert!(old.ok);

        let staged = staged_pinyin_path(session);
        let conn = Connection::open(&staged).unwrap();
        conn.execute_batch(
            "INSERT INTO quick_parases VALUES
               ('host', 'HostOld', 100000),
               ('host', 'HostOld', 100000);
             CREATE TABLE owl_host_quick_phrases(key TEXT NOT NULL, value TEXT NOT NULL);
             INSERT INTO owl_host_quick_phrases VALUES
               ('host', 'HostOld'),
               ('host', 'HostOld');",
        )
        .unwrap();

        let source = Connection::open(&db_path).unwrap();
        source
            .execute_batch("ALTER TABLE quick_parases RENAME TO missing_quick_parases;")
            .unwrap();
        drop(source);

        let failed = call_action(
            session,
            "{\"op\":\"set_host_phrases\",\"text\":\"HostNew\\thost\"}",
        );
        assert!(!failed.ok);
        assert!(
            failed.error.as_deref().is_some_and(|err| {
                err.contains("HOST_PHRASE_CLEANUP_FAILED") && err.contains("copy base rows")
            }),
            "the SQL failure must be exposed instead of swallowed: {:?}",
            failed.error
        );
        assert_eq!(
            host_phrase_texts(session),
            vec!["HostOld"],
            "a failed synchronization must not install the new table"
        );

        let rows: Vec<(String, String, i64)> = conn
            .prepare("SELECT key, value, weight FROM quick_parases ORDER BY key, value, weight")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            rows,
            vec![
                ("base".to_owned(), "BaseHigh".to_owned(), 950000),
                ("host".to_owned(), "HostOld".to_owned(), 100000),
                ("host".to_owned(), "HostOld".to_owned(), 100000),
            ]
        );

        owl_msime_session_destroy(session);
    }

    #[test]
    fn session_creation_restores_base_quick_phrases_before_first_snapshot() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        let user_dir = tmp.path().join("user-data");
        build_minimal_test_pinyin_db(&db_path);
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "INSERT INTO quick_parases VALUES
               ('base', 'BaseHigh', 950000),
               ('same', 'Same', 10),
               ('same', 'Same', 100000),
               ('host', 'SourcePhrase', 100000);
             CREATE TABLE owl_host_quick_phrases(key TEXT NOT NULL, value TEXT NOT NULL);
             INSERT INTO owl_host_quick_phrases VALUES ('host', 'SourcePhrase');",
        )
        .unwrap();
        drop(conn);

        let staged_dir = user_dir.join("msime-dicts");
        fs::create_dir_all(&staged_dir).unwrap();
        let staged = staged_dir.join("msime-pinyin.db");
        fs::copy(&db_path, &staged).unwrap();
        let conn = Connection::open(&staged).unwrap();
        conn.execute(
            "UPDATE quick_parases SET value = 'StaleHostPhr' WHERE key = 'host'",
            [],
        )
        .unwrap();
        drop(conn);
        assert_eq!(
            fs::metadata(&db_path).unwrap().len(),
            fs::metadata(&staged).unwrap().len(),
            "the fixture must keep the same file length so create does not re-stage it"
        );

        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let c_user = CString::new(user_dir.to_str().unwrap()).unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_user.as_ptr(), 5);
        assert!(!session.is_null());

        // This is the first session operation: no snapshot or start maintenance happened first.
        let initial = call_snapshot(session);
        assert!(initial.ok);
        for ch in ['h', 'o', 's', 't'] {
            let typed = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            assert!(typed.ok);
        }
        let first_frame = call_snapshot(session);
        assert!(
            first_frame
                .candidates
                .iter()
                .any(|candidate| candidate.text == "SourcePhrase"),
            "the first engine generation must read the restored base rows"
        );
        assert!(
            first_frame
                .candidates
                .iter()
                .all(|candidate| candidate.text != "StaleHostPhr"),
            "a stale host row in the staged database must not survive the first frame"
        );
        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        let values: Vec<String> = conn
            .prepare("SELECT value FROM quick_parases ORDER BY value")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(values, vec!["BaseHigh", "Same", "Same", "SourcePhrase"]);
        owl_msime_session_destroy(session);
    }

    #[test]
    fn legacy_host_migration_preserves_user_quick_phrase_state() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        let user_dir = tmp.path().join("user-data");
        build_minimal_test_pinyin_db(&db_path);
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "INSERT INTO quick_parases VALUES
               ('base', 'Base', 100),
               ('learned', 'Learned', 10),
               ('removed', 'Removed', 100),
               ('shared', 'Shared', 50),
               ('host', 'HostConflict', 10);
             CREATE TABLE owl_host_quick_phrases(key TEXT NOT NULL, value TEXT NOT NULL);
             INSERT INTO owl_host_quick_phrases VALUES ('host', 'HostConflict');",
        )
        .unwrap();
        drop(conn);

        let staged_dir = user_dir.join("msime-dicts");
        fs::create_dir_all(&staged_dir).unwrap();
        let staged = staged_dir.join("msime-pinyin.db");
        fs::copy(&db_path, &staged).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1_100));
        let conn = Connection::open(&staged).unwrap();
        for weight in [101, 100] {
            conn.execute(
                "UPDATE quick_parases SET weight=?1 WHERE key='base'",
                [weight],
            )
            .unwrap();
        }
        let tracking_before: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='owl_host_quick_phrases'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tracking_before, 1);
        drop(conn);

        let engine_user_dir = user_dir.join("msime-user");
        fs::create_dir_all(&engine_user_dir).unwrap();
        let journal = engine_user_dir.join(msime_engine::assets::USER_JOURNAL);
        let conn = Connection::open(&journal).unwrap();
        conn.execute_batch(
            "CREATE TABLE user_dictionary_operations(
                 dictionary TEXT NOT NULL,
                 key TEXT NOT NULL,
                 value TEXT NOT NULL,
                 operation TEXT NOT NULL,
                 weight INTEGER NOT NULL DEFAULT 0,
                 display TEXT NOT NULL DEFAULT '',
                 user_inserted INTEGER NOT NULL DEFAULT 0,
                 updated_at INTEGER NOT NULL DEFAULT 0,
                 PRIMARY KEY(dictionary,key,value)
             );
             INSERT INTO user_dictionary_operations
                 (dictionary,key,value,operation,weight,user_inserted,updated_at)
             VALUES
                 ('quick','base','Base','upsert',125,0,1),
                 ('quick','removed','Removed','delete',0,1,2),
                 ('quick','shared','Shared','upsert',75,1,3),
                 ('quick','mine','Mine','upsert',700,1,4);",
        )
        .unwrap();
        drop(conn);

        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let c_user = CString::new(user_dir.to_str().unwrap()).unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_user.as_ptr(), 5);
        assert!(!session.is_null());

        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        let tracking_after: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='owl_host_quick_phrases'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tracking_after, 0, "legacy tracking must be consumed");
        let rows: Vec<(String, String, i64)> = conn
            .prepare("SELECT key, value, weight FROM quick_parases ORDER BY key, value, weight")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            rows,
            vec![
                ("base".to_owned(), "Base".to_owned(), 125),
                ("host".to_owned(), "HostConflict".to_owned(), 10),
                ("learned".to_owned(), "Learned".to_owned(), 10),
                ("mine".to_owned(), "Mine".to_owned(), 700),
                ("shared".to_owned(), "Shared".to_owned(), 75),
            ],
            "migration must restore base rows, replay quick-phrase journal state, and drop only legacy host rows"
        );
        let tracking_table_count: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='owl_host_quick_phrases'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tracking_table_count, 0);
        drop(conn);

        for ch in ['m', 'i', 'n', 'e'] {
            call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        assert_eq!(
            call_snapshot(session)
                .candidates
                .first()
                .map(|candidate| candidate.text.as_str()),
            Some("Mine")
        );

        // With no legacy tracking table, later host-phrase updates must leave main rows alone.
        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        conn.execute(
            "UPDATE quick_parases SET weight=701 WHERE key='mine' AND value='Mine'",
            [],
        )
        .unwrap();
        drop(conn);
        let updated = call_action(
            session,
            "{\"op\":\"set_host_phrases\",\"text\":\"HostNew\\thost\"}",
        );
        assert!(updated.ok);
        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        let weight: i64 = conn
            .query_row(
                "SELECT weight FROM quick_parases WHERE key='mine' AND value='Mine'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(weight, 701);
        drop(conn);

        owl_msime_session_destroy(session);
        Connection::open(&journal)
            .unwrap()
            .execute(
                "UPDATE user_dictionary_operations SET weight=701, updated_at=5
                 WHERE dictionary='quick' AND key='mine' AND value='Mine'",
                [],
            )
            .unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_user.as_ptr(), 5);
        assert!(!session.is_null());
        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        let weight: i64 = conn
            .query_row(
                "SELECT weight FROM quick_parases WHERE key='mine' AND value='Mine'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            weight, 701,
            "creating another session must not reset user rows"
        );
        owl_msime_session_destroy(session);
    }

    #[test]
    fn corrupt_user_journal_is_quarantined_before_quick_phrase_replay() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("test-pinyin.db");
        let user_dir = tmp.path().join("user-data");
        build_minimal_test_pinyin_db(&db_path);
        Connection::open(&db_path)
            .unwrap()
            .execute("INSERT INTO quick_parases VALUES ('base', 'Base', 100)", [])
            .unwrap();

        let engine_user_dir = user_dir.join("msime-user");
        fs::create_dir_all(&engine_user_dir).unwrap();
        let journal = engine_user_dir.join(msime_engine::assets::USER_JOURNAL);
        fs::write(&journal, b"synthetic invalid database").unwrap();

        let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
        let c_empty = CString::new("").unwrap();
        let c_user = CString::new(user_dir.to_str().unwrap()).unwrap();
        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_user.as_ptr(), 5);
        assert!(
            !session.is_null(),
            "a corrupt journal must not prevent session creation"
        );
        assert!(!journal.exists());
        assert!(
            fs::read_dir(&engine_user_dir)
                .unwrap()
                .filter_map(Result::ok)
                .any(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("msime_user.db.corrupt-")
                }),
            "the corrupt journal must be retained beside the new journal path"
        );

        let conn = Connection::open(staged_pinyin_path(session)).unwrap();
        let values: Vec<String> = conn
            .prepare("SELECT value FROM quick_parases ORDER BY value")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            values,
            vec!["Base"],
            "a corrupt journal contributes no operations, so the base table must still be restored"
        );
        owl_msime_session_destroy(session);
    }

    #[test]
    fn loads_seed_msime_pinyin_db_when_present() {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .expect("repo root");
        let seed_pinyin = repo_root.join("data/owl-rime/msime/msime-pinyin.db");
        if !seed_pinyin.is_file() {
            return;
        }
        let seed_english = repo_root.join("data/owl-rime/msime/msime-english.db");
        let c_pinyin = CString::new(seed_pinyin.to_str().unwrap()).unwrap();
        let c_english = CString::new(
            seed_english
                .is_file()
                .then(|| seed_english.to_str().unwrap())
                .unwrap_or(""),
        )
        .unwrap();
        let c_empty = CString::new("").unwrap();

        let session =
            owl_msime_session_create(c_pinyin.as_ptr(), c_english.as_ptr(), c_empty.as_ptr(), 5);
        assert!(!session.is_null());

        for ch in ['n', 'i', 'h', 'a', 'o'] {
            let snap = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            assert!(snap.ok);
        }
        let snap = call_snapshot(session);
        assert!(snap.candidates.iter().any(|c| c.text == "你好"));

        let wubi_mode = call_action(session, r#"{"op":"set_input_mode","mode":"wubi"}"#);
        assert!(wubi_mode.ok);
        let wubi_scheme = call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"wubi"}"#);
        assert!(wubi_scheme.ok);

        for (code, expected) in [("a", "工"), ("ifcy", "法"), ("hang", "虛")] {
            for ch in code.chars() {
                let typed = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
                assert!(typed.ok);
            }
            let candidates = call_snapshot(session).candidates;
            assert!(
                candidates
                    .iter()
                    .any(|candidate| candidate.text == expected),
                "production Wubi seed must answer {code} with {expected}"
            );
            let _ = call_action(session, r#"{"op":"clear"}"#);
        }

        let mut cold = None;
        for ch in "edui".chars() {
            let typed = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            assert!(typed.ok);
            cold = Some(typed);
        }
        let cold = cold.expect("edui has four keys");
        assert!(
            cold.committed_text.as_deref() == Some("膫")
                || cold
                    .candidates
                    .iter()
                    .any(|candidate| candidate.text == "膫"),
            "production Wubi seed must contain the cold full code edui -> 膫"
        );

        owl_msime_session_destroy(session);
    }

    #[test]
    fn unknown_pinyin_scheme_fails_without_replacing_the_active_scheme() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        let user = tmp.path().join("user");
        let cache = tmp.path().join("cache");
        let (session, error) = create_with_generation(&resources, &user, &cache, "scheme-unknown");
        assert!(error.is_none(), "{error:?}");
        assert!(!session.is_null());

        let selected = call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"xiaohe"}"#);
        assert!(selected.ok, "{:?}", selected.error);
        let rejected = call_action(
            session,
            r#"{"op":"set_pinyin_scheme","scheme":"not-a-real-scheme"}"#,
        );
        assert!(!rejected.ok);
        assert!(rejected
            .error
            .as_deref()
            .is_some_and(|message| message.contains("UNKNOWN_PINYIN_SCHEME")));
        assert_eq!(unsafe { (*session).pinyin_scheme.as_str() }, "xiaohe");
        assert_eq!(
            session_options(session).shuangpin_profile,
            ShuangpinProfileKind::Xiaohe as u8
        );

        for ch in "ni".chars() {
            let typed = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(typed.ok, "{:?}", typed.error);
        }
        assert!(
            call_snapshot(session)
                .candidates
                .iter()
                .any(|candidate| candidate.text == "你"),
            "the rejected scheme must leave the previous xiaohe mapping working"
        );
        owl_msime_session_destroy(session);
    }

    #[test]
    fn custom_shuangpin_requires_a_valid_table_and_preserves_the_previous_profile() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        let user = tmp.path().join("user");
        let cache = tmp.path().join("cache");
        let (session, error) = create_with_generation(&resources, &user, &cache, "scheme-invalid");
        assert!(error.is_none(), "{error:?}");
        assert!(!session.is_null());

        let selected = call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"xiaohe"}"#);
        assert!(selected.ok, "{:?}", selected.error);

        let missing_table = call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"custom"}"#);
        assert!(!missing_table.ok);
        assert!(missing_table
            .error
            .as_deref()
            .is_some_and(|message| message.contains("missing table")));

        let mut invalid_table = shuangpin_table_json(ShuangpinProfileKind::Xiaohe);
        invalid_table["finals"]
            .as_array_mut()
            .unwrap()
            .pop()
            .unwrap();
        let invalid = call_action(
            session,
            &serde_json::json!({
                "op": "set_pinyin_scheme",
                "scheme": "custom",
                "custom_profile": invalid_table,
            })
            .to_string(),
        );
        assert!(!invalid.ok);
        assert!(invalid
            .error
            .as_deref()
            .is_some_and(|message| message.contains("INVALID_CUSTOM_SHUANGPIN_PROFILE")));
        assert_eq!(unsafe { (*session).pinyin_scheme.as_str() }, "xiaohe");
        assert_eq!(
            session_options(session).shuangpin_profile,
            ShuangpinProfileKind::Xiaohe as u8
        );
        assert!(session_options(session).shuangpin_custom_profile.is_none());

        for ch in "ni".chars() {
            let typed = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(typed.ok, "{:?}", typed.error);
        }
        assert!(
            call_snapshot(session)
                .candidates
                .iter()
                .any(|candidate| candidate.text == "你"),
            "invalid custom profiles must not disturb the active xiaohe mapping"
        );
        owl_msime_session_destroy(session);
    }

    #[test]
    fn custom_shuangpin_table_is_applied_and_a_changed_table_rebuilds_the_engine() {
        let tmp = TempDir::new().unwrap();
        let resources = build_minimal_test_resources(&tmp.path().join("resources"));
        let user = tmp.path().join("user");
        let cache = tmp.path().join("cache");
        let (session, error) = create_with_generation(&resources, &user, &cache, "scheme-custom");
        assert!(error.is_none(), "{error:?}");
        assert!(!session.is_null());
        unsafe {
            (*session).options.shuangpin_preedit_uses_raw = false;
        }

        let original = shuangpin_table_json(ShuangpinProfileKind::Xiaohe);
        let applied = call_action(
            session,
            &serde_json::json!({
                "op": "set_pinyin_scheme",
                "scheme": "custom",
                "custom_profile": original,
            })
            .to_string(),
        );
        assert!(applied.ok, "{:?}", applied.error);
        assert_eq!(
            session_options(session).shuangpin_profile,
            ShuangpinProfileKind::Custom as u8
        );
        for ch in "pkpk".chars() {
            let typed = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(typed.ok, "{:?}", typed.error);
        }
        let first_snapshot = call_snapshot(session);
        assert_eq!(first_snapshot.raw_input, "pkpk");
        assert_eq!(
            first_snapshot.preedit, "ping'ping",
            "xiaohe's k final must resolve ping"
        );

        // A second valid table with the same `custom` profile must rebuild the engine,
        // not retain the first table's key map. Ziranma moves `in` from `b` to `n`.
        let second_table = shuangpin_table_json(ShuangpinProfileKind::Ziranma);
        let reapplied = call_action(
            session,
            &serde_json::json!({
                "op": "set_pinyin_scheme",
                "scheme": "custom",
                "custom_profile": second_table,
            })
            .to_string(),
        );
        assert!(reapplied.ok, "{:?}", reapplied.error);

        for ch in "pypy".chars() {
            let typed = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(typed.ok, "{:?}", typed.error);
        }
        let snapshot = call_snapshot(session);
        assert_eq!(snapshot.raw_input, "pypy");
        assert_eq!(
            snapshot.preedit, "ping'ping",
            "the changed custom table must be the one used by the rebuilt engine"
        );

        let cleared = call_action(session, r#"{"op":"clear"}"#);
        assert!(cleared.ok, "{:?}", cleared.error);
        for ch in "pkpk".chars() {
            let typed = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
            assert!(typed.ok, "{:?}", typed.error);
        }
        assert_eq!(
            call_snapshot(session).preedit,
            "pao'pao",
            "the previous xiaohe key map must not survive the rebuild"
        );
        owl_msime_session_destroy(session);
    }
}
