#![allow(unsafe_code)]

mod app_rpc;
mod config;
mod input_ffi;
mod pinned_transform;
mod punctuation_menu;
mod rerank;
mod session_actions;
mod session_roots;
mod session_runtime;
mod sessions;
mod smart_punctuation;

#[cfg(test)]
mod ffi_tests_modes;
#[cfg(test)]
mod ffi_tests_rerank;
#[cfg(test)]
mod ffi_tests_roots;
#[cfg(test)]
mod ffi_tests_support;
#[cfg(test)]
mod ffi_tests_typing;

pub use app_rpc::*;
pub use input_ffi::*;
pub use session_runtime::{CandidateDto, OwlMsimeSession, SnapshotResponseDto};

impl OwlMsimeSession {
    pub(crate) fn apply_session_option(&mut self, name: &str, value: bool) -> Result<(), String> {
        match name {
            "quick_phrase_candidates" => {
                self.quick_phrase_candidates = value;
                self.apply_quick_phrase_preference_if_idle()?;
            }
            "ascii_punct" => {
                self.options.chinese_punctuation = !value;
                let _ = self.runtime.set_chinese_punctuation_enabled(!value);
            }
            "emoji" | "emoji_suggestion" => {
                self.runtime
                    .set_mixed_emoji_candidates(value)
                    .map_err(|error| error.to_string())?;
                self.options.mixed_emoji = value;
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
            "wubi_auto_commit_unique" => {
                self.runtime.set_wubi_auto_commit_unique(value);
            }
            "wubi_fifth_code_top_commit" => {
                self.runtime.set_wubi_fifth_code_top_commit(value);
            }
            "wubi_code_hint" => {
                self.wubi_code_hint = value;
            }
            "wubi_auto_clear" => {
                self.wubi_auto_clear = value;
            }
            "wubi_z_wildcard" => {
                if self.options.wubi_z_wildcard != value {
                    self.options.wubi_z_wildcard = value;
                    self.force_rebuild_engine()?;
                }
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
                    self.force_rebuild_engine()?;
                }
            }
            _ => {}
        }
        Ok(())
    }
}
