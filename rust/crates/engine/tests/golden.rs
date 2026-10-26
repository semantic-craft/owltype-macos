//! Golden differential tests: replay the scenarios and real-dictionary sets recorded from the C++ reference engine (`tools/engine-golden/README.md`) against the public API and fail with a per-step diff.
//!
//! `MSIME_GOLDEN_SCENARIO=<name>[,<name>...]` limits the scripted run to those scenarios. The real sets need the `dict-v2.0.1` resource directory in `MSIME_EVAL_RESOURCES` and are skipped, with the reason printed, without it.

mod golden_support;

use std::sync::{Mutex, MutexGuard};

use golden_support::{real, replay};

/// The engine's journal cache and personal n-gram store are process-wide and every replay closes them when it ends, so the tests that drive a session take turns, as the recorder ran one scenario per process.
static ENGINE: Mutex<()> = Mutex::new(());

/// A test that failed while holding the lock must not turn the next one into a lock error.
fn engine_lock() -> MutexGuard<'static, ()> {
    ENGINE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[test]
fn scripted_scenarios_match_the_reference() {
    let _engine = engine_lock();
    replay::assert_scenarios(&replay::selected_scenarios());
}

#[test]
fn real_sentences_v1_match_the_reference() {
    let _engine = engine_lock();
    real::assert_real_set("sentences-v1.jsonl");
}

#[test]
fn real_sentences_neutral_v1_match_the_reference() {
    let _engine = engine_lock();
    real::assert_real_set("sentences-neutral-v1.jsonl");
}

#[test]
fn real_sentences_v2_match_the_reference() {
    let _engine = engine_lock();
    real::assert_real_set("sentences-v2.jsonl");
}

#[test]
fn real_quanpin_words_subset_matches_the_reference() {
    let _engine = engine_lock();
    real::assert_real_set("quanpin-words-v1.subset3000.jsonl");
}
