use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde_json::json;
use tempfile::TempDir;

use crate::ffi_tests_support::*;
use crate::pinned_transform::{pinned_candidate_seat, PinnedWord};
use crate::session_roots::product_engine_options;
use crate::sessions::with_session;
use crate::*;

#[test]
fn traditional_pin_uses_only_host_verified_display_sources() {
    let source = PinnedWord::new("發".to_owned(), true, Some("发".to_owned()));
    let simplified = [transform_row("罚", "fa"), transform_row("发", "fa")];
    assert_eq!(
        pinned_candidate_seat(&simplified, "fa", &source, true),
        Some(1)
    );
    assert_eq!(
        pinned_candidate_seat(&simplified, "fa", &source, false),
        None,
        "traditional fallback must not leak into simplified mode"
    );

    let lossy = PinnedWord::new("髮".to_owned(), true, None);
    let simplified_only = [transform_row("发", "fa")];
    assert_eq!(
        pinned_candidate_seat(&simplified_only, "fa", &lossy, true),
        None,
        "a unique Simplified source does not prove that it displays the pinned word"
    );

    let exact = PinnedWord::new("髮".to_owned(), true, None);
    let raw_traditional = [transform_row("发", "fa"), transform_row("髮", "fa")];
    assert_eq!(
        pinned_candidate_seat(&raw_traditional, "fa", &exact, true),
        Some(1),
        "an exact candidate must win before a host source"
    );

    let phrase = PinnedWord::new("頭髮".to_owned(), true, Some("头发".to_owned()));
    let phrase_row = [transform_row("头发", "toufa")];
    assert_eq!(
        pinned_candidate_seat(&phrase_row, "toufa", &phrase, true),
        Some(0)
    );
}

#[test]
fn product_options_enable_builtin_local_features() {
    let options = product_engine_options(
        Path::new("/resources"),
        Path::new("/user"),
        Path::new("/cache"),
        Path::new("/dictionaries"),
        5,
    );
    assert!(options.local_unicode);
    assert!(options.local_date_time);
    assert!(options.local_date_time_inline);
    assert!(options.local_date_time_menu);
    assert!(!options.local_expression);
    assert!(options.mixed_emoji);
    assert!(options.mixed_symbols);
    assert!(options.local_emoji);
    assert!(options.local_kaomoji);
    assert!(options.local_symbol);
}

#[test]
fn candidate_emoji_option_refreshes_the_live_composition_only() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    build_minimal_test_others_db(&resources);
    let (session, error) = create_with_explicit_roots(
        &resources.join(msime_engine::assets::MAIN_DICTIONARY),
        &resources,
        &tmp.path().join("user"),
        &tmp.path().join("cache"),
        &tmp.path().join("dictionaries"),
    );
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());

    call_action(
        session,
        r#"{"op":"set_option","name":"emoji","value":false}"#,
    );
    for ch in ['p', 'i', 'n', 'g'] {
        let frame = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(frame.ok);
    }
    let initial = call_snapshot(session);
    assert!(!initial.candidates.iter().any(|row| row.text == "🍎"));
    let options = session_options(session);
    assert!(!options.mixed_emoji);
    assert!(options.local_emoji);

    let enabled = call_action(
        session,
        r#"{"op":"set_option","name":"emoji","value":true}"#,
    );
    assert!(enabled.candidates.iter().any(|row| row.text == "🍎"));
    assert_eq!(enabled.local_mode, "none");
    let options = session_options(session);
    assert!(options.mixed_emoji);
    assert!(options.local_emoji);

    let repeated = call_action(
        session,
        r#"{"op":"set_option","name":"emoji","value":true}"#,
    );
    assert_eq!(repeated.generation, enabled.generation);
    assert!(repeated.candidates.iter().any(|row| row.text == "🍎"));

    let disabled_by_alias = call_action(
        session,
        r#"{"op":"set_option","name":"emoji_suggestion","value":false}"#,
    );
    assert!(!disabled_by_alias
        .candidates
        .iter()
        .any(|row| row.text == "🍎"));
    let options = session_options(session);
    assert!(!options.mixed_emoji);
    assert!(options.local_emoji);

    let enabled_by_alias = call_action(
        session,
        r#"{"op":"set_option","name":"emoji_suggestion","value":true}"#,
    );
    assert!(enabled_by_alias
        .candidates
        .iter()
        .any(|row| row.text == "🍎"));
    let options = session_options(session);
    assert!(options.mixed_emoji);
    assert!(options.local_emoji);

    owl_msime_session_destroy(session);
}

#[test]
fn production_seed_delivers_emoji_rows_through_ffi() {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let resources = repository.join("data/owl-rime/msime");
    let pinyin = resources.join(msime_engine::assets::MAIN_DICTIONARY);
    if !pinyin.is_file() {
        return;
    }
    let others = resources.join(msime_engine::assets::OTHER_DICTIONARY);
    assert!(
        others.is_file(),
        "missing production emoji catalog at {}; run make owl-seed",
        others.display()
    );

    let tmp = TempDir::new().unwrap();
    let (session, error) = create_with_explicit_roots(
        &pinyin,
        &resources,
        &tmp.path().join("user"),
        &tmp.path().join("cache"),
        &tmp.path().join("dictionaries"),
    );
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());
    let enabled = call_action(
        session,
        r#"{"op":"set_option","name":"emoji","value":true}"#,
    );
    assert!(enabled.ok, "{:?}", enabled.error);

    for ch in "pingguo".chars() {
        let frame = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(frame.ok, "{:?}", frame.error);
    }
    let apple = candidate_texts_across_pages(session);
    assert!(apple.iter().any(|text| text == "🍎"), "{apple:?}");
    assert!(apple.iter().any(|text| text == "🍏"), "{apple:?}");

    call_action(session, r#"{"op":"clear"}"#);
    for ch in "ping".chars() {
        let frame = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(frame.ok, "{:?}", frame.error);
    }
    let ping = candidate_texts_across_pages(session);
    assert!(ping.iter().any(|text| text == "🏓"), "{ping:?}");

    owl_msime_session_destroy(session);
}

#[test]
fn explicit_roots_keep_session_runtime_separate_from_the_shared_user_journal() {
    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);
    let user = tmp.path().join("persistent-user");
    fs::create_dir_all(&user).unwrap();
    let journal = user.join(msime_engine::assets::USER_JOURNAL);
    Connection::open(&journal)
        .unwrap()
        .execute_batch(
            "CREATE TABLE candidate_selection_state(
                 context_key TEXT NOT NULL,
                 entry_key TEXT NOT NULL,
                 value TEXT NOT NULL,
                 selection_count INTEGER NOT NULL DEFAULT 0,
                 PRIMARY KEY(context_key,entry_key,value)
             );
             INSERT INTO candidate_selection_state
                 (context_key,entry_key,value,selection_count)
             VALUES ('codex-boundary','ni','你',7);",
        )
        .unwrap();

    let runtime_a = tmp.path().join("runtime-a");
    let runtime_b = tmp.path().join("runtime-b");
    let resources_a = runtime_a.join("resources");
    let cache_a = runtime_a.join("cache");
    let dictionaries_a = runtime_a.join("dictionaries");
    let resources_b = runtime_b.join("resources");
    let cache_b = runtime_b.join("cache");
    let dictionaries_b = runtime_b.join("dictionaries");

    let (session_a, error_a) =
        create_with_explicit_roots(&pinyin, &resources_a, &user, &cache_a, &dictionaries_a);
    assert!(error_a.is_none(), "{error_a:?}");
    assert!(!session_a.is_null());
    let (session_b, error_b) =
        create_with_explicit_roots(&pinyin, &resources_b, &user, &cache_b, &dictionaries_b);
    assert!(error_b.is_none(), "{error_b:?}");
    assert!(!session_b.is_null());

    let options_a = session_options(session_a);
    let options_b = session_options(session_b);
    assert_eq!(
        Path::new(&options_a.resources),
        fs::canonicalize(&resources_a).unwrap()
    );
    assert_eq!(
        Path::new(&options_a.cache),
        fs::canonicalize(&cache_a).unwrap()
    );
    assert_eq!(
        Path::new(&options_a.dictionaries),
        fs::canonicalize(&dictionaries_a).unwrap()
    );
    assert_eq!(
        Path::new(&options_b.resources),
        fs::canonicalize(&resources_b).unwrap()
    );
    assert_eq!(
        Path::new(&options_a.user_data),
        Path::new(&options_b.user_data)
    );
    assert_ne!(options_a.resources, options_b.resources);
    assert_ne!(options_a.cache, options_b.cache);
    assert_ne!(options_a.dictionaries, options_b.dictionaries);
    assert!(!resources_a.join("msime-resources").exists());
    assert!(!user.join("msime-user").exists());
    assert!(dictionaries_a.join("msime-pinyin.db").is_file());
    assert!(dictionaries_a.join("msime-english.db").is_file());
    assert_eq!(assertion_journal_count(&journal), 7);

    for session in [session_a, session_b] {
        for ch in ['n', 'i'] {
            let typed = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
            assert!(typed.ok);
        }
        assert!(call_snapshot(session)
            .candidates
            .iter()
            .any(|candidate| candidate.text == "你"));
    }

    owl_msime_session_destroy(session_a);
    fs::remove_dir_all(&runtime_a).unwrap();
    assert!(journal.is_file());
    assert_eq!(assertion_journal_count(&journal), 7);

    owl_msime_session_destroy(session_b);
    fs::remove_dir_all(&runtime_b).unwrap();
    assert!(journal.is_file());
    assert_eq!(assertion_journal_count(&journal), 7);

    let runtime_c = tmp.path().join("runtime-c");
    let (reopened, error_c) = create_with_explicit_roots(
        &pinyin,
        &runtime_c.join("resources"),
        &user,
        &runtime_c.join("cache"),
        &runtime_c.join("dictionaries"),
    );
    assert!(error_c.is_none(), "{error_c:?}");
    assert!(!reopened.is_null());
    assert_eq!(assertion_journal_count(&journal), 7);
    for ch in ['n', 'i'] {
        let typed = call_action(reopened, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        assert!(typed.ok);
    }
    assert!(call_snapshot(reopened)
        .candidates
        .iter()
        .any(|candidate| candidate.text == "你"));
    owl_msime_session_destroy(reopened);
}

#[test]
fn missing_rerank_model_degrades_without_blocking_input() {
    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);
    Connection::open(&pinyin)
        .unwrap()
        .execute("DELETE FROM tbl_2_n", [])
        .unwrap();
    let resources = tmp.path().join("resources");
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let dictionaries = tmp.path().join("dictionaries");
    let (session, error) =
        create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());

    let missing = tmp.path().join("missing.safetensors");
    let config = json!({
        "keyboard": {
            "enabled": true,
            "path": missing.to_string_lossy(),
            "source": "test",
            "version": "1"
        },
        "settled": {"enabled": false}
    });
    let configured = configure_rerank(session, &config.to_string());
    // The worker can finish before configure returns its status snapshot.
    assert!(matches!(
        configured["keyboard"]["state"].as_str(),
        Some("loading" | "missing")
    ));
    let status = wait_for_rerank_state(session, "keyboard", "missing");
    assert_eq!(status["keyboard"]["enabled"], true);
    assert!(status["keyboard"]["error"].is_string());

    let frame = call_action(session, r#"{"op":"insert","ch":"n"}"#);
    assert!(frame.ok);
    assert_eq!(frame.raw_input, "n");
    owl_msime_session_destroy(session);
}

#[test]
fn shipped_models_rerank_settled_candidates_and_preserve_visible_selection() {
    let Some(directory) = std::env::var_os("MSIME_NEURAL_MODEL_DIR").map(PathBuf::from) else {
        eprintln!("skipping: MSIME_NEURAL_MODEL_DIR is not set");
        return;
    };
    let keyboard = directory.join("sentence-model.safetensors");
    let desktop = directory.join("sentence-model-desktop.safetensors");
    if !keyboard.is_file() || !desktop.is_file() {
        eprintln!("skipping: shipped sentence models are absent from {directory:?}");
        return;
    }

    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);
    Connection::open(&pinyin)
        .unwrap()
        .execute("DELETE FROM tbl_2_n", [])
        .unwrap();
    let resources = tmp.path().join("resources");
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let dictionaries = tmp.path().join("dictionaries");
    let (session, error) =
        create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());

    let config = json!({
        "keyboard": {
            "enabled": true,
            "path": keyboard.to_string_lossy(),
            "source": "metasequoiaime/chinese-ime-lm",
            "version": "model-v1",
            "expected_sha256": "86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1"
        },
        "settled": {
            "enabled": true,
            "path": desktop.to_string_lossy(),
            "source": "metasequoiaime/chinese-ime-lm",
            "version": "model-v1",
            "expected_sha256": "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469"
        }
    });
    let _ = configure_rerank(session, &config.to_string());
    wait_for_rerank_state(session, "keyboard", "ready");
    let status = wait_for_rerank_state(session, "settled", "ready");
    assert_eq!(status["keyboard"]["license"], "Apache-2.0");
    assert_eq!(status["settled"]["attached"], true);
    assert!(status["settled"]["attribution"]
        .as_str()
        .is_some_and(|value| value.contains("LCCC")));

    for ch in ["n", "i", "h", "a", "o"] {
        let frame = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(frame.ok);
    }
    let _ = call_action(session, r#"{"op":"move_highlight","delta":1}"#);
    let before = call_snapshot(session);
    assert!(!before.candidates.is_empty());
    let highlighted_text = before.candidates[before.highlighted_index].text.clone();
    let started = start_settled_rerank(session);
    assert_eq!(started["status"], "pending", "{started}");
    let token = started["token"].as_u64().unwrap();
    let duplicate = start_settled_rerank(session);
    assert_eq!(duplicate["token"], token);
    let applied = wait_for_settled_job(session, token, true);
    assert_eq!(applied["current"], true);
    let after = call_snapshot(session);
    assert_eq!(
        after.candidates[after.highlighted_index].text, highlighted_text,
        "settled rerank must preserve the highlighted candidate identity"
    );

    let full_index = after
        .candidates
        .iter()
        .position(|candidate| candidate.input_len == after.raw_input.len())
        .unwrap_or_else(|| panic!("no full-coverage candidate in {after:?}"));
    let selected_text = after.candidates[full_index].text.clone();
    let selected = call_action(
        session,
        &format!(r#"{{"op":"select_visible","index":{full_index}}}"#),
    );
    assert_eq!(
        selected.committed_text.as_deref(),
        Some(selected_text.as_str())
    );

    for ch in ["n", "i", "h", "a", "o"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let tokenized = call_snapshot(session);
    let full_index = tokenized
        .candidates
        .iter()
        .position(|candidate| candidate.input_len == tokenized.raw_input.len())
        .unwrap_or_else(|| panic!("no full-coverage candidate in {tokenized:?}"));
    let selected_text = tokenized.candidates[full_index].text.clone();
    let selected = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":{full_index},"generation":{},"is_absolute":false}}"#,
            tokenized.generation
        ),
    );
    assert_eq!(
        selected.committed_text.as_deref(),
        Some(selected_text.as_str())
    );
    owl_msime_session_destroy(session);
}

#[test]
fn stale_settled_result_is_discarded_and_its_model_is_reused() {
    let Some(directory) = std::env::var_os("MSIME_NEURAL_MODEL_DIR").map(PathBuf::from) else {
        eprintln!("skipping: MSIME_NEURAL_MODEL_DIR is not set");
        return;
    };
    let desktop = directory.join("sentence-model-desktop.safetensors");
    if !desktop.is_file() {
        eprintln!("skipping: desktop sentence model is absent from {directory:?}");
        return;
    }

    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);
    Connection::open(&pinyin)
        .unwrap()
        .execute("DELETE FROM tbl_2_n", [])
        .unwrap();
    let resources = tmp.path().join("resources");
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let dictionaries = tmp.path().join("dictionaries");
    let (session, error) =
        create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());
    let config = json!({
        "keyboard": {"enabled": false},
        "settled": {
            "enabled": true,
            "path": desktop.to_string_lossy(),
            "expected_sha256": "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469"
        }
    });
    let _ = configure_rerank(session, &config.to_string());
    wait_for_rerank_state(session, "settled", "ready");

    for ch in ["n", "i", "h", "a", "o"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let started = start_settled_rerank(session);
    assert_eq!(started["status"], "pending", "{started}");
    let token = started["token"].as_u64().unwrap();
    assert!(
        call_action(session, r#"{"op":"insert","ch":"a"}"#).ok,
        "input must continue while settled scoring is running"
    );
    let stale = wait_for_settled_job(session, token, false);
    assert_eq!(stale["current"], false);
    assert_eq!(call_snapshot(session).raw_input, "nihaoa");

    // The discarded result returns its model to the runtime: a later pause can rank again.
    let _ = call_action(session, r#"{"op":"clear"}"#);
    for ch in ["n", "i", "h", "a", "o"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let restarted = start_settled_rerank(session);
    assert_eq!(restarted["status"], "pending", "{restarted}");
    let token = restarted["token"].as_u64().unwrap();
    let done = wait_for_settled_job(session, token, false);
    assert_eq!(done["current"], false);
    owl_msime_session_destroy(session);
}

#[test]
fn settled_rerank_without_model_work_completes_without_a_stale_job() {
    let Some(directory) = std::env::var_os("MSIME_NEURAL_MODEL_DIR").map(PathBuf::from) else {
        eprintln!("skipping: MSIME_NEURAL_MODEL_DIR is not set");
        return;
    };
    let desktop = directory.join("sentence-model-desktop.safetensors");
    if !desktop.is_file() {
        eprintln!("skipping: desktop sentence model is absent from {directory:?}");
        return;
    }

    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);
    let resources = tmp.path().join("resources");
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let dictionaries = tmp.path().join("dictionaries");
    let (session, error) =
        create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());
    let config = json!({
        "keyboard": {"enabled": false},
        "settled": {
            "enabled": true,
            "path": desktop.to_string_lossy(),
            "expected_sha256": "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469"
        }
    });
    let _ = configure_rerank(session, &config.to_string());
    wait_for_rerank_state(session, "settled", "ready");

    // A trusted dictionary leader needs no neural comparison. Put the pin in place before
    // typing so the composition carries candidate operations that the settled presentation
    // pass can replay after the host removes the pin.
    assert!(call_action(session, r#"{"op":"set_pinned_words","text":"ni\t0\t尼"}"#).ok);
    for ch in ["n", "i"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let before = call_snapshot(session);
    assert_eq!(before.candidates[0].text, "尼");
    assert!(call_action(session, r#"{"op":"set_pinned_words","text":""}"#).ok);
    let started = start_settled_rerank(session);
    assert_eq!(started["status"], "done", "{started}");
    assert_eq!(started["current"], true);
    assert_eq!(started["moved"], false);
    assert_eq!(call_snapshot(session).candidates[0].text, "尼");
    owl_msime_session_destroy(session);
}

#[test]
fn settled_model_is_reattached_after_worker_launch_failure() {
    let Some(directory) = std::env::var_os("MSIME_NEURAL_MODEL_DIR").map(PathBuf::from) else {
        eprintln!("skipping: MSIME_NEURAL_MODEL_DIR is not set");
        return;
    };
    let desktop = directory.join("sentence-model-desktop.safetensors");
    if !desktop.is_file() {
        eprintln!("skipping: desktop sentence model is absent from {directory:?}");
        return;
    }

    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);
    Connection::open(&pinyin)
        .unwrap()
        .execute("DELETE FROM tbl_2_n", [])
        .unwrap();
    let resources = tmp.path().join("resources");
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let dictionaries = tmp.path().join("dictionaries");
    let (session, error) =
        create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());
    let config = json!({
        "keyboard": {"enabled": false},
        "settled": {
            "enabled": true,
            "path": desktop.to_string_lossy(),
            "expected_sha256": "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469"
        }
    });
    let _ = configure_rerank(session, &config.to_string());
    wait_for_rerank_state(session, "settled", "ready");

    // Simulate begin_settled_rerank taking the model while worker creation then fails.
    with_session(session, |session| {
        session.runtime.set_settled_reranker(None);
        session
            .rerank
            .recover_settled_worker_failure(&mut session.runtime);
    })
    .unwrap();
    assert_eq!(rerank_status(session)["settled"]["attached"], true);

    for ch in ["n", "i", "h", "a", "o"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let started = start_settled_rerank(session);
    assert_eq!(started["status"], "pending", "{started}");
    let token = started["token"].as_u64().unwrap();
    let discarded = wait_for_settled_job(session, token, false);
    assert_eq!(discarded["current"], false);
    owl_msime_session_destroy(session);
}
