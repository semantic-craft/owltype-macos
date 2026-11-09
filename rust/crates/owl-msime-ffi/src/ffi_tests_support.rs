use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::ptr;

use msime_engine::ensure_english_schema;
use msime_engine::host::{shuangpin_builtin_table, EngineOptions};
use msime_engine::ShuangpinProfileKind;
use msime_input_runtime::TransformRow;
use rusqlite::Connection;
use serde_json::Value;

use crate::sessions::with_session;
use crate::*;

pub(crate) fn build_minimal_test_pinyin_db(path: &Path) {
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

pub(crate) fn build_minimal_test_resources(root: &Path) -> PathBuf {
    fs::create_dir_all(root).unwrap();
    let pinyin = root.join(msime_engine::assets::MAIN_DICTIONARY);
    build_minimal_test_pinyin_db(&pinyin);
    ensure_english_schema(&root.join(msime_engine::assets::ENGLISH_DICTIONARY)).unwrap();
    root.to_path_buf()
}

pub(crate) fn build_minimal_test_others_db(root: &Path) {
    let connection =
        Connection::open(root.join(msime_engine::assets::OTHER_DICTIONARY)).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE emoji (
                 emoji TEXT NOT NULL PRIMARY KEY,
                 category TEXT NOT NULL,
                 sort_order INTEGER NOT NULL,
                 keywords TEXT NOT NULL,
                 pinyin TEXT NOT NULL
             ) WITHOUT ROWID;
             CREATE TABLE emoji_pinyin (
                 key TEXT NOT NULL,
                 emoji TEXT NOT NULL,
                 sort_order INTEGER NOT NULL,
                 PRIMARY KEY (key, emoji)
             ) WITHOUT ROWID;
             INSERT INTO emoji VALUES ('🍎', 'Food and drink', 0, '苹果', 'pingguo');
             INSERT INTO emoji_pinyin VALUES ('ping', '🍎', 0);",
        )
        .unwrap();
}

pub(crate) fn shuangpin_table_json(kind: ShuangpinProfileKind) -> serde_json::Value {
    let table = shuangpin_builtin_table(kind).expect("built-in shuangpin table");
    serde_json::json!({
        "initials": table.initials,
        "finals": table.finals,
        "zero_initials": table.zero_initials,
    })
}

pub(crate) fn call_action(session: *mut OwlMsimeSession, json: &str) -> SnapshotResponseDto {
    let c_req = CString::new(json).unwrap();
    let raw = owl_msime_session_handle_action_json(session, c_req.as_ptr());
    assert!(!raw.is_null());
    let resp_str = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    owl_msime_string_free(raw);
    serde_json::from_str(&resp_str).expect("valid response json")
}

pub(crate) fn call_snapshot(session: *const OwlMsimeSession) -> SnapshotResponseDto {
    let raw = owl_msime_session_snapshot_json(session);
    assert!(!raw.is_null());
    let resp_str = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    owl_msime_string_free(raw);
    serde_json::from_str(&resp_str).expect("valid snapshot json")
}

pub(crate) fn call_json(raw: *mut c_char) -> Value {
    assert!(!raw.is_null());
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    owl_msime_string_free(raw);
    serde_json::from_str(&text).expect("valid rerank response json")
}

pub(crate) fn configure_rerank(session: *mut OwlMsimeSession, config: &str) -> Value {
    let config = CString::new(config).unwrap();
    call_json(owl_msime_session_configure_rerank_json(
        session,
        config.as_ptr(),
    ))
}

pub(crate) fn rerank_status(session: *mut OwlMsimeSession) -> Value {
    call_json(owl_msime_session_rerank_status_json(session))
}

pub(crate) fn start_settled_rerank(session: *mut OwlMsimeSession) -> Value {
    call_json(owl_msime_session_start_settled_rerank_json(session))
}

pub(crate) fn poll_settled_rerank(session: *mut OwlMsimeSession, token: u64, accept: bool) -> Value {
    call_json(owl_msime_session_poll_settled_rerank_json(
        session, token, accept,
    ))
}

pub(crate) fn wait_for_rerank_state(session: *mut OwlMsimeSession, model: &str, expected: &str) -> Value {
    for _ in 0..500 {
        let status = rerank_status(session);
        if status[model]["state"] == expected {
            return status;
        }
        assert_eq!(
            status[model]["state"], "loading",
            "rerank model did not reach {expected}: {status}"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    panic!(
        "rerank model did not reach {expected}: {}",
        rerank_status(session)
    );
}

pub(crate) fn wait_for_settled_job(session: *mut OwlMsimeSession, token: u64, accept: bool) -> Value {
    for _ in 0..500 {
        let response = poll_settled_rerank(session, token, accept);
        if response["status"] == "done" {
            return response;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    panic!("settled rerank job {token} did not finish");
}

pub(crate) fn select_visible_text(session: *mut OwlMsimeSession, expected: &str) -> SnapshotResponseDto {
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

pub(crate) fn candidate_texts_across_pages(session: *mut OwlMsimeSession) -> Vec<String> {
    let mut texts = Vec::new();
    let mut expected_page = 0;
    loop {
        let frame = call_snapshot(session);
        assert_eq!(frame.page, expected_page);
        texts.extend(frame.candidates.into_iter().map(|candidate| candidate.text));
        if !frame.has_more_pages {
            return texts;
        }
        let next = call_action(session, r#"{"op":"turn_page","delta":1}"#);
        assert!(next.ok, "{:?}", next.error);
        expected_page += 1;
        assert!(
            expected_page < 512,
            "candidate pagination did not terminate"
        );
    }
}

pub(crate) fn staged_pinyin_path(session: *const OwlMsimeSession) -> PathBuf {
    assert!(!session.is_null());
    with_session(session, |session| session.staged_pinyin_path.clone()).unwrap()
}

pub(crate) fn transform_row<'a>(text: &'a str, code: &'a str) -> TransformRow<'a> {
    TransformRow {
        text,
        code,
        annotation: "",
        source: 0,
    }
}


pub(crate) fn host_phrase_texts(session: *const OwlMsimeSession) -> Vec<String> {
    assert!(!session.is_null());
    with_session(session, |session| {
        session
            .options
            .quick_phrase_table
            .iter()
            .map(|entry| entry.text.clone())
            .collect()
    })
    .unwrap()
}

pub(crate) fn create_with_explicit_roots(
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

pub(crate) fn create_with_generation(
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

pub(crate) fn session_options(session: *const OwlMsimeSession) -> EngineOptions {
    assert!(!session.is_null());
    with_session(session, |session| session.options.clone()).unwrap()
}

pub(crate) fn assertion_journal_count(journal: &Path) -> i64 {
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

pub(crate) fn directory_tree(root: &Path) -> Vec<String> {
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

pub(crate) fn file_contents(root: &Path) -> Vec<(String, Vec<u8>)> {
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
