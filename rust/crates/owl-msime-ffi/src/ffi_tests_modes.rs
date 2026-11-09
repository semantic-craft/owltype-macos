use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};

use msime_engine::ShuangpinProfileKind;
use rusqlite::Connection;
use tempfile::TempDir;

use crate::ffi_tests_support::*;
use crate::sessions::with_session;
use crate::*;

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

    for ch in ['K', 'h', 'o', 's', 't'] {
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
    for ch in ['K', 'h', 'o', 's', 't'] {
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

    for ch in ['K', 'm', 'i', 'n', 'e'] {
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
    // Match the product's resource-generation path: official Wubi is a separate file.
    let temporary = TempDir::new().unwrap();
    let (session, error) = create_with_generation(
        seed_pinyin.parent().unwrap(),
        &temporary.path().join("user"),
        &temporary.path().join("cache"),
        "official-seed-smoke",
    );
    assert!(error.is_none(), "{error:?}");
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
    assert_eq!(
        with_session(session, |session| session.pinyin_scheme.clone()).unwrap(),
        "xiaohe"
    );
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
    assert_eq!(
        with_session(session, |session| session.pinyin_scheme.clone()).unwrap(),
        "xiaohe"
    );
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
    with_session(session, |session| {
        session.options.shuangpin_preedit_uses_raw = false
    })
    .unwrap();

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

#[test]
fn wubi_code_hint_off_hides_native_codes_while_preserving_lookup_and_wildcard_annotations() {
    let seed_pinyin = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .expect("repo root")
        .join("data/owl-rime/msime/msime-pinyin.db");
    if !seed_pinyin.is_file() {
        return;
    }
    let temporary = TempDir::new().unwrap();
    let (session, error) = create_with_generation(
        seed_pinyin.parent().unwrap(),
        &temporary.path().join("user"),
        &temporary.path().join("cache"),
        "wubi-hint-policy",
    );
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());

    assert!(call_action(session, r#"{"op":"set_input_mode","mode":"wubi"}"#).ok);
    assert!(call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"wubi"}"#).ok);

    assert!(call_action(session, r#"{"op":"insert","ch":"i"}"#).ok);
    let default_off = call_snapshot(session);
    assert!(
        default_off
            .candidates
            .iter()
            .all(|candidate| candidate.comment.is_none()),
        "native Wubi candidates must hide code annotations when wubi_code_hint is off"
    );
    assert!(call_action(session, r#"{"op":"clear"}"#).ok);

    for ch in "znihao".chars() {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let lookup = call_snapshot(session);
    let hello = lookup
        .candidates
        .iter()
        .find(|candidate| candidate.text == "你好")
        .expect("你好 in znihao lookup");
    assert_eq!(hello.comment.as_deref(), Some("wqvb"));
    assert!(call_action(session, r#"{"op":"clear"}"#).ok);

    assert!(
        call_action(
            session,
            r#"{"op":"set_option","name":"wubi_code_hint","value":true}"#
        )
        .ok
    );
    assert!(call_action(session, r#"{"op":"insert","ch":"i"}"#).ok);
    let hint_on = call_snapshot(session);
    let zibo = hint_on
        .candidates
        .iter()
        .find(|candidate| candidate.text == "淄博")
        .expect("淄博 in i candidates");
    assert_eq!(zibo.comment.as_deref(), Some("vfg"));
    owl_msime_session_destroy(session);
}
