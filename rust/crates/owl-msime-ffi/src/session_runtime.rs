use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex};

use msime_engine::host::{prepare_options, Command, EngineOptions, Session as EngineSession};
use msime_engine::{
    ensure_english_schema, reject_redirected_directory, roots_overlap, SchemeType,
    ShuangpinCustomTable, ShuangpinProfileKind,
};
use msime_input_runtime::{Action, Runtime, View};
use serde::{Deserialize, Serialize};
use tempfile::TempDir;

use crate::pinned_transform::{OwlPinnedState, OwlPinnedTransform};
use crate::punctuation_menu::PunctuationMenu;
use crate::rerank;
use crate::session_roots::{
    prepare_explicit_roots, product_engine_options, reconcile_quick_phrases, resolve_pinyin_source,
    stage_file_if_needed, SessionRoots,
};

pub struct OwlMsimeSession {
    pub(crate) runtime: Runtime<EngineSession>,
    pub(crate) rerank: rerank::RerankState,
    pub(crate) options: EngineOptions,
    pub(crate) source_pinyin_path: PathBuf,
    pub(crate) staged_pinyin_path: PathBuf,
    pub(crate) page_size: u8,
    pub(crate) input_mode: String,
    pub(crate) pinyin_scheme: String,
    pub(crate) quick_phrase_candidates: bool,
    pub(crate) wubi_code_hint: bool,
    pub(crate) wubi_auto_clear: bool,
    pub(crate) wubi_candidate_mode: String,
    pub(crate) wubi_z_reverse_lookup: bool,
    pub(crate) wubi_english_channel: bool,
    pub(crate) wubi_user_dict_learning: bool,
    pub(crate) pinned_state: Arc<Mutex<OwlPinnedState>>,
    pub(crate) punctuation_menu: Option<PunctuationMenu>,
    pub(crate) punctuation_menu_generation: u64,
    pub(crate) _temp_dir: Option<TempDir>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct ActionPayload {
    pub(crate) op: String,
    #[serde(default)]
    pub(crate) ch: Option<String>,
    #[serde(default)]
    pub(crate) delta: Option<i32>,
    #[serde(default)]
    pub(crate) index: Option<usize>,
    #[serde(default)]
    pub(crate) start: Option<usize>,
    #[serde(default)]
    pub(crate) count: Option<usize>,
    #[serde(default)]
    pub(crate) pos: Option<usize>,
    #[serde(default)]
    pub(crate) generation: Option<u64>,
    #[serde(default)]
    pub(crate) is_absolute: Option<bool>,
    #[serde(default)]
    pub(crate) ascii: Option<bool>,
    #[serde(default)]
    pub(crate) target: Option<String>,
    #[serde(default)]
    pub(crate) text: Option<String>,
    #[serde(default)]
    pub(crate) traditional_sources: Vec<TraditionalPinSourceDto>,
    #[serde(default)]
    pub(crate) mode: Option<String>,
    #[serde(default)]
    pub(crate) scheme: Option<String>,
    #[serde(default)]
    pub(crate) profile: Option<String>,
    #[serde(default)]
    pub(crate) custom_profile: Option<ShuangpinCustomTableDto>,
    #[serde(default)]
    pub(crate) page_size: Option<u32>,
    #[serde(default)]
    pub(crate) mask: Option<u32>,
    #[serde(default)]
    pub(crate) name: Option<String>,
    #[serde(default)]
    pub(crate) value: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TraditionalPinSourceDto {
    pub(crate) code: String,
    /// The final text shown to the user for this pin.
    pub(crate) text: String,
    /// The exact candidate text whose host display conversion produces `text`.
    pub(crate) source: String,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct ShuangpinCustomTableDto {
    pub(crate) initials: Vec<(String, String)>,
    pub(crate) finals: Vec<(String, String)>,
    pub(crate) zero_initials: Vec<(String, String)>,
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
    pub local_mode: String,
    pub spelling_symbols: String,
    pub caret_position: usize,
    pub preedit_caret_byte: usize,
    pub page: usize,
    pub page_size: usize,
    pub highlighted_index: usize,
    pub has_more_pages: bool,
    pub candidates: Vec<CandidateDto>,
}

pub(crate) fn clamp_page_size(page_size: u32) -> u8 {
    if page_size == 0 {
        5
    } else {
        page_size.clamp(1, 10) as u8
    }
}

const HOST_GENERATION_SEQUENCE_MASK: u64 = (1_u64 << 63) - 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HostGenerationNamespace {
    Runtime = 0,
    PunctuationMenu = 1,
}

impl HostGenerationNamespace {
    pub(crate) fn encode(self, sequence: u64) -> u64 {
        ((self as u64) << 63) | (sequence & HOST_GENERATION_SEQUENCE_MASK)
    }
}

pub(crate) fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    Some(c_str.to_string_lossy().into_owned())
}

pub(crate) fn into_c_string_ptr<T: Serialize>(value: &T) -> *mut c_char {
    let json = serde_json::to_string(value).unwrap_or_else(|err| {
        format!(
            "{{\"ok\":false,\"error\":{},\"consumed\":false,\"committed_text\":null,\"cleared\":false,\"generation\":0,\"raw_input\":\"\",\"preedit\":\"\",\"local_mode\":\"none\",\"spelling_symbols\":\"\",\"caret_position\":0,\"preedit_caret_byte\":0,\"page\":0,\"page_size\":5,\"highlighted_index\":0,\"has_more_pages\":false,\"candidates\":[]}}",
            serde_json::to_string(&err.to_string()).unwrap_or_else(|_| "\"serialization error\"".to_owned())
        )
    });
    match CString::new(json) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

pub(crate) fn error_response(message: impl Into<String>) -> SnapshotResponseDto {
    SnapshotResponseDto {
        ok: false,
        error: Some(message.into()),
        consumed: false,
        committed_text: None,
        cleared: false,
        generation: 0,
        raw_input: String::new(),
        preedit: String::new(),
        local_mode: "none".to_owned(),
        spelling_symbols: String::new(),
        caret_position: 0,
        preedit_caret_byte: 0,
        page: 0,
        page_size: 5,
        highlighted_index: 0,
        has_more_pages: false,
        candidates: Vec::new(),
    }
}

pub(crate) fn map_caret_to_preedit_byte(
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

// Pinned macOS WubiCodeHintPolicy + CandidateAnnotationRun: a remaining-code
// hint wins when available, otherwise retain the engine annotation. Script notes
// keep their existing independent presentation priority in Owltype.
pub(crate) fn wubi_hint_prefix(view: &View, enabled: bool) -> Option<&str> {
    (enabled
        && view.scheme == SchemeType::Wubi as u8
        && view.local_mode == "none"
        && !view.answered_by_pinyin_fallback)
        .then_some(view.preedit.as_str())
}

pub(crate) fn show_wubi_annotation(
    view: &View,
    candidate: &msime_input_runtime::Candidate,
    wubi_code_hint: bool,
) -> bool {
    if view.scheme != SchemeType::Wubi as u8 {
        return false;
    }
    wubi_code_hint
        || view.answered_by_pinyin_fallback
        || view.preedit.contains('z')
        || candidate.code.contains('\'')
}

pub(crate) fn candidate_comment(
    candidate: &msime_input_runtime::Candidate,
    wubi_prefix: Option<&str>,
    wubi_annotations: bool,
) -> Option<String> {
    if let Some(note) = candidate
        .script_annotation
        .as_ref()
        .filter(|note| !note.is_empty())
    {
        return Some(note.clone());
    }
    if let Some(typed) = wubi_prefix.filter(|typed| !typed.is_empty() && typed.len() <= 64) {
        if candidate.code.len() <= 64 {
            if let Some(suffix) = candidate
                .code
                .strip_prefix(typed)
                .filter(|suffix| !suffix.is_empty())
            {
                return Some(suffix.to_owned());
            }
        }
    }
    (wubi_annotations && !candidate.annotation.is_empty()).then(|| candidate.annotation.clone())
}

pub(crate) fn snapshot_from_view(
    view: View,
    consumed: bool,
    committed_text: Option<String>,
    cleared: bool,
    wubi_code_hint: bool,
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
    let hint_prefix = wubi_hint_prefix(&view, wubi_code_hint).map(str::to_owned);
    let candidates = view
        .candidates
        .iter()
        .map(|c| {
            let wubi_annotations = show_wubi_annotation(&view, c, wubi_code_hint);
            let comment = candidate_comment(c, hint_prefix.as_deref(), wubi_annotations);
            CandidateDto {
                text: c.text.clone(),
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
        generation: HostGenerationNamespace::Runtime.encode(view.generation),
        raw_input,
        preedit,
        local_mode: view.local_mode,
        spelling_symbols: view.spelling_symbols,
        caret_position,
        preedit_caret_byte,
        page: view.page,
        page_size: view.page_size,
        highlighted_index,
        has_more_pages,
        candidates,
    }
}

pub(crate) fn shuangpin_profile_for_name(name: &str) -> Option<ShuangpinProfileKind> {
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

pub(crate) fn is_known_pinyin_scheme(name: &str) -> bool {
    matches!(name, "quanpin" | "wubi" | "wubi_pinyin") || shuangpin_profile_for_name(name).is_some()
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
        auxiliary_resources_dir: &str,
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

        // Dictionary generations own only the mutable working dictionaries. Auxiliary
        // catalogs remain in the signed application, including for existing 2.1.0 packs.
        let auxiliary = Path::new(auxiliary_resources_dir);
        if !auxiliary.is_absolute() || !auxiliary.is_dir() {
            return Err("auxiliary resources must be an existing absolute directory".into());
        }
        reject_redirected_directory(auxiliary)
            .map_err(|e| format!("invalid auxiliary resources: {e}"))?;
        let auxiliary = fs::canonicalize(auxiliary)
            .map_err(|e| format!("cannot resolve auxiliary resources: {e}"))?;
        for writable in [&user, &cache, &dictionaries] {
            if roots_overlap(&auxiliary, writable) {
                return Err("auxiliary resources overlap a writable session root".into());
            }
        }
        let page_size = clamp_page_size(page_size);
        let options = product_engine_options(&auxiliary, &user, &cache, &dictionaries, page_size);
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
            wubi_single_first: false,
            page_size: usize::from(page_size),
            wubi_z_reverse_lookup: true,
        }));
        runtime.set_candidate_transform(Some(Box::new(OwlPinnedTransform {
            state: Arc::clone(&pinned_state),
        })));

        Ok(Self {
            runtime,
            rerank: rerank::RerankState::default(),
            options,
            source_pinyin_path,
            staged_pinyin_path,
            page_size,
            input_mode: "chinese".to_owned(),
            pinyin_scheme: "quanpin".to_owned(),
            quick_phrase_candidates: false,
            wubi_code_hint: false,
            wubi_auto_clear: false,
            wubi_candidate_mode: "normal".to_owned(),
            wubi_z_reverse_lookup: true,
            wubi_english_channel: false,
            wubi_user_dict_learning: true,
            pinned_state,
            punctuation_menu: None,
            punctuation_menu_generation: 0,
            _temp_dir: temp_dir,
        })
    }

    pub(crate) fn temp_english_backtick(&self, view: &View) -> bool {
        self.input_mode == "wubi"
            && self.wubi_english_channel
            && view.local_mode == "temporary_english"
    }

    pub(crate) fn build_snapshot(
        &self,
        view: View,
        consumed: bool,
        committed_text: Option<String>,
        cleared: bool,
    ) -> SnapshotResponseDto {
        let show_hint = self.wubi_code_hint;
        let backtick = self.temp_english_backtick(&view);
        snapshot_from_view(view, consumed, committed_text, cleared, show_hint, backtick)
    }

    pub fn snapshot(&self) -> SnapshotResponseDto {
        if self.punctuation_menu.is_some() {
            self.build_punctuation_menu_snapshot(false, None, false)
        } else {
            self.build_snapshot(self.runtime.view(), false, None, false)
        }
    }

    fn next_punctuation_menu_generation(&mut self) -> u64 {
        let next =
            (self.punctuation_menu_generation & HOST_GENERATION_SEQUENCE_MASK).wrapping_add(1);
        self.punctuation_menu_generation = if next == 0 { 1 } else { next };
        HostGenerationNamespace::PunctuationMenu.encode(self.punctuation_menu_generation)
    }

    pub(crate) fn build_punctuation_menu_snapshot(
        &self,
        consumed: bool,
        committed_text: Option<String>,
        cleared: bool,
    ) -> SnapshotResponseDto {
        let Some(menu) = self.punctuation_menu.as_ref() else {
            return self.build_snapshot(self.runtime.view(), consumed, committed_text, cleared);
        };
        let page_size = usize::from(self.page_size).max(1);
        let page = menu.page(page_size);
        let start = page * page_size;
        let end = (start + page_size).min(menu.candidates().len());
        let trigger = menu.trigger().to_string();
        SnapshotResponseDto {
            ok: true,
            error: None,
            consumed,
            committed_text,
            cleared,
            generation: menu.generation(),
            raw_input: trigger.clone(),
            preedit: trigger.clone(),
            local_mode: "none".to_owned(),
            spelling_symbols: String::new(),
            caret_position: trigger.len(),
            preedit_caret_byte: trigger.len(),
            page,
            page_size,
            highlighted_index: menu.highlighted().saturating_sub(start),
            has_more_pages: end < menu.candidates().len(),
            candidates: menu.candidates()[start..end]
                .iter()
                .map(|candidate| CandidateDto {
                    text: (*candidate).to_owned(),
                    comment: None,
                    kind: "Phrase".to_owned(),
                    input_len: trigger.len(),
                })
                .collect(),
        }
    }

    pub(crate) fn open_punctuation_menu(&mut self, trigger: char) -> Result<SnapshotResponseDto, String> {
        if PunctuationMenu::new(trigger, 0).is_none() {
            return Err(format!("unsupported punctuation menu trigger: {trigger}"));
        }

        if let Some(mut menu) = self.punctuation_menu.take() {
            if menu.trigger() == trigger {
                menu.cycle();
                menu.set_generation(self.next_punctuation_menu_generation());
                self.punctuation_menu = Some(menu);
                return Ok(self.build_punctuation_menu_snapshot(true, None, false));
            }
            let previous = menu.selected().to_owned();
            let generation = self.next_punctuation_menu_generation();
            self.punctuation_menu = PunctuationMenu::new(trigger, generation);
            return Ok(self.build_punctuation_menu_snapshot(true, Some(previous), false));
        }

        let view = self.runtime.view();
        let has_composition = !view.phrase_prefix.is_empty()
            || !view.editing_text.is_empty()
            || !view.preedit.is_empty()
            || !view.candidates.is_empty();
        let committed_text = if has_composition {
            let transition = self
                .runtime
                .dispatch(Action::Finish)
                .map_err(|error| error.to_string())?;
            self.sync_pinned_state_from_view(&transition.view);
            transition.commit
        } else {
            None
        };
        let generation = self.next_punctuation_menu_generation();
        self.punctuation_menu = PunctuationMenu::new(trigger, generation);
        Ok(self.build_punctuation_menu_snapshot(true, committed_text, false))
    }

    pub(crate) fn select_punctuation_candidate(&mut self, index: usize) -> SnapshotResponseDto {
        let Some(selected) = self
            .punctuation_menu
            .as_ref()
            .and_then(|menu| menu.candidate(index))
        else {
            return self.build_punctuation_menu_snapshot(false, None, false);
        };
        self.punctuation_menu = None;
        self.build_snapshot(self.runtime.view(), true, Some(selected.to_owned()), false)
    }

    pub(crate) fn select_punctuation_token(
        &mut self,
        index: usize,
        is_absolute: bool,
        generation: Option<u64>,
    ) -> SnapshotResponseDto {
        let page_size = usize::from(self.page_size).max(1);
        let Some(menu) = self.punctuation_menu.as_ref() else {
            return self.build_snapshot(self.runtime.view(), false, None, false);
        };
        if generation.is_some_and(|value| value != menu.generation()) {
            return self.build_punctuation_menu_snapshot(false, None, false);
        }
        let page_start = menu.page(page_size) * page_size;
        let absolute = if is_absolute {
            index
        } else {
            page_start + index
        };
        self.select_punctuation_candidate(absolute)
    }

    pub(crate) fn move_punctuation_highlight(&mut self, delta: i32) -> SnapshotResponseDto {
        let changed = {
            let Some(menu) = self.punctuation_menu.as_mut() else {
                return self.build_snapshot(self.runtime.view(), false, None, false);
            };
            if delta == 0 {
                return self.build_punctuation_menu_snapshot(true, None, false);
            }
            menu.move_highlight(delta)
        };
        if changed {
            let generation = self.next_punctuation_menu_generation();
            if let Some(menu) = self.punctuation_menu.as_mut() {
                menu.set_generation(generation);
            }
        }
        self.build_punctuation_menu_snapshot(true, None, false)
    }

    pub(crate) fn turn_punctuation_page(&mut self, delta: i32) -> SnapshotResponseDto {
        let page_size = usize::from(self.page_size).max(1);
        let changed = {
            let Some(menu) = self.punctuation_menu.as_mut() else {
                return self.build_snapshot(self.runtime.view(), false, None, false);
            };
            if delta == 0 {
                return self.build_punctuation_menu_snapshot(false, None, false);
            }
            let current = menu.page(page_size);
            let next = if delta < 0 {
                current.saturating_sub(delta.unsigned_abs() as usize)
            } else {
                current
                    .saturating_add(delta as usize)
                    .min(menu.page_count(page_size).saturating_sub(1))
            };
            menu.set_page(next, page_size)
        };
        if changed {
            let generation = self.next_punctuation_menu_generation();
            if let Some(menu) = self.punctuation_menu.as_mut() {
                menu.set_generation(generation);
            }
        }
        self.build_punctuation_menu_snapshot(true, None, false)
    }

    pub(crate) fn peek_punctuation_candidates(&self, start: usize, count: usize) -> SnapshotResponseDto {
        let mut dto = self.build_punctuation_menu_snapshot(true, None, false);
        let Some(menu) = self.punctuation_menu.as_ref() else {
            return dto;
        };
        let input_len = menu.trigger().len_utf8();
        dto.candidates = menu
            .candidates()
            .iter()
            .skip(start)
            .take(count)
            .map(|candidate| CandidateDto {
                text: (*candidate).to_owned(),
                comment: None,
                kind: "Phrase".to_owned(),
                input_len,
            })
            .collect();
        dto
    }

    pub(crate) fn merge_punctuation_menu_commit(&mut self, dto: &mut SnapshotResponseDto) {
        if !dto.ok {
            return;
        }
        let Some(menu) = self.punctuation_menu.take() else {
            return;
        };
        let selected = menu.selected();
        dto.committed_text = Some(match dto.committed_text.take() {
            Some(committed) => format!("{selected}{committed}"),
            None => selected.to_owned(),
        });
        dto.consumed = true;
    }

    pub(crate) fn sync_pinned_state_for_upcoming_input(&self, next_input: String, caret_at_end: bool) {
        if let Ok(mut guard) = self.pinned_state.lock() {
            guard.enabled = self.input_mode == "chinese" && self.pinyin_scheme == "quanpin";
            guard.active_input = next_input;
            guard.caret_at_end = caret_at_end;
            guard.input_mode = self.input_mode.clone();
            guard.pinyin_scheme = self.pinyin_scheme.clone();
            guard.wubi_single_first = self.wubi_candidate_mode == "single_first";
            guard.page_size = usize::from(self.page_size);
            guard.wubi_z_reverse_lookup = self.wubi_z_reverse_lookup;
        }
    }

    pub(crate) fn sync_pinned_state_from_view(&self, view: &View) {
        if let Ok(mut guard) = self.pinned_state.lock() {
            guard.enabled = self.input_mode == "chinese" && self.pinyin_scheme == "quanpin";
            guard.active_input = view.editing_text.clone();
            guard.caret_at_end =
                view.phrase_prefix.is_empty() && view.caret_position == view.editing_text.len();
            guard.input_mode = self.input_mode.clone();
            guard.pinyin_scheme = self.pinyin_scheme.clone();
            guard.wubi_single_first = self.wubi_candidate_mode == "single_first";
            guard.page_size = usize::from(self.page_size);
            guard.wubi_z_reverse_lookup = self.wubi_z_reverse_lookup;
        }
    }

    pub(crate) fn rebuild_engine_if_needed(&mut self) -> Result<(), String> {
        self.rebuild_engine_if_needed_with_force(false)
    }

    pub(crate) fn rebuild_engine_if_needed_with_force(&mut self, force: bool) -> Result<(), String> {
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
            self.options.quick_phrase_candidates = self.quick_phrase_candidates;
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
            self.rerank.engine_replaced(&mut self.runtime);
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

    pub(crate) fn force_rebuild_engine(&mut self) -> Result<(), String> {
        let _ = self.runtime.dispatch(Action::Command(Command::Cancel));
        self.options.first_page_rows = usize::from(self.page_size);
        let mut new_engine = EngineSession::new(&self.options).map_err(|e| e.to_string())?;
        new_engine.set_wubi_z_pinyin_lookup(self.wubi_z_reverse_lookup);
        self.runtime
            .replace_engine(new_engine, self.page_size)
            .map_err(|e| e.to_string())?;
        self.rerank.engine_replaced(&mut self.runtime);
        let view = self.runtime.view();
        self.sync_pinned_state_from_view(&view);
        Ok(())
    }

    pub(crate) fn apply_quick_phrase_preference_if_idle(&mut self) -> Result<(), String> {
        let enabled = self.quick_phrase_candidates;
        if self.options.quick_phrase_candidates != enabled && self.runtime.is_idle() {
            self.runtime
                .set_quick_phrase_candidates(enabled)
                .map_err(|error| error.to_string())?;
            self.options.quick_phrase_candidates = enabled;
        }
        Ok(())
    }

}
