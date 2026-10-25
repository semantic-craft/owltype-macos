use std::ffi::{c_char, CStr, CString};
use std::ptr;

use owl_msime_ffi::{
    owl_msime_engine_finalize, owl_msime_session_create_with_roots, owl_msime_session_destroy,
    owl_msime_session_handle_action_json, owl_msime_string_free,
};
use rusqlite::Connection;
use serde_json::Value;
use tempfile::TempDir;

fn c_path(path: &std::path::Path) -> CString {
    CString::new(path.to_string_lossy().as_bytes()).unwrap()
}

fn call_json(session: *mut owl_msime_ffi::OwlMsimeSession, request: &str) -> Value {
    let request = CString::new(request).unwrap();
    let raw = owl_msime_session_handle_action_json(session, request.as_ptr());
    assert!(!raw.is_null());
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    owl_msime_string_free(raw);
    serde_json::from_str(&text).unwrap()
}

fn build_resources(root: &std::path::Path) -> std::path::PathBuf {
    let resources = root.join("resources");
    std::fs::create_dir_all(&resources).unwrap();
    let pinyin = resources.join("msime-pinyin.db");
    let connection = Connection::open(&pinyin).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE tbl_1_n (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE TABLE tbl_1_h (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE TABLE tbl_2_n (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE TABLE tbl_1_s (\"key\" TEXT, \"jp\" TEXT, \"value\" TEXT, \"weight\" INTEGER DEFAULT 0);
             CREATE TABLE quick_parases (\"key\" TEXT, \"value\" TEXT, \"weight\" INTEGER);
             INSERT INTO tbl_1_n VALUES ('ni', 'n', '你', 5000);",
        )
        .unwrap();
    drop(connection);
    resources
}

fn create_session(
    root: &std::path::Path,
    resources: &std::path::Path,
) -> *mut owl_msime_ffi::OwlMsimeSession {
    let pinyin = resources.join("msime-pinyin.db");
    let empty = CString::new("").unwrap();
    let resources_c = c_path(resources);
    let pinyin_c = c_path(&pinyin);
    let user_c = c_path(&root.join("user"));
    let cache_c = c_path(&root.join("cache"));
    let dictionaries_c = c_path(&root.join("dictionaries"));
    let mut error: *mut c_char = ptr::null_mut();
    let session = owl_msime_session_create_with_roots(
        pinyin_c.as_ptr(),
        empty.as_ptr(),
        resources_c.as_ptr(),
        user_c.as_ptr(),
        cache_c.as_ptr(),
        dictionaries_c.as_ptr(),
        5,
        &mut error,
    );
    if !error.is_null() {
        let message = unsafe { CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned();
        owl_msime_string_free(error);
        panic!("{message}");
    }
    assert!(!session.is_null());
    session
}

#[test]
fn finalize_waits_for_sessions_and_allows_reopen() {
    let root = TempDir::new().unwrap();
    let resources = build_resources(root.path());
    let session = create_session(root.path(), &resources);

    assert!(!owl_msime_engine_finalize());
    assert_eq!(
        call_json(session, r#"{"op":"insert","ch":"n"}"#)["ok"],
        true
    );
    let frame = call_json(session, r#"{"op":"insert","ch":"i"}"#);
    assert_eq!(frame["ok"], true);
    assert!(frame["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .any(|candidate| candidate["text"] == "你"));

    owl_msime_session_destroy(session);
    assert!(owl_msime_engine_finalize());
    assert!(owl_msime_engine_finalize());

    let reopened = create_session(root.path(), &resources);
    let frame = call_json(reopened, r#"{"op":"insert","ch":"n"}"#);
    assert_eq!(frame["ok"], true);
    owl_msime_session_destroy(reopened);
    assert!(owl_msime_engine_finalize());
}
