//! Imports the deterministic Rime migration staged by the macOS host.
//!
//! The Swift side owns source discovery, mapping and content-addressed staging.
//! This module treats that directory as untrusted input: it verifies the
//! manifest and record digest, validates every row before opening the journal,
//! and only then calls the engine's existing dictionary-state and learning-habit
//! merge functions. A snapshot of the mutable databases restores both merges if
//! either one fails after validation.

use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use msime_engine::assets;
use msime_engine::host::{
    merge_dictionary_state, merge_learning_habits, normalize_full_pinyin, DictionaryStateMerge,
    DictionaryStateRecord, LearningHabit, LearningHabitsMerge, SnapshotReadError,
};
use msime_engine::{close_cached_databases, PersonalDictionaryKind, RuntimePaths};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

const MIGRATION_ROOT: &str = ".owl-user-migration";
const MANIFEST_NAME: &str = "manifest.json";
const RECORDS_NAME: &str = "dictionary-state.ndjson";
const PREPARED_NAME: &str = ".prepared";
const PREPARED_MARKER: &[u8] = b"owlrime-user-migration-v1\n";
const MANIFEST_SCHEMA_VERSION: u32 = 1;
const MAPPER_VERSION: &str = "rime-userdb-v1";
const REQUEST_PREFIX: &str = "owlrime-migrate-";
const MAX_MANIFEST_BYTES: u64 = 4 * 1024 * 1024;
const MAX_RECORDS_BYTES: u64 = 512 * 1024 * 1024;
const MAX_RECORD_LINE_BYTES: usize = 64 * 1024;
const MAX_RECORDS: usize = 500_000;
const MAX_PINS: usize = 100_000;
const MAX_KEY_BYTES: usize = 512;
const MAX_VALUE_BYTES: usize = 4_096;
const MAX_WEIGHT: i64 = 100_000_000;

static IMPORT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MigrationManifest {
    schema_version: u32,
    mapper_version: String,
    #[serde(rename = "requestID")]
    request_id: String,
    source_digest: String,
    record_digest: String,
    sources: Vec<serde_json::Value>,
    pins: Vec<MigrationPin>,
    issues: Vec<serde_json::Value>,
    limitations: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MigrationPin {
    code: String,
    text: String,
    // Required by the versioned manifest schema. Whether a pin was captured in
    // traditional mode remains owned by owl_pinned_words and does not decide
    // whether Rust can import the pin.
    #[allow(dead_code)]
    traditional: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OverlayRecord {
    #[serde(rename = "type")]
    record_type: String,
    deleted: bool,
    data: OverlayData,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OverlayData {
    kind: String,
    code: String,
    word: String,
    weight: i64,
    user_inserted: bool,
}

#[derive(Debug)]
struct ValidatedImport {
    manifest: MigrationManifest,
    source_count: usize,
    issue_count: usize,
    records: Vec<DictionaryStateRecord>,
    pins: Vec<MigrationPin>,
    habits: Vec<LearningHabit>,
    pins_external_only: usize,
}

#[derive(Debug, Serialize)]
struct UserMigrationReport {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<String>,
    source_count: usize,
    issue_count: usize,
    record_count: usize,
    entries_written: usize,
    positions_written: usize,
    selections_written: usize,
    records_kept: usize,
    records_skipped: usize,
    user_words_preserved: usize,
    pins_total: usize,
    pins_written: usize,
    pins_kept: usize,
    pins_external_only: usize,
    habits_trimmed: usize,
    warnings: Vec<String>,
}

impl UserMigrationReport {
    fn failure(error: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(error.into()),
            request_id: None,
            source_count: 0,
            issue_count: 0,
            record_count: 0,
            entries_written: 0,
            positions_written: 0,
            selections_written: 0,
            records_kept: 0,
            records_skipped: 0,
            user_words_preserved: 0,
            pins_total: 0,
            pins_written: 0,
            pins_kept: 0,
            pins_external_only: 0,
            habits_trimmed: 0,
            warnings: Vec::new(),
        }
    }
}

struct DatabaseSnapshot {
    path: PathBuf,
    originals: Vec<(PathBuf, PathBuf)>,
}

fn c_string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("argument is null".to_owned());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| "argument is not UTF-8".to_owned())
}

fn json_c_string(value: &UserMigrationReport) -> *mut c_char {
    let json = serde_json::to_string(value).unwrap_or_else(|error| {
        format!(
            "{{\"ok\":false,\"error\":{},\"source_count\":0,\"issue_count\":0,\"record_count\":0,\"entries_written\":0,\"positions_written\":0,\"selections_written\":0,\"records_kept\":0,\"records_skipped\":0,\"user_words_preserved\":0,\"pins_total\":0,\"pins_written\":0,\"pins_kept\":0,\"pins_external_only\":0,\"habits_trimmed\":0,\"warnings\":[]}}",
            serde_json::to_string(&error.to_string())
                .unwrap_or_else(|_| "\"serialization error\"".to_owned())
        )
    });
    let sanitized = json.replace('\0', "\u{fffd}");
    CString::new(sanitized)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn absolute_root(raw: &str, label: &str) -> Result<PathBuf, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(format!("{label} is empty"));
    }
    let path = PathBuf::from(trimmed);
    if !path.is_absolute() {
        return Err(format!("{label} is not absolute: {}", path.display()));
    }
    let metadata = fs::symlink_metadata(&path)
        .map_err(|error| format!("failed to inspect {label} {}: {error}", path.display()))?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(format!(
            "{label} is not a real directory: {}",
            path.display()
        ));
    }
    fs::canonicalize(&path)
        .map_err(|error| format!("failed to canonicalize {label} {}: {error}", path.display()))
}

fn valid_request_id(request_id: &str) -> bool {
    request_id
        .strip_prefix(REQUEST_PREFIX)
        .is_some_and(|suffix| {
            suffix.len() == 64
                && suffix
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut result = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut result, "{byte:02x}").expect("writing to String cannot fail");
    }
    result
}

fn real_directory(path: &Path, label: &str) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("{label} is missing at {}: {error}", path.display()))?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(format!(
            "{label} is not a real directory: {}",
            path.display()
        ));
    }
    Ok(())
}

fn read_bounded_regular_file(path: &Path, maximum: u64, label: &str) -> Result<Vec<u8>, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("{label} is missing at {}: {error}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(format!("{label} is not a regular file: {}", path.display()));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() != 1 {
            return Err(format!(
                "{label} has multiple hard links: {}",
                path.display()
            ));
        }
    }
    if metadata.len() > maximum {
        return Err(format!(
            "{label} is {} bytes, exceeding the {maximum}-byte limit",
            metadata.len()
        ));
    }
    let mut file = File::open(path)
        .map_err(|error| format!("failed to open {label} {}: {error}", path.display()))?;
    let mut bytes = Vec::with_capacity(usize::try_from(metadata.len()).unwrap_or(0));
    file.read_to_end(&mut bytes)
        .map_err(|error| format!("failed to read {label} {}: {error}", path.display()))?;
    if bytes.len() as u64 != metadata.len() {
        return Err(format!(
            "{label} changed while it was read: {}",
            path.display()
        ));
    }
    Ok(bytes)
}

fn validate_stage(
    user_data: &Path,
    request_id: &str,
) -> Result<(ValidatedImport, PathBuf), String> {
    if !valid_request_id(request_id) {
        return Err("request_id does not name an Owltype migration request".to_owned());
    }
    let migration_root = user_data.join(MIGRATION_ROOT);
    real_directory(&migration_root, "migration root")?;
    let stage = migration_root.join(request_id);
    real_directory(&stage, "migration stage")?;
    let canonical_stage = fs::canonicalize(&stage)
        .map_err(|error| format!("failed to canonicalize migration stage: {error}"))?;
    let expected = fs::canonicalize(user_data)
        .map_err(|error| format!("failed to canonicalize user_data_dir: {error}"))?
        .join(MIGRATION_ROOT)
        .join(request_id);
    if canonical_stage != expected {
        return Err("migration stage is not the exact child of user_data_dir".to_owned());
    }

    let names = fs::read_dir(&stage)
        .map_err(|error| {
            format!(
                "failed to read migration stage {}: {error}",
                stage.display()
            )
        })?
        .map(|entry| {
            entry
                .map_err(|error| format!("failed to read migration stage entry: {error}"))?
                .file_name()
                .into_string()
                .map_err(|_| "migration stage contains a non-UTF-8 name".to_owned())
        })
        .collect::<Result<HashSet<_>, _>>()?;
    let expected_names = HashSet::from([
        MANIFEST_NAME.to_owned(),
        RECORDS_NAME.to_owned(),
        PREPARED_NAME.to_owned(),
    ]);
    if names != expected_names {
        return Err("migration stage must contain exactly manifest, records and marker".to_owned());
    }

    let manifest_bytes =
        read_bounded_regular_file(&stage.join(MANIFEST_NAME), MAX_MANIFEST_BYTES, "manifest")?;
    let manifest: MigrationManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|error| format!("invalid migration manifest: {error}"))?;
    if manifest.schema_version != MANIFEST_SCHEMA_VERSION
        || manifest.mapper_version != MAPPER_VERSION
        || manifest.request_id != request_id
        || !valid_sha256(&manifest.source_digest)
        || !valid_sha256(&manifest.record_digest)
    {
        return Err("migration manifest version, request or digest is invalid".to_owned());
    }

    let marker = read_bounded_regular_file(&stage.join(PREPARED_NAME), 64, "prepared marker")?;
    if marker != PREPARED_MARKER {
        return Err("migration prepared marker is invalid".to_owned());
    }
    let record_bytes = read_bounded_regular_file(
        &stage.join(RECORDS_NAME),
        MAX_RECORDS_BYTES,
        "record stream",
    )?;
    if sha256(&record_bytes) != manifest.record_digest {
        return Err("migration record digest does not match the staged file".to_owned());
    }

    let records = parse_records(&record_bytes)?;
    if manifest.pins.len() > MAX_PINS {
        return Err(format!("migration has more than {MAX_PINS} pins"));
    }
    let pins = manifest.pins.clone();
    let (habits, pins_external_only) = map_pins(&pins)?;
    let source_count = manifest.sources.len();
    let issue_count = manifest.issues.len();
    Ok((
        ValidatedImport {
            source_count,
            issue_count,
            manifest,
            records,
            pins,
            habits,
            pins_external_only,
        },
        stage,
    ))
}

fn parse_records(bytes: &[u8]) -> Result<Vec<DictionaryStateRecord>, String> {
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    let mut records = Vec::new();
    let mut identities = HashSet::new();
    let mut start = 0usize;
    while start < bytes.len() {
        let relative_end = bytes[start..]
            .iter()
            .position(|byte| *byte == b'\n')
            .ok_or_else(|| "migration record stream does not end with a newline".to_owned())?;
        let end = start + relative_end;
        let line = &bytes[start..end];
        if line.is_empty() {
            return Err("migration record stream contains an empty line".to_owned());
        }
        if line.len() > MAX_RECORD_LINE_BYTES {
            return Err(format!(
                "migration record line exceeds {MAX_RECORD_LINE_BYTES} bytes"
            ));
        }
        if line.contains(&b'\r') {
            return Err("migration record line contains CR".to_owned());
        }
        let overlay: OverlayRecord = serde_json::from_slice(line)
            .map_err(|error| format!("invalid migration record: {error}"))?;
        if overlay.record_type != "overlay" {
            return Err(format!(
                "unsupported migration record type {:?}",
                overlay.record_type
            ));
        }
        let body = overlay.data;
        if body.user_inserted {
            return Err("user_inserted=true is not accepted by this migration importer".to_owned());
        }
        let kind = match body.kind.as_str() {
            "pinyin" => PersonalDictionaryKind::Pinyin,
            "wubi" => PersonalDictionaryKind::Wubi,
            "wubi98" => PersonalDictionaryKind::Wubi98,
            other => return Err(format!("unsupported dictionary kind {other:?}")),
        };
        if !bounded(&body.code, MAX_KEY_BYTES)
            || !bounded(&body.word, MAX_VALUE_BYTES)
            || !(0..=MAX_WEIGHT).contains(&body.weight)
            || (!overlay.deleted && body.weight < 1)
        {
            return Err("migration record fields are outside their allowed ranges".to_owned());
        }
        let identity = (kind.journal_name(), body.code.clone(), body.word.clone());
        if !identities.insert(identity) {
            return Err("migration record stream contains a duplicate identity".to_owned());
        }
        records.push(DictionaryStateRecord::Entry {
            kind,
            key: body.code,
            value: body.word,
            weight: body.weight,
            display: String::new(),
            deleted: overlay.deleted,
            user_inserted: false,
        });
        if records.len() > MAX_RECORDS {
            return Err(format!("migration has more than {MAX_RECORDS} records"));
        }
        start = end + 1;
    }
    Ok(records)
}

fn bounded(value: &str, maximum: usize) -> bool {
    !value.is_empty() && value.len() <= maximum && !value.contains('\0')
}

fn map_pins(pins: &[MigrationPin]) -> Result<(Vec<LearningHabit>, usize), String> {
    let mut habits = Vec::new();
    let mut contexts = HashSet::new();
    let mut external_only = 0usize;
    for pin in pins {
        if !bounded(&pin.code, MAX_KEY_BYTES) || !bounded(&pin.text, MAX_VALUE_BYTES) {
            return Err("migration pin fields are outside their allowed ranges".to_owned());
        }
        let expected_syllables = pin.text.chars().count();
        let context = normalize_full_pinyin(&pin.code, expected_syllables);
        if context.is_empty() || !contexts.insert(context.clone()) {
            external_only += 1;
            continue;
        }
        habits.push(LearningHabit::PinnedCandidate {
            context,
            value: pin.text.clone(),
            updated_at: 1,
        });
    }
    Ok((habits, external_only))
}

fn writable_database_paths(paths: &RuntimePaths) -> [PathBuf; 3] {
    [
        paths.user(assets::USER_JOURNAL),
        paths.dictionary(assets::MAIN_DICTIONARY),
        paths.dictionary(assets::ENGLISH_DICTIONARY),
    ]
}

fn snapshot_databases(paths: &RuntimePaths) -> Result<(TempDir, Vec<DatabaseSnapshot>), String> {
    close_cached_databases();
    let migration_root = paths.user_data.join(MIGRATION_ROOT);
    let temp = tempfile::Builder::new()
        .prefix(".import-rollback-")
        .tempdir_in(&migration_root)
        .map_err(|error| format!("failed to create migration rollback directory: {error}"))?;
    let mut snapshots = Vec::new();
    for (index, path) in writable_database_paths(paths).into_iter().enumerate() {
        let mut originals = Vec::new();
        let backup = temp.path().join(format!("{index}.db"));
        if snapshot_file(&path, &backup)? {
            originals.push((path.clone(), backup));
        }
        for (sidecar_index, sidecar) in database_sidecars(&path).into_iter().enumerate() {
            let backup = temp.path().join(format!("{index}-{sidecar_index}.db"));
            if snapshot_file(&sidecar, &backup)? {
                if originals.is_empty() {
                    return Err(format!(
                        "database sidecar exists without its database: {}",
                        sidecar.display()
                    ));
                }
                originals.push((sidecar, backup));
            }
        }
        snapshots.push(DatabaseSnapshot { path, originals });
    }
    Ok((temp, snapshots))
}

fn database_sidecars(path: &Path) -> [PathBuf; 3] {
    ["-wal", "-shm", "-journal"].map(|suffix| {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        PathBuf::from(name)
    })
}

fn snapshot_file(source: &Path, target: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(source) {
        Ok(metadata) if metadata.file_type().is_file() => {
            create_private_file(target)?;
            fs::copy(source, target).map_err(|error| {
                format!(
                    "failed to snapshot {} to {}: {error}",
                    source.display(),
                    target.display()
                )
            })?;
            Ok(true)
        }
        Ok(_) => Err(format!(
            "mutable database path is not a regular file: {}",
            source.display()
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "failed to inspect mutable database {}: {error}",
            source.display()
        )),
    }
}

fn create_private_file(path: &Path) -> Result<(), String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map(drop)
        .map_err(|error| format!("failed to create {}: {error}", path.display()))
}

fn restore_databases(snapshots: &[DatabaseSnapshot]) -> Result<(), String> {
    close_cached_databases();
    let mut failures = Vec::new();
    for snapshot in snapshots {
        remove_database_sidecars(&snapshot.path, &mut failures);
        remove_file_if_present(&snapshot.path, "mutable database", &mut failures);
        for (original, backup) in &snapshot.originals {
            let restored = fs::copy(backup, original)
                .map(|_| ())
                .map_err(|error| error.to_string())
                .and_then(|()| {
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        fs::set_permissions(original, fs::Permissions::from_mode(0o600))
                            .map_err(|error| error.to_string())?;
                    }
                    Ok(())
                });
            if let Err(error) = restored {
                failures.push(format!("{}: {error}", original.display()));
            }
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "could not restore every mutable database after failure: {}",
            failures.join("; ")
        ))
    }
}

fn remove_database_sidecars(path: &Path, failures: &mut Vec<String>) {
    for sidecar in database_sidecars(path) {
        remove_file_if_present(&sidecar, "database sidecar", failures);
    }
}

fn remove_file_if_present(path: &Path, label: &str, failures: &mut Vec<String>) {
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => failures.push(format!(
            "failed to remove {label} {}: {error}",
            path.display()
        )),
    }
}

fn finish_failed_import(
    original: String,
    rollback: TempDir,
    snapshots: &[DatabaseSnapshot],
) -> Result<UserMigrationReport, String> {
    match restore_databases(snapshots) {
        Ok(()) => Err(original),
        Err(restore_error) => {
            let retained = rollback.keep();
            Err(format!(
                "{original}; {restore_error}; recovery snapshot retained at {}",
                retained.display()
            ))
        }
    }
}

fn import_validated(
    paths: &RuntimePaths,
    validated: ValidatedImport,
) -> Result<UserMigrationReport, String> {
    let (rollback, snapshots) = snapshot_databases(paths)?;
    let options = super::product_engine_options(
        &paths.resources,
        &paths.user_data,
        &paths.cache,
        &paths.dictionaries,
        9,
    );
    let dictionary = if validated.records.is_empty() {
        DictionaryStateMerge::default()
    } else {
        match merge_dictionary_state(
            &options,
            validated.records.len(),
            validated
                .records
                .iter()
                .cloned()
                .map(Ok::<_, SnapshotReadError>),
        ) {
            Ok(merge) => merge,
            Err(error) => {
                let original = format!("dictionary merge failed: {error}");
                return finish_failed_import(original, rollback, &snapshots);
            }
        }
    };
    let habits = if validated.habits.is_empty() {
        LearningHabitsMerge::default()
    } else {
        match merge_learning_habits(
            &options,
            validated.habits.len(),
            validated
                .habits
                .iter()
                .cloned()
                .map(Ok::<_, SnapshotReadError>),
        ) {
            Ok(merge) => merge,
            Err(error) => {
                let original = format!("learning-habit merge failed: {error}");
                return finish_failed_import(original, rollback, &snapshots);
            }
        }
    };
    let mut warnings = validated.manifest.limitations.clone();
    warnings.extend([
        "pinned_candidates keeps one value per normalized full-pinyin context in owl_pinned_words order; later pins and pins without a valid context remain only in owl_pinned_words.".to_owned(),
        "Rime decay and tick are not represented in Rust dictionary state; the staged commit-count mapping remains visible in manifest limitations.".to_owned(),
        "user_inserted=true is rejected instead of being silently dropped because the personal-dictionary queue is outside this importer.".to_owned(),
    ]);
    Ok(UserMigrationReport {
        ok: true,
        error: None,
        request_id: Some(validated.manifest.request_id),
        source_count: validated.source_count,
        issue_count: validated.issue_count,
        record_count: validated.records.len(),
        entries_written: dictionary.entries,
        positions_written: dictionary.positions,
        selections_written: dictionary.selections,
        records_kept: dictionary.kept,
        records_skipped: dictionary.skipped,
        user_words_preserved: dictionary.words,
        pins_total: validated.pins.len(),
        pins_written: habits.written,
        pins_kept: habits.kept,
        pins_external_only: validated.pins_external_only,
        habits_trimmed: habits.trimmed,
        warnings,
    })
}

fn import_user_migration(
    resources: &str,
    user_data: &str,
    cache: &str,
    dictionaries: &str,
    request_id: &str,
) -> Result<UserMigrationReport, String> {
    let resources = absolute_root(resources, "resources_dir")?;
    let user_data = absolute_root(user_data, "user_data_dir")?;
    let cache = absolute_root(cache, "cache_dir")?;
    let dictionaries = absolute_root(dictionaries, "dictionaries_dir")?;
    let paths = RuntimePaths {
        resources,
        user_data: user_data.clone(),
        cache,
        dictionaries,
    };
    paths
        .validate()
        .map_err(|error| format!("invalid migration runtime roots: {error}"))?;
    let (validated, _stage) = validate_stage(&user_data, request_id)?;
    let _guard = IMPORT_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| "migration importer lock is poisoned".to_owned())?;
    import_validated(&paths, validated)
}

#[no_mangle]
pub extern "C" fn owl_msime_user_migration_import(
    resources_dir: *const c_char,
    user_data_dir: *const c_char,
    cache_dir: *const c_char,
    dictionaries_dir: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let result = (|| {
            let resources = c_string(resources_dir)?;
            let user_data = c_string(user_data_dir)?;
            let cache = c_string(cache_dir)?;
            let dictionaries = c_string(dictionaries_dir)?;
            let request_id = c_string(request_id)?;
            import_user_migration(&resources, &user_data, &cache, &dictionaries, &request_id)
        })();
        match result {
            Ok(report) => json_c_string(&report),
            Err(error) => json_c_string(&UserMigrationReport::failure(error)),
        }
    }))
    .unwrap_or_else(|_| {
        json_c_string(&UserMigrationReport::failure(
            "panic in user migration import",
        ))
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::ffi::CString;
    use std::ptr;

    use rusqlite::{params, Connection};
    use serde_json::{json, Value};
    use tempfile::TempDir;

    use super::*;

    struct Fixture {
        _temp: TempDir,
        resources: PathBuf,
        user: PathBuf,
        cache: PathBuf,
        dictionaries: PathBuf,
    }

    struct Staged {
        request_id: String,
    }

    impl Fixture {
        fn new(seed: bool) -> Self {
            let temp = TempDir::new().unwrap();
            let resources = temp.path().join("resources");
            let user = temp.path().join("user");
            let cache = temp.path().join("cache");
            let dictionaries = temp.path().join("dictionaries");
            for directory in [&resources, &user, &cache, &dictionaries] {
                fs::create_dir_all(directory).unwrap();
            }
            fs::create_dir_all(user.join(MIGRATION_ROOT)).unwrap();
            if seed {
                let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
                let production = repository.join("data/owl-rime/msime");
                for name in [
                    assets::MAIN_DICTIONARY,
                    assets::WUBI_DICTIONARY,
                    assets::ENGLISH_DICTIONARY,
                ] {
                    fs::copy(production.join(name), resources.join(name)).unwrap();
                }
            }
            let mut fixture = Self {
                _temp: temp,
                resources,
                user,
                cache,
                dictionaries,
            };
            if seed {
                fixture.dictionaries = fixture.prepare_generation();
            }
            fixture
        }

        fn prepare_generation(&self) -> PathBuf {
            // Swift prepares the live generation before importing; include the same split tables.
            let options = msime_engine::host::prepare_options(
                self.resources.to_str().unwrap(),
                self.user.to_str().unwrap(),
                self.cache.to_str().unwrap(),
                "migration-fixture",
            )
            .unwrap();
            PathBuf::from(options.dictionaries)
        }

        fn stage(&self, records: &[Value], pins: &[Value]) -> Staged {
            let mut record_data = Vec::new();
            for record in records {
                serde_json::to_writer(&mut record_data, record).unwrap();
                record_data.push(b'\n');
            }
            let request_seed = [
                record_data.as_slice(),
                serde_json::to_vec(pins).unwrap().as_slice(),
            ]
            .concat();
            let request_id = format!("{REQUEST_PREFIX}{}", sha256(&request_seed));
            let stage = self.user.join(MIGRATION_ROOT).join(&request_id);
            fs::create_dir(&stage).unwrap();
            let manifest = json!({
                "schemaVersion": MANIFEST_SCHEMA_VERSION,
                "mapperVersion": MAPPER_VERSION,
                "requestID": request_id,
                "sourceDigest": sha256(b"source fixture"),
                "recordDigest": sha256(&record_data),
                "sources": [],
                "pins": pins,
                "issues": [],
                "limitations": ["fixture limitation"]
            });
            fs::write(
                stage.join(MANIFEST_NAME),
                serde_json::to_vec(&manifest).unwrap(),
            )
            .unwrap();
            fs::write(stage.join(RECORDS_NAME), &record_data).unwrap();
            fs::write(stage.join(PREPARED_NAME), PREPARED_MARKER).unwrap();
            Staged { request_id }
        }

        fn import(&self, request_id: &str) -> Result<UserMigrationReport, String> {
            import_user_migration(
                self.resources.to_str().unwrap(),
                self.user.to_str().unwrap(),
                self.cache.to_str().unwrap(),
                self.dictionaries.to_str().unwrap(),
                request_id,
            )
        }

        fn journal(&self) -> PathBuf {
            self.user.join(assets::USER_JOURNAL)
        }

        fn main_dictionary(&self) -> PathBuf {
            self.dictionaries.join(assets::MAIN_DICTIONARY)
        }

        fn session(&self) -> *mut crate::OwlMsimeSession {
            let resources = CString::new(self.resources.to_string_lossy().as_bytes()).unwrap();
            let user = CString::new(self.user.to_string_lossy().as_bytes()).unwrap();
            let cache = CString::new(self.cache.to_string_lossy().as_bytes()).unwrap();
            let content_id = CString::new("migration-fixture").unwrap();
            let mut error = ptr::null_mut();
            let session = crate::owl_msime_session_create_with_generation(
                resources.as_ptr(),
                user.as_ptr(),
                cache.as_ptr(),
                content_id.as_ptr(),
                9,
                &mut error,
            );
            assert_ne!(
                session.is_null(),
                error.is_null(),
                "session and error must be mutually exclusive"
            );
            if !error.is_null() {
                let message = unsafe { CStr::from_ptr(error) }
                    .to_string_lossy()
                    .into_owned();
                crate::owl_msime_string_free(error);
                panic!("session creation failed: {message}");
            }
            session
        }
    }

    fn record(
        kind: &str,
        code: &str,
        word: &str,
        weight: i64,
        deleted: bool,
        user_inserted: bool,
    ) -> Value {
        json!({
            "type": "overlay",
            "deleted": deleted,
            "data": {
                "kind": kind,
                "code": code,
                "word": word,
                "weight": weight,
                "user_inserted": user_inserted
            }
        })
    }

    fn pin(code: &str, text: &str) -> Value {
        json!({"code": code, "text": text, "traditional": false})
    }

    fn traditional_pin(code: &str, text: &str) -> Value {
        json!({"code": code, "text": text, "traditional": true})
    }

    fn action(session: *mut crate::OwlMsimeSession, value: Value) -> Value {
        let request = CString::new(serde_json::to_vec(&value).unwrap()).unwrap();
        let raw = crate::owl_msime_session_handle_action_json(session, request.as_ptr());
        assert!(!raw.is_null());
        let response = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        crate::owl_msime_string_free(raw);
        serde_json::from_str(&response).unwrap()
    }

    fn snapshot(session: *const crate::OwlMsimeSession) -> Value {
        let raw = crate::owl_msime_session_snapshot_json(session);
        assert!(!raw.is_null());
        let response = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        crate::owl_msime_string_free(raw);
        serde_json::from_str(&response).unwrap()
    }

    fn type_text(session: *mut crate::OwlMsimeSession, text: &str) {
        for ch in text.chars() {
            let response = action(session, json!({"op": "insert", "ch": ch.to_string()}));
            assert_eq!(response["ok"], true, "{response}");
        }
    }

    fn select_text(session: *mut crate::OwlMsimeSession, expected: &str) {
        let frame = snapshot(session);
        let index = candidate_index(&frame, expected)
            .unwrap_or_else(|| panic!("candidate {expected:?} missing from {frame}"));
        let response = action(session, json!({"op": "select_visible", "index": index}));
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["committed_text"], expected);
    }

    fn candidate_index(frame: &Value, expected: &str) -> Option<usize> {
        frame["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .position(|candidate| candidate["text"] == expected)
    }

    fn clear(session: *mut crate::OwlMsimeSession) {
        let response = action(session, json!({"op": "clear"}));
        assert_eq!(response["ok"], true, "{response}");
    }

    fn database_components(base: &Path) -> Vec<PathBuf> {
        std::iter::once(base.to_path_buf())
            .chain(database_sidecars(base))
            .filter(|path| path.exists())
            .collect()
    }

    fn database_bytes(fixture: &Fixture) -> BTreeMap<PathBuf, Vec<u8>> {
        close_cached_databases();
        [
            fixture.journal(),
            fixture.main_dictionary(),
            fixture.dictionaries.join(assets::ENGLISH_DICTIONARY),
        ]
        .into_iter()
        .flat_map(|path| database_components(&path))
        .map(|path| {
            let bytes = fs::read(&path).unwrap();
            (path, bytes)
        })
        .collect()
    }

    #[cfg(unix)]
    fn preserve_journal_inode(fixture: &Fixture, name: &str) -> PathBuf {
        let probe = fixture._temp.path().join(name);
        fs::hard_link(fixture.journal(), &probe).unwrap();
        probe
    }

    #[cfg(unix)]
    fn remove_journal_artifacts(fixture: &Fixture) {
        for entry in fs::read_dir(&fixture.user).unwrap() {
            let entry = entry.unwrap();
            let name = entry.file_name().into_string().unwrap();
            let journal_name = assets::USER_JOURNAL;
            let reset_artifact = name == journal_name
                || name.starts_with(&format!("{journal_name}-"))
                || name.starts_with(&format!("{journal_name}.corrupt-"));
            if reset_artifact {
                assert!(entry.file_type().unwrap().is_file(), "{name}");
                fs::remove_file(entry.path()).unwrap();
            }
        }
    }

    #[cfg(unix)]
    fn reset_user_data(fixture: &Fixture) {
        remove_journal_artifacts(fixture);
        fs::remove_dir_all(&fixture.dictionaries).unwrap();
        assert_eq!(fixture.prepare_generation(), fixture.dictionaries);
    }

    #[cfg(unix)]
    fn journal_operation_exists(path: &Path, dictionary: &str, key: &str, value: &str) -> bool {
        if !path.is_file() {
            return false;
        }
        Connection::open(path)
            .unwrap()
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM user_dictionary_operations
                    WHERE dictionary=?1 AND key=?2 AND value=?3
                      AND operation='upsert'
                )",
                params![dictionary, key, value],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
            != 0
    }

    #[cfg(unix)]
    fn ngram_word_count(path: &Path, word: &str) -> i64 {
        Connection::open(path)
            .unwrap()
            .query_row(
                "SELECT
                    (SELECT COALESCE(SUM(count), 0) FROM personal_bigram WHERE word=?1)
                  + (SELECT COALESCE(SUM(count), 0) FROM personal_trigram WHERE word=?1)",
                params![word],
                |row| row.get(0),
            )
            .unwrap()
    }

    #[cfg(unix)]
    fn wait_for_ngram_word(path: &Path, word: &str) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(6);
        while std::time::Instant::now() < deadline {
            if ngram_word_count(path, word) > 0 {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        false
    }

    #[cfg(unix)]
    fn finalize_after_sessions_close() {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while !crate::owl_msime_engine_finalize() {
            assert!(
                std::time::Instant::now() < deadline,
                "other tests kept a session live for the entire finalize window"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[cfg(unix)]
    #[test]
    fn reset_after_session_destroy_does_not_reuse_the_old_journal_cache() {
        let fixture = Fixture::new(true);
        let session = fixture.session();
        type_text(session, "ni");
        select_text(session, "泥");
        crate::owl_msime_session_destroy(session);
        finalize_after_sessions_close();

        let old_journal = preserve_journal_inode(&fixture, "old-reset-journal.db");
        let learned_before_reset = ngram_word_count(&old_journal, "泥");
        assert!(
            learned_before_reset > 0,
            "the real selection did not reach the personal-context journal"
        );

        reset_user_data(&fixture);
        assert!(!fixture.journal().exists());

        let reset_session = fixture.session();
        type_text(reset_session, "ni");
        let reset_snapshot = snapshot(reset_session);
        assert_ne!(
            reset_snapshot["candidates"][0]["text"], "泥",
            "a reset journal must not restore the previous selection's ranking"
        );
        select_text(reset_session, "尼");
        let new_learning_landed = wait_for_ngram_word(&fixture.journal(), "尼");
        let old_inode_received_new_learning = ngram_word_count(&old_journal, "尼");
        crate::owl_msime_session_destroy(reset_session);

        assert_eq!(
            old_inode_received_new_learning, 0,
            "the new session wrote its learning into the reset journal's old inode"
        );
        assert!(
            new_learning_landed,
            "the new session's delayed personal-context write did not reach the new journal"
        );
        assert_eq!(
            ngram_word_count(&old_journal, "泥"),
            learned_before_reset,
            "the old inode changed after the reset"
        );
        assert!(!journal_operation_exists(
            &fixture.journal(),
            "pinyin",
            "ni",
            "泥"
        ));
        assert!(journal_operation_exists(
            &fixture.journal(),
            "pinyin",
            "ni",
            "尼"
        ));

        let restarted = fixture.session();
        type_text(restarted, "ni");
        let restarted_snapshot = snapshot(restarted);
        assert_ne!(
            restarted_snapshot["candidates"][0]["text"], "泥",
            "restarting must not replay the deleted journal's learning"
        );
        assert!(candidate_index(&restarted_snapshot, "尼").is_some());
        crate::owl_msime_session_destroy(restarted);
    }

    #[cfg(unix)]
    #[test]
    fn migration_import_does_not_reuse_an_older_session_journal_cache() {
        let fixture = Fixture::new(true);
        let staged = fixture.stage(
            &[record("wubi", "abcd", "迁移字", 9_000_000, false, false)],
            &[],
        );
        let session = fixture.session();
        type_text(session, "ni");
        select_text(session, "泥");
        crate::owl_msime_session_destroy(session);
        finalize_after_sessions_close();

        let old_journal = preserve_journal_inode(&fixture, "old-migration-journal.db");
        let learned_before_migration = ngram_word_count(&old_journal, "泥");
        assert!(learned_before_migration > 0);
        remove_journal_artifacts(&fixture);
        assert!(!fixture.journal().exists());

        let report = fixture.import(&staged.request_id).unwrap();
        assert!(report.ok);
        assert!(journal_operation_exists(
            &fixture.journal(),
            "wubi",
            "abcd",
            "迁移字"
        ));
        assert!(!journal_operation_exists(
            &fixture.journal(),
            "pinyin",
            "ni",
            "泥"
        ));

        let migrated = fixture.session();
        type_text(migrated, "ni");
        select_text(migrated, "尼");
        let migrated_learning_landed = wait_for_ngram_word(&fixture.journal(), "尼");
        let old_inode_received_new_learning = ngram_word_count(&old_journal, "尼");
        crate::owl_msime_session_destroy(migrated);

        assert_eq!(
            old_inode_received_new_learning, 0,
            "a pre-migration session cache wrote into the replaced journal inode"
        );
        assert!(
            migrated_learning_landed,
            "learning after migration did not reach the replacement journal"
        );
        assert_eq!(
            ngram_word_count(&old_journal, "泥"),
            learned_before_migration
        );
        assert_eq!(
            Connection::open(&old_journal)
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM user_dictionary_operations
                     WHERE dictionary='wubi' AND value='迁移字'",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            0,
            "migration data was written into the replaced journal inode"
        );
    }

    #[test]
    fn real_seed_import_is_idempotent_and_learning_survives_reopen() {
        let fixture = Fixture::new(true);
        let records = vec![
            record("pinyin", "zhuang'qiang", "迁移混输", 10, false, false),
            record("wubi", "qqqq", "迁移字", 10, false, false),
        ];
        let pins = vec![pin("ni hao", "你好")];
        let staged = fixture.stage(&records, &pins);

        let first = fixture.import(&staged.request_id).unwrap();
        assert!(first.ok);
        assert_eq!(first.record_count, 2);
        assert_eq!(first.entries_written, 2);
        assert_eq!(first.pins_written, 1);
        close_cached_databases();
        let journal = fixture.journal();
        let connection = Connection::open(&journal).unwrap();
        let operation_count: i64 = connection
            .query_row(
                "SELECT count(*) FROM user_dictionary_operations",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let pin_count: i64 = connection
            .query_row("SELECT count(*) FROM pinned_candidates", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(operation_count, 2);
        assert_eq!(pin_count, 1);
        drop(connection);

        let second = fixture.import(&staged.request_id).unwrap();
        assert!(second.ok);
        assert_eq!(second.entries_written, 0);
        assert_eq!(second.records_kept, 2);
        assert_eq!(second.pins_written, 0);
        assert_eq!(second.pins_kept, 1);
        close_cached_databases();
        let connection = Connection::open(&journal).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT count(*) FROM user_dictionary_operations",
                    [],
                    |row| { row.get::<_, i64>(0) }
                )
                .unwrap(),
            2
        );
        assert_eq!(
            connection
                .query_row("SELECT count(*) FROM pinned_candidates", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            1
        );
        drop(connection);

        close_cached_databases();
        let session = fixture.session();
        clear(session);
        type_text(session, "zhuangqiang");
        assert!(candidate_index(&snapshot(session), "迁移混输").unwrap() > 0);
        select_text(session, "迁移混输");

        clear(session);
        assert_eq!(
            action(session, json!({"op": "set_input_mode", "mode": "wubi"}))["ok"],
            true
        );
        assert_eq!(
            action(
                session,
                json!({"op": "set_pinyin_scheme", "scheme": "wubi"})
            )["ok"],
            true
        );
        type_text(session, "qqqq");
        select_text(session, "迁移字");

        clear(session);
        assert_eq!(
            action(
                session,
                json!({"op": "set_pinyin_scheme", "scheme": "wubi_pinyin"})
            )["ok"],
            true
        );
        type_text(session, "zhuangqiang");
        select_text(session, "迁移混输");
        crate::owl_msime_session_destroy(session);
        close_cached_databases();

        let connection = Connection::open(&journal).unwrap();
        let learned_weight: i64 = connection
            .query_row(
                "SELECT weight FROM user_dictionary_operations
                 WHERE dictionary='pinyin' AND key='zhuang''qiang'
                   AND value='迁移混输' AND user_inserted=0",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            learned_weight > 10,
            "selection learning did not update the imported row's weight"
        );
        drop(connection);

        close_cached_databases();
        let reopened = fixture.session();
        clear(reopened);
        type_text(reopened, "zhuangqiang");
        let pinyin = snapshot(reopened);
        assert_eq!(candidate_index(&pinyin, "迁移混输"), Some(0), "{pinyin}");
        clear(reopened);
        assert_eq!(
            action(reopened, json!({"op": "set_input_mode", "mode": "wubi"}))["ok"],
            true
        );
        assert_eq!(
            action(
                reopened,
                json!({"op": "set_pinyin_scheme", "scheme": "wubi"})
            )["ok"],
            true
        );
        type_text(reopened, "qqqq");
        let wubi = snapshot(reopened);
        assert!(
            wubi["candidates"]
                .as_array()
                .unwrap()
                .iter()
                .any(|candidate| candidate["text"] == "迁移字"),
            "{wubi}"
        );
        clear(reopened);
        assert_eq!(
            action(
                reopened,
                json!({"op": "set_pinyin_scheme", "scheme": "wubi_pinyin"})
            )["ok"],
            true
        );
        type_text(reopened, "zhuangqiang");
        let mixed = snapshot(reopened);
        assert!(
            mixed["candidates"]
                .as_array()
                .unwrap()
                .iter()
                .any(|candidate| candidate["text"] == "迁移混输"),
            "{mixed}"
        );
        crate::owl_msime_session_destroy(reopened);
    }

    #[test]
    fn traditional_pin_is_imported_and_later_context_conflict_is_reported() {
        let fixture = Fixture::new(true);
        let pins = vec![
            traditional_pin("shi xing", "試行"),
            pin("shi xing", "施行"),
            traditional_pin("fa", "發"),
        ];
        let staged = fixture.stage(&[], &pins);

        let report = fixture.import(&staged.request_id).unwrap();

        assert!(report.ok);
        assert_eq!(report.pins_total, 3);
        assert_eq!(report.pins_written, 2);
        assert_eq!(report.pins_external_only, 1);
        close_cached_databases();
        let connection = Connection::open(fixture.journal()).unwrap();
        let shixing: String = connection
            .query_row(
                "SELECT value FROM pinned_candidates WHERE context_key='shi''xing'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let fa: String = connection
            .query_row(
                "SELECT value FROM pinned_candidates WHERE context_key='fa'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(shixing, "試行");
        assert_eq!(fa, "發");
    }

    #[test]
    fn habit_failure_restores_every_database_byte_for_byte() {
        let fixture = Fixture::new(true);
        let initial = fixture.stage(
            &[record("wubi", "abcd", "迁移字", 9_000_000, false, false)],
            &[],
        );
        fixture.import(&initial.request_id).unwrap();

        close_cached_databases();
        Connection::open(fixture.journal())
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER reject_pin BEFORE INSERT ON pinned_candidates
                 WHEN NEW.context_key='hao'
                 BEGIN SELECT RAISE(FAIL,'injected migration failure'); END;",
            )
            .unwrap();
        close_cached_databases();
        let before = database_bytes(&fixture);

        let failing = fixture.stage(
            &[record("pinyin", "a'a", "阿阿", 9_000_000, false, false)],
            &[pin("hao", "好")],
        );
        let error = fixture.import(&failing.request_id).unwrap_err();
        assert!(error.contains("learning-habit merge failed"), "{error}");
        assert_eq!(database_bytes(&fixture), before);

        let connection = Connection::open(fixture.main_dictionary()).unwrap();
        let changed: i64 = connection
            .query_row(
                "SELECT count(*) FROM tbl_2_a WHERE key='a''a' AND value='阿阿'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(changed, 0);
        assert!(fixture
            .user
            .join(MIGRATION_ROOT)
            .join(&failing.request_id)
            .is_dir());
    }

    #[cfg(unix)]
    #[test]
    fn restore_failure_retains_a_byte_exact_recovery_snapshot() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = Fixture::new(true);
        let initial = fixture.stage(
            &[record("wubi", "abcd", "迁移字", 9_000_000, false, false)],
            &[],
        );
        fixture.import(&initial.request_id).unwrap();

        close_cached_databases();
        Connection::open(fixture.journal())
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER reject_pin BEFORE INSERT ON pinned_candidates
                 WHEN NEW.context_key='hao'
                 BEGIN SELECT RAISE(FAIL,'injected migration failure'); END;",
            )
            .unwrap();
        close_cached_databases();

        let bases = [
            fixture.journal(),
            fixture.main_dictionary(),
            fixture.dictionaries.join(assets::ENGLISH_DICTIONARY),
        ];
        let mut expected_backups = BTreeMap::new();
        for (index, base) in bases.iter().enumerate() {
            if base.is_file() {
                expected_backups.insert(format!("{index}.db"), fs::read(base).unwrap());
            }
            for (sidecar_index, sidecar) in database_sidecars(base).iter().enumerate() {
                if sidecar.is_file() {
                    expected_backups.insert(
                        format!("{index}-{sidecar_index}.db"),
                        fs::read(sidecar).unwrap(),
                    );
                }
            }
        }

        let failing = fixture.stage(
            &[record("pinyin", "a'a", "阿阿", 9_000_000, false, false)],
            &[pin("hao", "好")],
        );
        let original_permissions = fs::metadata(&fixture.dictionaries).unwrap().permissions();
        let mut read_only = original_permissions.clone();
        read_only.set_mode(0o500);
        fs::set_permissions(&fixture.dictionaries, read_only).unwrap();

        let error = fixture.import(&failing.request_id).unwrap_err();
        fs::set_permissions(&fixture.dictionaries, original_permissions).unwrap();

        assert!(error.contains("could not restore every"), "{error}");
        let marker = "recovery snapshot retained at ";
        let retained = error
            .rsplit_once(marker)
            .map(|(_, path)| PathBuf::from(path.trim()))
            .unwrap_or_else(|| panic!("retained rollback path missing from {error}"));
        assert!(retained.is_dir(), "{}", retained.display());

        let actual_backups = fs::read_dir(&retained)
            .unwrap()
            .map(|entry| entry.unwrap())
            .filter(|entry| entry.file_type().unwrap().is_file())
            .map(|entry| {
                (
                    entry.file_name().into_string().unwrap(),
                    fs::read(entry.path()).unwrap(),
                )
            })
            .collect::<BTreeMap<_, _>>();
        assert_eq!(actual_backups, expected_backups);
        assert!(fixture
            .user
            .join(MIGRATION_ROOT)
            .join(&failing.request_id)
            .is_dir());
    }

    #[test]
    fn invalid_stages_are_rejected_without_creating_a_database() {
        let fixture = Fixture::new(false);
        let valid_record = record("pinyin", "a'a", "阿阿", 10, false, false);

        let digest = fixture.stage(&[valid_record.clone()], &[]);
        let manifest_path = fixture
            .user
            .join(MIGRATION_ROOT)
            .join(&digest.request_id)
            .join(MANIFEST_NAME);
        let mut manifest: Value =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest["recordDigest"] = json!("0".repeat(64));
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();

        let duplicate = fixture.stage(&[valid_record.clone(), valid_record], &[]);
        let unknown = fixture.stage(
            &[json!({
                "type": "overlay",
                "deleted": false,
                "unexpected": true,
                "data": {
                    "kind": "pinyin",
                    "code": "a'a",
                    "word": "阿阿",
                    "weight": 10,
                    "user_inserted": false
                }
            })],
            &[],
        );
        let inserted = fixture.stage(&[record("pinyin", "a'a", "阿阿", 10, false, true)], &[]);

        for (request_id, expected) in [
            (digest.request_id, "record digest"),
            (duplicate.request_id, "duplicate identity"),
            (unknown.request_id, "unknown field"),
            (inserted.request_id, "user_inserted=true"),
        ] {
            let error = fixture.import(&request_id).unwrap_err();
            assert!(error.contains(expected), "{request_id}: {error}");
            assert!(!fixture.journal().exists());
            assert_eq!(fs::read_dir(&fixture.dictionaries).unwrap().count(), 0);
            assert!(fixture.user.join(MIGRATION_ROOT).join(&request_id).is_dir());
        }
    }
}
