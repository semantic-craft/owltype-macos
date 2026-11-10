use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use msime_engine::CandidateSource;
use msime_input_runtime::{CandidateOps, CandidateTransform, TransformRow};

#[derive(Clone, Debug)]
pub(crate) struct PinnedWord {
    pub(crate) text: String,
    pub(crate) traditional_source: Option<String>,
}

impl PinnedWord {
    pub(crate) fn new(text: String, traditional: bool, traditional_source: Option<String>) -> Self {
        Self {
            text,
            traditional_source: traditional
                .then_some(traditional_source)
                .flatten()
                .filter(|source| !source.is_empty()),
        }
    }
}

#[derive(Default)]
pub(crate) struct OwlPinnedState {
    pub(crate) words: HashMap<(String, bool), Vec<PinnedWord>>,
    pub(crate) enabled: bool,
    pub(crate) traditional: bool,
    pub(crate) active_input: String,
    pub(crate) caret_at_end: bool,
    pub(crate) input_mode: String,
    pub(crate) pinyin_scheme: String,
    pub(crate) wubi_single_first: bool,
    pub(crate) page_size: usize,
    pub(crate) wubi_z_reverse_lookup: bool,
}

pub(crate) struct OwlPinnedTransform {
    pub(crate) state: Arc<Mutex<OwlPinnedState>>,
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
                for pin in pins {
                    if let Some(seat) =
                        pinned_candidate_seat(window, &target_norm, pin, guard.traditional)
                    {
                        let seat_u32 = seat as u32;
                        if !ops.order.contains(&seat_u32) {
                            ops.order.push(seat_u32);
                            ops.annotations.push((seat_u32, "置顶".to_owned()));
                        }
                    }
                }
            }
        }

        // 2. Wubi single-character-first mode (#250): place single-character candidates ahead of phrases
        //    (except during z-prefix reverse lookup), while preserving page 0's quick-phrase slots.
        let quick_phrase_src = CandidateSource::QuickPhrase as u8;
        let in_z_lookup = guard.input_mode == "wubi"
            && guard.pinyin_scheme != "wubi_pinyin"
            && guard.wubi_z_reverse_lookup
            && guard.active_input.starts_with('z');
        if guard.input_mode == "wubi" && guard.wubi_single_first && !in_z_lookup {
            let page_sz = guard.page_size.max(1);
            let page0_quick: Vec<usize> = window
                .iter()
                .take(page_sz)
                .enumerate()
                .filter(|(_, row)| row.source == quick_phrase_src)
                .map(|(seat, _)| seat)
                .collect();
            let mut non_quick_order = Vec::with_capacity(window.len());
            for (seat, row) in window.iter().enumerate() {
                if row.source != quick_phrase_src && row.text.chars().count() == 1 {
                    non_quick_order.push(seat);
                }
            }
            for (seat, row) in window.iter().enumerate() {
                if row.source != quick_phrase_src && row.text.chars().count() != 1 {
                    non_quick_order.push(seat);
                }
            }
            let mut non_quick_iter = non_quick_order.into_iter();
            let head_slots = page0_quick.first().copied().unwrap_or(page_sz);
            for _ in 0..head_slots {
                if let Some(seat) = non_quick_iter.next() {
                    push_unique(&mut ops.order, seat);
                }
            }
            for seat in page0_quick {
                push_unique(&mut ops.order, seat);
            }
            for seat in non_quick_iter {
                push_unique(&mut ops.order, seat);
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

pub(crate) fn pinned_candidate_seat(
    window: &[TransformRow<'_>],
    target_norm: &str,
    pin: &PinnedWord,
    traditional: bool,
) -> Option<usize> {
    let matching_code =
        |row: &TransformRow<'_>| row.code.is_empty() || normalized_pinyin(row.code) == target_norm;
    if let Some((seat, _)) = window
        .iter()
        .enumerate()
        .find(|(_, row)| matching_code(row) && row.text == pin.text)
    {
        return Some(seat);
    }
    if !traditional {
        return None;
    }

    // The host converts candidate text after this transform. It supplies the exact source row
    // only when converting that row back produces this pin, so a lossy inverse lookup such as
    // 髮 -> 发 -> 發 cannot silently pin the wrong word.
    let source = pin.traditional_source.as_deref()?;
    window
        .iter()
        .position(|row| matching_code(row) && row.text == source)
}
