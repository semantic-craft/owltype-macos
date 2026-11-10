use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use msime_engine::host::EngineOptions;
use msime_engine::{
    reject_redirected_directory, roots_overlap, weakly_canonical, FrequencyAdjustmentMode,
    HelpcodeKeymap, SchemeSet, SchemeType, SentenceAssociationOptions, ShuangpinHelpcodeModes,
    ShuangpinProfileKind, WubiProfileKind,
};
use rusqlite::Connection;

pub(crate) fn stage_file_if_needed(src: &Path, dst: &Path) -> std::io::Result<()> {
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
pub(crate) struct SessionRoots {
    pub(crate) resources: PathBuf,
    pub(crate) user: PathBuf,
    pub(crate) cache: PathBuf,
    pub(crate) dictionaries: PathBuf,
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

pub(crate) fn prepare_explicit_roots(
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

pub(crate) fn validate_explicit_roots(roots: &SessionRoots) -> Result<(), String> {
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

pub(crate) fn resolve_pinyin_source(raw: &str) -> Result<PathBuf, String> {
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

pub(crate) fn reconcile_quick_phrases(
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

pub(crate) fn product_engine_options(
    resources: &Path,
    user_data: &Path,
    cache: &Path,
    dictionaries: &Path,
    page_size: u8,
) -> EngineOptions {
    EngineOptions {
        korean_layout: 0,
        multilingual_languages: Vec::new(),
        next_word_prediction: false,
        resources: resources.to_string_lossy().into_owned(),
        user_data: user_data.to_string_lossy().into_owned(),
        cache: cache.to_string_lossy().into_owned(),
        dictionaries: dictionaries.to_string_lossy().into_owned(),
        scheme: SchemeType::Quanpin as u8,
        enabled_schemes: SchemeSet::ALL,
        shuangpin_profile: ShuangpinProfileKind::Xiaohe as u8,
        shuangpin_custom_profile: None,
        shuangpin_preedit_uses_raw: true,
        shuangpin_preedit_separated: false,
        force_cantonese_shuangpin: false,
        cantonese_output_conversion: None,
        single_character_only: false,
        caret_edit_suffix: false,
        learning: true,
        learn_english_on_enter: true,
        autocorrect_transposition: true,
        autocorrect_neighbor: true,
        fuzzy_pinyin_rules: 0,
        wubi_mixed_pinyin: false,
        wubi_z_wildcard: false,
        wubi_profile: WubiProfileKind::Wubi86 as u8,
        wubi_reverse_code: true,
        helpcode: false,
        strict_quanpin_helpcode: false,
        show_helpcode: false,
        shuangpin_helpcode_modes: ShuangpinHelpcodeModes::default(),
        grid_helpcode: false,
        helpcode_schema: "ziranma".to_owned(),
        helpcode_trigger_key: None,
        helpcode_table: Some(Arc::new(HelpcodeKeymap::default())),
        helpcode_fallback_resources: None,
        custom_helpcode_root: None,
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
        english_minimum_prefix: 5,
        english_first_page_count: 1,
        mixed_emoji: true,
        mixed_kaomoji: false,
        mixed_symbols: true,
        mixed_japanese: false,
        local_unicode: true,
        local_date_time: true,
        local_date_time_inline: true,
        local_date_time_menu: true,
        local_quick_phrase: true,
        local_emoji: true,
        local_kaomoji: true,
        local_super_jianpin: true,
        local_super_jianpin_slash: true,
        local_temporary_english: true,
        local_temporary_japanese: false,
        local_expression: false,
        local_command: false,
        local_mention: false,
        local_chaizi: false,
        local_symbol: true,
        local_shift_letter_entry: true,
        chaizi_traditional_output: false,
        command_table: Vec::new(),
        plugin_commands: Vec::new(),
        mention_entries: Vec::new(),
        quick_phrase_table: Vec::new(),
        quick_phrase_table_in_candidates: false,
        // Native capability is available; fresh 0.55 mixed_input.quick_phrase defaults OFF.
        quick_phrase_candidates: false,
        quick_phrase_frequency: true,
        sentence_association: SentenceAssociationOptions::default(),
        rescoring_context: String::new(),
        sentence_alternatives: true,
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

