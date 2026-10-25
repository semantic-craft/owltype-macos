#![allow(unsafe_code)]

use std::ffi::{c_char, CStr, CString};
use std::collections::HashSet;
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use msime_engine::host::{Command, EngineOptions, HelpcodeKeymap, Session as EngineSession};
use msime_engine::{
    ensure_english_schema, FrequencyAdjustmentMode, SchemeSet, SchemeType,
    SentenceAssociationOptions, ShuangpinHelpcodeModes, ShuangpinProfileKind, WubiProfileKind,
};
use msime_input_runtime::{Action, Runtime, View};
use serde::{Deserialize, Serialize};
use tempfile::TempDir;

pub struct OwlMsimeSession {
    runtime: Runtime<EngineSession>,
    options: EngineOptions,
    page_size: u8,
    input_mode: String,
    pinyin_scheme: String,
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
    mode: Option<String>,
    #[serde(default)]
    scheme: Option<String>,
    #[serde(default)]
    page_size: Option<u32>,
  #[serde(default)]
  name: Option<String>,
  #[serde(default)]
  value: Option<bool>,
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
    pub raw_input: String,
    pub preedit: String,
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
            "{{\"ok\":false,\"error\":{},\"consumed\":false,\"committed_text\":null,\"cleared\":false,\"raw_input\":\"\",\"preedit\":\"\",\"page\":0,\"page_size\":5,\"highlighted_index\":0,\"has_more_pages\":false,\"candidates\":[]}}",
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
        raw_input: String::new(),
        preedit: String::new(),
        page: 0,
        page_size: 5,
        highlighted_index: 0,
        has_more_pages: false,
        candidates: Vec::new(),
    }
}

fn snapshot_from_view(
    view: View,
    consumed: bool,
    committed_text: Option<String>,
    cleared: bool,
) -> SnapshotResponseDto {
    let highlighted_index = view
        .candidates
        .iter()
        .position(|c| c.highlighted)
        .unwrap_or(0);
    let has_more_pages = view.page + 1 < view.page_count;
    let input_len = view.editing_text.len();
    let preedit = if view.phrase_prefix.is_empty() {
        view.preedit
    } else {
        format!("{}{}", view.phrase_prefix, view.preedit)
    };
    let candidates = view
        .candidates
        .into_iter()
        .map(|c| CandidateDto {
            text: c.text,
            comment: if c.annotation.is_empty() {
                None
            } else {
                Some(c.annotation)
            },
            kind: "Phrase".to_owned(),
            input_len,
        })
        .collect();
    SnapshotResponseDto {
        ok: true,
        error: None,
        consumed,
        committed_text,
        cleared,
        raw_input: view.editing_text,
        preedit,
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
        "microsoft" | "sogou" => Some(ShuangpinProfileKind::Microsoft),
        "ziranma" | "ziguang" | "jiajia" => Some(ShuangpinProfileKind::Ziranma),
        "abc" => Some(ShuangpinProfileKind::SmartAbc),
        "shoudao" => Some(ShuangpinProfileKind::Shoudao),
        _ => None,
    }
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

impl OwlMsimeSession {
    pub fn create(
        pinyin_db_path: &str,
        english_db_path: &str,
        user_data_dir: &str,
        page_size: u32,
    ) -> Result<Self, String> {
        let trimmed_pinyin = pinyin_db_path.trim();
        if trimmed_pinyin.is_empty() {
            return Err("pinyin_db_path is empty".to_owned());
        }
        let pinyin_src = fs::canonicalize(trimmed_pinyin)
            .map_err(|e| format!("failed to resolve pinyin_db_path {trimmed_pinyin}: {e}"))?;
        if !pinyin_src.is_file() {
            return Err(format!("pinyin_db_path is not a file: {}", pinyin_src.display()));
        }

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

        let resources_dir = base_dir.join("msime-resources");
        let user_dir = base_dir.join("msime-user");
        let cache_dir = base_dir.join("msime-cache");
        let dict_dir = base_dir.join("msime-dicts");
        for dir in [&resources_dir, &user_dir, &cache_dir, &dict_dir] {
            fs::create_dir_all(dir)
                .map_err(|e| format!("failed to create runtime dir {}: {e}", dir.display()))?;
        }

        let staged_pinyin = dict_dir.join("msime-pinyin.db");
        stage_file_if_needed(&pinyin_src, &staged_pinyin)
            .map_err(|e| format!("failed to stage msime-pinyin.db: {e}"))?;

        let staged_english = dict_dir.join("msime-english.db");
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

        let page_size_u8 = clamp_page_size(page_size);
        let options = EngineOptions {
            resources: resources_dir.to_string_lossy().into_owned(),
            user_data: user_dir.to_string_lossy().into_owned(),
            cache: cache_dir.to_string_lossy().into_owned(),
            dictionaries: dict_dir.to_string_lossy().into_owned(),
            scheme: SchemeType::Quanpin as u8,
            enabled_schemes: SchemeSet::ALL,
            shuangpin_profile: ShuangpinProfileKind::Xiaohe as u8,
            shuangpin_custom_profile: None,
            shuangpin_preedit_uses_raw: true,
            single_character_only: false,
            learning: true,
            learn_english_on_enter: true,
            autocorrect_transposition: false,
            autocorrect_neighbor: false,
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
            english_minimum_prefix: 5,
            english_first_page_count: 1,
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
            local_shift_letter_entry: false,
            chaizi_traditional_output: false,
            command_table: Vec::new(),
            plugin_commands: Vec::new(),
            mention_entries: Vec::new(),
            quick_phrase_table: Vec::new(),
            quick_phrase_candidates: false,
            quick_phrase_frequency: true,
            sentence_association: SentenceAssociationOptions::default(),
            rescoring_context: String::new(),
            sentence_alternatives: false,
            first_page_rows: usize::from(page_size_u8),
            vietnamese_input_method: 0,
            vietnamese_tone_style: 0,
            cantonese_dictionary: String::new(),
            zhuyin_dictionary: String::new(),
            stroke_dictionary: String::new(),
            japanese_dictionary: String::new(),
            wubi_dictionary: String::new(),
        };

        let engine_session = EngineSession::new(&options).map_err(|e| e.to_string())?;
        let mut runtime = Runtime::new(engine_session, page_size_u8).map_err(|e| e.to_string())?;
        let _ = runtime.focus(true).map_err(|e| e.to_string())?;

        Ok(Self {
            runtime,
            options,
            page_size: page_size_u8,
            input_mode: "chinese".to_owned(),
            pinyin_scheme: "quanpin".to_owned(),
            _temp_dir: temp_dir,
        })
    }

    pub fn snapshot(&self) -> SnapshotResponseDto {
        snapshot_from_view(self.runtime.view(), false, None, false)
    }

    fn rebuild_engine_if_needed(&mut self) -> Result<(), String> {
        let desired_scheme = if self.input_mode == "wubi" {
            SchemeType::Wubi as u8
        } else if shuangpin_profile_for_name(&self.pinyin_scheme).is_some() {
            SchemeType::Shuangpin as u8
        } else {
            SchemeType::Quanpin as u8
        };
        let desired_profile = shuangpin_profile_for_name(&self.pinyin_scheme)
            .unwrap_or(ShuangpinProfileKind::Xiaohe) as u8;

        if self.options.scheme != desired_scheme
            || self.options.shuangpin_profile != desired_profile
        {
            let _ = self.runtime.dispatch(Action::Command(Command::Cancel));
            self.options.scheme = desired_scheme;
            self.options.shuangpin_profile = desired_profile;
            self.options.first_page_rows = usize::from(self.page_size);
            let new_engine = EngineSession::new(&self.options).map_err(|e| e.to_string())?;
            self.runtime
                .replace_engine(new_engine, self.page_size)
                .map_err(|e| e.to_string())?;
        }
        let dedicated_english = self.input_mode == "english";
        let _ = self
            .runtime
            .set_dedicated_english(dedicated_english)
            .map_err(|e| e.to_string())?;
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
                    return snapshot_from_view(self.runtime.view(), false, None, false);
                }
                let byte = ch as u8;
                let shift = byte.is_ascii_uppercase();
                match self.runtime.dispatch(Action::Character { value: byte, shift }) {
                    Ok(transition) => snapshot_from_view(
                        transition.view,
                        transition.handled,
                        transition.commit,
                        false,
                    ),
                    Err(err) => error_response(err.to_string()),
                }
            }
            "backspace" => match self.runtime.dispatch(Action::Command(Command::Backspace)) {
                Ok(transition) => snapshot_from_view(
                    transition.view,
                    transition.handled,
                    transition.commit,
                    false,
                ),
                Err(err) => error_response(err.to_string()),
            },
            "commit_raw" => match self.runtime.dispatch(Action::Command(Command::CommitRaw)) {
                Ok(transition) => snapshot_from_view(
                    transition.view,
                    transition.handled,
                    transition.commit,
                    false,
                ),
                Err(err) => error_response(err.to_string()),
            },
            "space" => match self.runtime.dispatch(Action::SelectHighlighted) {
                Ok(transition) => snapshot_from_view(
                    transition.view,
                    transition.handled,
                    transition.commit,
                    false,
                ),
                Err(err) => error_response(err.to_string()),
            },
            "clear" => {
                let had_input = !self.runtime.view().editing_text.is_empty();
                match self.runtime.dispatch(Action::Command(Command::Cancel)) {
                    Ok(transition) => snapshot_from_view(
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
                    return snapshot_from_view(self.runtime.view(), true, None, false);
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
                    Some(t) => snapshot_from_view(t.view, t.handled, t.commit, false),
                    None => snapshot_from_view(self.runtime.view(), false, None, false),
                }
            }
            "turn_page" => {
                let delta = payload.delta.unwrap_or(0);
                if delta == 0 {
                    return snapshot_from_view(self.runtime.view(), false, None, false);
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
                        snapshot_from_view(t.view, t.handled && moved, t.commit, false)
                    }
                    None => snapshot_from_view(self.runtime.view(), false, None, false),
                }
            }
            "select_visible" => {
                let Some(index) = payload.index else {
                    return error_response("select_visible requires index");
                };
                let view = self.runtime.view();
                let Some(candidate) = view.candidates.get(index) else {
                    return snapshot_from_view(view, false, None, false);
                };
                let id = candidate.id;
                match self.runtime.dispatch(Action::Select(id)) {
                    Ok(transition) => snapshot_from_view(
                        transition.view,
                        transition.handled,
                        transition.commit,
                        false,
                    ),
                    Err(err) => error_response(err.to_string()),
                }
            }
            "set_input_mode" => {
                let Some(mode) = payload.mode else {
                    return error_response("set_input_mode requires mode");
                };
                self.input_mode = mode;
                if let Err(err) = self.rebuild_engine_if_needed() {
                    return error_response(err);
                }
                snapshot_from_view(self.runtime.view(), true, None, false)
            }
            "set_pinyin_scheme" => {
                let Some(scheme) = payload.scheme else {
                    return error_response("set_pinyin_scheme requires scheme");
                };
                self.pinyin_scheme = scheme;
                if let Err(err) = self.rebuild_engine_if_needed() {
                    return error_response(err);
                }
                snapshot_from_view(self.runtime.view(), true, None, false)
            }
            "set_page_size" => {
                let Some(ps) = payload.page_size else {
                    return error_response("set_page_size requires page_size");
                };
                let clamped = clamp_page_size(ps);
                self.page_size = clamped;
                self.options.first_page_rows = usize::from(clamped);
                let _ = self.runtime.set_page_size(clamped);
                snapshot_from_view(self.runtime.view(), true, None, false)
            }
            "set_option" => {
                let Some(name) = payload.name.as_deref() else {
                    return error_response("set_option requires name");
                };
                let value = payload.value.unwrap_or(false);
                match name {
                    "ascii_punct" => {
                        self.options.chinese_punctuation = !value;
                    }
                    "emoji_suggestion" => {
                        self.options.mixed_emoji = value;
                        self.options.local_emoji = value;
                    }
                    _ => {}
                }
                snapshot_from_view(self.runtime.view(), true, None, false)
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
pub extern "C" fn owl_msime_session_snapshot_json(
    session: *const OwlMsimeSession,
) -> *mut c_char {
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
               ('ni', 'n', '泥', 2000);

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
               ('ni''hao', 'nh', '昵号', 1000);

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
               ('shi', 's', '式', 2000);",
        )
        .expect("populate test sqlite db");
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
        assert_eq!(selected.committed_text.as_deref(), Some(second_text.as_str()));
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

        owl_msime_session_destroy(session);
    }
}
