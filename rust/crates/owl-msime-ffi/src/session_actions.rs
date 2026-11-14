use std::collections::{HashMap, HashSet};
use std::path::Path;

use msime_engine::host::{check_shuangpin_custom_profile, Command};
use msime_engine::{fuzzy_rule, QuickPhraseEntry, ShuangpinCustomTable, WubiProfileKind};
use msime_input_runtime::{Action, CandidateId};
use serde_json::{json, Value};

use crate::pinned_transform::PinnedWord;
use crate::punctuation_menu::PunctuationMenu;
use crate::session_roots::reconcile_quick_phrases;
use crate::session_runtime::{
    candidate_comment, clamp_page_size, error_response, is_known_pinyin_scheme,
    show_wubi_annotation, wubi_hint_prefix, ActionPayload, CandidateDto, HostGenerationNamespace,
    OwlMsimeSession, SnapshotResponseDto,
};

impl OwlMsimeSession {
    pub fn handle_action_json(&mut self, action_json: &str) -> SnapshotResponseDto {
        let payload: ActionPayload = match serde_json::from_str(action_json) {
            Ok(p) => p,
            Err(err) => return error_response(format!("invalid action_json: {err}")),
        };
        if let Err(error) = self.apply_quick_phrase_preference_if_idle() {
            return error_response(error);
        }
        self.rerank.apply_pending(&mut self.runtime);
        if payload.op != "peek_candidates" {
            self.rerank.invalidate(&mut self.runtime);
        }

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
                            let mut dto = self.build_snapshot(
                                transition.view,
                                transition.handled,
                                transition.commit,
                                false,
                            );
                            self.merge_punctuation_menu_commit(&mut dto);
                            dto
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
                                let mut dto = self.build_snapshot(cleared_t.view, true, None, true);
                                self.merge_punctuation_menu_commit(&mut dto);
                                return dto;
                            }
                        }
                        self.sync_pinned_state_from_view(&transition.view);
                        let mut dto = self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        );
                        self.merge_punctuation_menu_commit(&mut dto);
                        dto
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "backspace" | "delete" => {
                if self.punctuation_menu.is_some() {
                    self.punctuation_menu = None;
                    return self.build_snapshot(self.runtime.view(), true, None, false);
                }
                let before = self.runtime.view();
                let caret = before.caret_position.min(before.editing_text.len());
                let mut next_input = before.editing_text.clone();
                let delete_forward = payload.op == "delete";
                let next_caret_at_end = if delete_forward && caret < next_input.len() {
                    next_input.remove(caret);
                    before.phrase_prefix.is_empty() && caret == next_input.len()
                } else if !delete_forward && caret > 0 && caret <= next_input.len() {
                    next_input.remove(caret - 1);
                    before.phrase_prefix.is_empty() && (caret - 1 == next_input.len())
                } else {
                    false
                };
                self.sync_pinned_state_for_upcoming_input(next_input, next_caret_at_end);
                let command = if delete_forward {
                    Command::DeleteForward
                } else {
                    Command::Backspace
                };
                match self.runtime.dispatch(Action::Command(command)) {
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
                        let mut dto = self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        );
                        self.merge_punctuation_menu_commit(&mut dto);
                        dto
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "punctuation_menu" => {
                let Some(ch_str) = payload.ch.as_deref() else {
                    return error_response("punctuation_menu requires ch");
                };
                let mut chars = ch_str.chars();
                let Some(trigger) = chars.next() else {
                    return error_response("punctuation_menu ch is empty");
                };
                if chars.next().is_some() || !trigger.is_ascii() {
                    return error_response("punctuation_menu ch must be one ASCII character");
                }
                match self.open_punctuation_menu(trigger) {
                    Ok(dto) => dto,
                    Err(err) => error_response(err),
                }
            }
            "finish" | "finish_on_focus_loss" => {
                if let Some(menu) = self.punctuation_menu.take() {
                    return self.build_snapshot(
                        self.runtime.view(),
                        true,
                        Some(menu.selected().to_owned()),
                        false,
                    );
                }
                let action = if payload.op == "finish_on_focus_loss" {
                    Action::FinishOnFocusLoss
                } else {
                    Action::Finish
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
                    Err(error) => error_response(error.to_string()),
                }
            }
            "balance_pair" => {
                match self
                    .runtime
                    .balance_paired_punctuation_after_auto_close(b'<')
                {
                    Ok(()) => self.build_snapshot(self.runtime.view(), true, None, false),
                    Err(error) => error_response(error.to_string()),
                }
            }
            "segment" => {
                let action = match payload.target.as_deref() {
                    Some("left") => Action::SegmentMoveLeft,
                    Some("right") => Action::SegmentMoveRight,
                    Some("backspace") => Action::SegmentBackspace,
                    _ => return error_response("segment requires left, right or backspace"),
                };
                match self.runtime.dispatch(action) {
                    Ok(transition) => {
                        self.sync_pinned_state_from_view(&transition.view);
                        // Refresh the existing transform with the engine-owned input/caret;
                        // segment deletion and movement can change Quanpin pin eligibility.
                        if let Err(error) =
                            self.runtime.set_caret(Some(transition.view.caret_position))
                        {
                            return error_response(error.to_string());
                        }
                        self.build_snapshot(
                            self.runtime.view(),
                            transition.handled,
                            transition.commit,
                            false,
                        )
                    }
                    Err(error) => error_response(error.to_string()),
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
                        let mut dto = self.build_snapshot(
                            transition.view,
                            transition.handled,
                            transition.commit,
                            false,
                        );
                        self.merge_punctuation_menu_commit(&mut dto);
                        dto
                    }
                    Err(err) => error_response(err.to_string()),
                }
            }
            "commit_raw" => {
                if self.punctuation_menu.is_some() {
                    let index = self
                        .punctuation_menu
                        .as_ref()
                        .map_or(0, PunctuationMenu::highlighted);
                    return self.select_punctuation_candidate(index);
                }
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
                if self.punctuation_menu.is_some() {
                    let index = self
                        .punctuation_menu
                        .as_ref()
                        .map_or(0, PunctuationMenu::highlighted);
                    return self.select_punctuation_candidate(index);
                }
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
                if self.punctuation_menu.is_some() {
                    self.punctuation_menu = None;
                    return self.build_snapshot(self.runtime.view(), true, None, true);
                }
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
                if self.punctuation_menu.is_some() {
                    return self.move_punctuation_highlight(delta);
                }
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
                if self.punctuation_menu.is_some() {
                    return self.turn_punctuation_page(delta);
                }
                if delta == 0 {
                    return self.build_snapshot(self.runtime.view(), false, None, false);
                }
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
                    Some(t) => self.build_snapshot(t.view, t.handled, t.commit, false),
                    None => self.build_snapshot(self.runtime.view(), false, None, false),
                }
            }
            "select_visible" => {
                let Some(index) = payload.index else {
                    return error_response("select_visible requires index");
                };
                if self.punctuation_menu.is_some() {
                    let page_size = usize::from(self.page_size).max(1);
                    let page_start = self
                        .punctuation_menu
                        .as_ref()
                        .map_or(0, |menu| menu.page(page_size) * page_size);
                    return self.select_punctuation_candidate(page_start + index);
                }
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
            "remove_token" => {
                let Some(index) = payload.index else {
                    return error_response("remove_token requires index");
                };
                let view = self.runtime.view();
                let current_generation = HostGenerationNamespace::Runtime.encode(view.generation);
                if self.punctuation_menu.is_some()
                    || payload.is_absolute.unwrap_or(false)
                    || payload.generation != Some(current_generation)
                {
                    return self.build_snapshot(view, false, None, false);
                }
                let Some(candidate) = view.candidates.get(index) else {
                    return self.build_snapshot(view, false, None, false);
                };
                match self.runtime.dispatch(Action::RemoveCandidate(candidate.id)) {
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
            "select_token" => {
                let Some(index) = payload.index else {
                    return error_response("select_token requires index");
                };
                if self.punctuation_menu.is_some() {
                    return self.select_punctuation_token(
                        index,
                        payload.is_absolute.unwrap_or(false),
                        payload.generation,
                    );
                }
                let view = self.runtime.view();
                let current_generation = HostGenerationNamespace::Runtime.encode(view.generation);
                let token_gen = payload.generation.unwrap_or(current_generation);
                if payload.generation.is_some() && token_gen != current_generation {
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
                if self.punctuation_menu.is_some() {
                    return self.peek_punctuation_candidates(start, count);
                }
                let all = self.runtime.all_candidates_cached();
                let view = self.runtime.view();
                let hint_prefix = wubi_hint_prefix(&view, self.wubi_code_hint).map(str::to_owned);
                let show_hint = self.wubi_code_hint;
                let input_len = view.editing_text.len();
                let mut dto = self.build_snapshot(view.clone(), true, None, false);
                dto.generation = HostGenerationNamespace::Runtime.encode(all.generation);
                dto.candidates = all
                    .candidates
                    .into_iter()
                    .skip(start)
                    .take(count)
                    .map(|c| {
                        let wubi_annotations = show_wubi_annotation(&view, &c, show_hint);
                        let comment =
                            candidate_comment(&c, hint_prefix.as_deref(), wubi_annotations);
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
                let mut traditional_sources = HashMap::new();
                let mut conflicting_sources = HashSet::new();
                for source in payload.traditional_sources {
                    if source.code.is_empty() || source.text.is_empty() || source.source.is_empty()
                    {
                        continue;
                    }
                    let key = (source.code, source.text);
                    if let Some(previous) =
                        traditional_sources.insert(key.clone(), source.source.clone())
                    {
                        if previous != source.source {
                            conflicting_sources.insert(key);
                        }
                    }
                }
                for key in conflicting_sources {
                    traditional_sources.remove(&key);
                }
                let mut parsed: HashMap<(String, bool), Vec<PinnedWord>> = HashMap::new();
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
                    let source = trad
                        .then(|| traditional_sources.get(&(code.to_owned(), word.to_owned())))
                        .flatten()
                        .cloned();
                    parsed
                        .entry((code.to_owned(), trad))
                        .or_default()
                        .push(PinnedWord::new(word.to_owned(), trad, source));
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
            "set_wubi_profile" => {
                let Some(profile) = payload
                    .profile
                    .as_deref()
                    .and_then(WubiProfileKind::from_name)
                else {
                    return error_response("set_wubi_profile requires wubi86 or wubi98 profile");
                };
                let previous = self.options.wubi_profile;
                if previous != profile as u8 {
                    self.options.wubi_profile = profile as u8;
                    if let Err(error) = self.force_rebuild_engine() {
                        self.options.wubi_profile = previous;
                        let _ = self.force_rebuild_engine();
                        return error_response(error);
                    }
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
                if self.punctuation_menu.is_some() {
                    self.build_punctuation_menu_snapshot(true, None, false)
                } else {
                    self.build_snapshot(self.runtime.view(), true, None, false)
                }
            }
            "set_option" => {
                let Some(name) = payload.name.as_deref() else {
                    return error_response("set_option requires name");
                };
                let value = payload.value.unwrap_or(false);
                if let Err(err) = self.apply_session_option(name, value) {
                    return error_response(err);
                }
                self.build_snapshot(self.runtime.view(), true, None, false)
            }
            other => error_response(format!("unsupported op: {other}")),
        }
    }

    pub fn configure_rerank(&mut self, config_json: &str) -> Value {
        match self.rerank.configure(&mut self.runtime, config_json) {
            Ok(()) => self.rerank.status(&mut self.runtime),
            Err(error) => json!({"ok": false, "error": error}),
        }
    }

    pub fn rerank_status(&mut self) -> Value {
        self.rerank.status(&mut self.runtime)
    }

    pub fn start_settled_rerank(&mut self) -> Value {
        self.rerank.start_settled(&mut self.runtime)
    }

    pub fn poll_settled_rerank(&mut self, token: u64, accept: bool) -> Value {
        self.rerank.poll_settled(&mut self.runtime, token, accept)
    }
}
