use std::collections::HashSet;
use std::fs;
use std::path::Path;

use msime_engine::ensure_english_schema;
use rusqlite::Connection;
use tempfile::TempDir;

use crate::ffi_tests_support::*;
use crate::sessions::with_session;
use crate::*;

#[test]
fn explicit_roots_reject_overlap_and_report_creation_errors() {
    let tmp = TempDir::new().unwrap();
    let pinyin = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&pinyin);

    let future_user = tmp.path().join("future-user");
    let before = directory_tree(tmp.path());
    let (session, error) = create_with_explicit_roots(
        &pinyin,
        &tmp.path().join("future-runtime/resources"),
        &future_user,
        &future_user.join("cache"),
        &tmp.path().join("future-runtime/dictionaries"),
    );
    assert!(session.is_null());
    assert!(error
        .as_deref()
        .is_some_and(|message| message.contains("session roots overlap")));
    assert_eq!(
        directory_tree(tmp.path()),
        before,
        "a future nested root must be rejected before creating any directory"
    );

    let existing_user = tmp.path().join("existing-user");
    fs::create_dir_all(&existing_user).unwrap();
    fs::write(existing_user.join("sentinel.txt"), b"keep").unwrap();
    let before = directory_tree(tmp.path());
    let (session, error) = create_with_explicit_roots(
        &pinyin,
        &tmp.path().join("existing-runtime/resources"),
        &existing_user,
        &existing_user.join("cache"),
        &tmp.path().join("existing-runtime/dictionaries"),
    );
    assert!(session.is_null());
    assert!(error
        .as_deref()
        .is_some_and(|message| message.contains("session roots overlap")));
    assert_eq!(
        directory_tree(tmp.path()),
        before,
        "an existing user tree must be unchanged when the requested cache root is nested"
    );

    let missing_pinyin = tmp.path().join("missing-pinyin.db");
    let (session, error) = create_with_explicit_roots(
        &missing_pinyin,
        &tmp.path().join("resources-2"),
        &tmp.path().join("user-2"),
        &tmp.path().join("cache-2"),
        &tmp.path().join("dictionaries-2"),
    );
    assert!(session.is_null());
    assert!(error
        .as_deref()
        .is_some_and(|message| message.contains("pinyin_db_path")));
}

#[cfg(unix)]
#[test]
fn explicit_roots_reject_redirected_directories_before_creation() {
    use std::os::unix::fs::symlink;

    for redirected in ["resources", "user", "cache", "dictionaries"] {
        let tmp = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        let pinyin = tmp.path().join("test-pinyin.db");
        build_minimal_test_pinyin_db(&pinyin);
        let linked = tmp.path().join(redirected);
        symlink(outside.path(), &linked).unwrap();

        let root = |name: &str| {
            if name == redirected {
                linked.clone()
            } else {
                tmp.path().join(name)
            }
        };
        let (session, error) = create_with_explicit_roots(
            &pinyin,
            &root("resources"),
            &root("user"),
            &root("cache"),
            &root("dictionaries"),
        );
        assert!(session.is_null(), "{redirected}");
        assert!(
            error
                .as_deref()
                .is_some_and(|message| message.contains("symbolic-link ancestor")),
            "{redirected}: {error:?}"
        );
        assert_eq!(
            fs::read_dir(outside.path()).unwrap().count(),
            0,
            "{redirected} must be rejected without writing through the link"
        );
    }
}

#[test]
fn upstream_generation_matches_explicit_roots_and_keeps_product_defaults() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    Connection::open(resources.join(msime_engine::assets::MAIN_DICTIONARY))
        .unwrap()
        .execute(
            "INSERT INTO quick_parases VALUES ('ni', '基础短语', 1000000)",
            [],
        )
        .unwrap();
    let resources_before = file_contents(&resources);

    let (explicit, explicit_error) = create_with_explicit_roots(
        &resources.join(msime_engine::assets::MAIN_DICTIONARY),
        &resources,
        &tmp.path().join("explicit-user"),
        &tmp.path().join("explicit-cache"),
        &tmp.path().join("explicit-dictionaries"),
    );
    assert!(explicit_error.is_none(), "{explicit_error:?}");
    assert!(!explicit.is_null());

    let user = tmp.path().join("msime-user");
    let cache = tmp.path().join("msime-cache");
    let (generated, generated_error) =
        create_with_generation(&resources, &user, &cache, "seed-fixture");
    assert!(generated_error.is_none(), "{generated_error:?}");
    assert!(!generated.is_null());
    assert!(user
        .join("dictionaries/seed-fixture")
        .join(msime_engine::assets::GENERATION_READY)
        .is_file());

    let options = session_options(generated);
    assert!(options.learning);
    assert!(options.autocorrect_transposition);
    assert!(options.autocorrect_neighbor);
    assert!(options.mixed_english);
    assert_eq!(options.english_minimum_prefix, 5);
    assert_eq!(options.english_first_page_count, 1);
    assert_eq!(options.first_page_rows, 5);
    assert!(!options.helpcode);

    let mut frames = Vec::new();
    for session in [explicit, generated] {
        for ch in ['n', 'i'] {
            call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
        }
        frames.push(call_snapshot(session));
    }
    assert_eq!(frames[0].raw_input, frames[1].raw_input);
    assert_eq!(frames[0].preedit, frames[1].preedit);
    assert_eq!(
        frames[0]
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>(),
        frames[1]
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>()
    );
    assert_eq!(frames[0].candidates[0].text, "你");
    assert!(
        !options.quick_phrase_candidates,
        "native fresh preferences disable ordinary quick phrases"
    );
    for (index, session) in [explicit, generated].into_iter().enumerate() {
        assert!(!frames[index]
            .candidates
            .iter()
            .any(|candidate| candidate.text == "基础短语"));
        let previous_generation = frames[index].generation;
        let enabled = call_action(
            session,
            r#"{"op":"set_option","name":"quick_phrase_candidates","value":true}"#,
        );
        assert!(enabled.ok);
        let pending = call_snapshot(session);
        assert_eq!(
            pending.raw_input, "ni",
            "queued preferences preserve composition"
        );
        assert_eq!(pending.generation, previous_generation);
        assert!(!pending
            .candidates
            .iter()
            .any(|candidate| candidate.text == "基础短语"));
        call_action(session, r#"{"op":"clear"}"#);
        call_action(session, r#"{"op":"insert","ch":"n"}"#);
        call_action(session, r#"{"op":"insert","ch":"i"}"#);
        frames[index] = call_snapshot(session);
        assert!(frames[index].generation > previous_generation);
    }
    assert!(frames[0]
        .candidates
        .iter()
        .any(|candidate| candidate.text == "基础短语"));

    call_action(generated, r#"{"op":"clear"}"#);
    let host = call_action(
        generated,
        r#"{"op":"set_host_phrases","text":"主机短语\tni"}"#,
    );
    assert!(host.ok);
    call_action(generated, r#"{"op":"insert","ch":"n"}"#);
    call_action(generated, r#"{"op":"insert","ch":"i"}"#);
    let ordinary = candidate_texts_across_pages(generated);
    assert!(
        !ordinary.iter().any(|text| text == "主机短语"),
        "Owl host enhancements require explicit K mode"
    );
    assert!(
        ordinary.iter().any(|text| text == "基础短语"),
        "native database quick phrases remain in ordinary macOS candidates"
    );
    call_action(generated, r#"{"op":"clear"}"#);
    for ch in ['K', 'n'] {
        call_action(generated, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
    }
    let prefix_candidates = candidate_texts_across_pages(generated);
    assert!(
        prefix_candidates.iter().any(|text| text == "基础短语"),
        "native database K prefix browsing is preserved"
    );
    assert!(
        !prefix_candidates.iter().any(|text| text == "主机短语"),
        "Owl invocations require the complete stored trigger even in explicit K mode"
    );
    call_action(generated, r#"{"op":"clear"}"#);
    for ch in ['K', 'n', 'i'] {
        call_action(generated, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
    }
    assert!(
        call_snapshot(generated)
            .candidates
            .iter()
            .any(|row| row.text == "主机短语"),
        "explicit K mode retains the host phrase table"
    );
    assert_eq!(file_contents(&resources), resources_before);

    owl_msime_session_destroy(explicit);
    owl_msime_session_destroy(generated);
}

#[test]
fn raw_commit_suppresses_a_production_autocorrect_candidate() {
    let tmp = TempDir::new().unwrap();
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let pinyin = repository.join("data/owl-rime/msime/msime-pinyin.db");
    assert!(
        pinyin.is_file(),
        "missing production seed at {}",
        pinyin.display()
    );
    let resources = tmp.path().join("resources");
    fs::create_dir_all(&resources).unwrap();
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let dictionaries = tmp.path().join("dictionaries");
    let (session, error) =
        create_with_explicit_roots(&pinyin, &resources, &user, &cache, &dictionaries);
    assert!(session.is_null() || error.is_none(), "{error:?}");
    assert!(!session.is_null());

    for ch in ['n', 'i', 'h', 's', 'o'] {
        let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(response.ok, "{:?}", response.error);
    }
    let initial = with_session(session, |session| session.runtime.all_candidates()).unwrap();
    let initial_rows = initial
        .candidates
        .iter()
        .filter(|candidate| candidate.text == "你好")
        .collect::<Vec<_>>();
    assert_eq!(initial_rows.len(), 1);
    assert!(initial_rows[0].corrected);
    assert_eq!(initial_rows[0].annotation, "nihso");
    let raw = call_action(session, r#"{"op":"commit_raw"}"#);
    assert_eq!(raw.committed_text.as_deref(), Some("nihso"));

    let journal = user.join(msime_engine::assets::USER_JOURNAL);
    let suppressions: Vec<String> = Connection::open(&journal)
        .unwrap()
        .prepare("SELECT input FROM pinyin_autocorrect_suppressions ORDER BY input")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(suppressions, vec!["nihso"]);

    for ch in ['n', 'i', 'h', 's', 'o'] {
        let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(response.ok, "{:?}", response.error);
    }
    let repeated = with_session(session, |session| session.runtime.all_candidates()).unwrap();
    let repeated_rows = repeated
        .candidates
        .iter()
        .filter(|candidate| candidate.text == "你好")
        .collect::<Vec<_>>();
    assert_eq!(repeated_rows.len(), 1);
    assert!(!repeated_rows[0].corrected);
    assert!(repeated_rows[0].annotation.is_empty());
    owl_msime_session_destroy(session);
}

#[test]
fn wubi_learning_default_persists_native_selection() {
    let tmp = TempDir::new().unwrap();
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../data/owl-rime/msime");
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    for learned in [false, true] {
        let (session, error) =
            create_with_generation(&resources, &user, &cache, "wubi-learning");
        assert!(error.is_none(), "{error:?}");
        assert!(!session.is_null());
        assert!(call_action(session, r#"{"op":"set_input_mode","mode":"wubi"}"#).ok);
        assert!(call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"wubi"}"#).ok);
        for ch in ['g', 'g', 'g', 'g'] {
            assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
        }
        let frame = call_snapshot(session);
        // Native Host API defaults: the second row moves first after one selection.
        assert_eq!(
            frame.candidates[0].text,
            if learned { "五一" } else { "王" }
        );
        if !learned {
            let selected = call_action(session, r#"{"op":"select_visible","index":1}"#);
            assert_eq!(selected.committed_text.as_deref(), Some("五一"));
            assert!(
                call_action(
                    session,
                    r#"{"op":"set_pinyin_scheme","scheme":"wubi_pinyin"}"#
                )
                .ok
            );
            for ch in ['n', 'i', 'n'] {
                assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
            }
            let next = call_snapshot(session);
            assert_eq!(
                next.candidates[0].text, "恍悟",
                "Native mixed query after the learned Wubi selection"
            );
        }
        owl_msime_session_destroy(session);
    }
}

#[test]
fn pure_wubi_fifth_key_tops_an_ambiguous_four_code() {
    let tmp = TempDir::new().unwrap();
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let resources = repository.join("data/owl-rime/msime");
    assert!(
        resources
            .join(msime_engine::assets::WUBI_DICTIONARY)
            .is_file(),
        "missing official split Wubi seed at {}",
        resources.display()
    );
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    // Use production generation preparation, which assembles the official split tables.
    let (session, error) = create_with_generation(&resources, &user, &cache, "wubi-fifth");
    assert!(session.is_null() || error.is_none(), "{error:?}");
    assert!(!session.is_null());

    let wubi_mode = call_action(session, r#"{"op":"set_input_mode","mode":"wubi"}"#);
    assert!(wubi_mode.ok, "{:?}", wubi_mode.error);
    let wubi_scheme = call_action(session, r#"{"op":"set_pinyin_scheme","scheme":"wubi"}"#);
    assert!(wubi_scheme.ok, "{:?}", wubi_scheme.error);

    for ch in ['a', 'a', 'a', 'a'] {
        let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(response.ok, "{:?}", response.error);
    }
    let before = call_snapshot(session);
    assert_eq!(before.committed_text, None);
    assert_eq!(before.raw_input, "aaaa");
    assert_eq!(
        before
            .candidates
            .first()
            .map(|candidate| candidate.text.as_str()),
        Some("工")
    );

    let topped = call_action(session, r#"{"op":"insert","ch":"x"}"#);
    assert!(topped.ok, "{:?}", topped.error);
    assert_eq!(topped.committed_text.as_deref(), Some("工"));
    assert_eq!(topped.raw_input, "x");
    assert_eq!(topped.preedit, "x");
    owl_msime_session_destroy(session);
}

#[test]
fn destroyed_handle_cannot_alias_a_reopened_session() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    let user = tmp.path().join("user");
    let cache = tmp.path().join("cache");
    let mut retired = HashSet::new();
    for _ in 0..32 {
        let (session, error) = create_with_generation(&resources, &user, &cache, "aba");
        assert!(error.is_none(), "{error:?}");
        assert!(!session.is_null());
        for stale in retired.iter().copied() {
            let stale = stale as *mut OwlMsimeSession;
            owl_msime_session_destroy(stale);
            assert!(!call_action(stale, r#"{"op":"insert","ch":"h"}"#).ok);
            assert!(!call_snapshot(stale).ok);
        }
        assert!(
            call_action(session, r#"{"op":"insert","ch":"n"}"#).ok,
            "stale handles must not destroy or mutate the reopened session"
        );
        assert_eq!(call_snapshot(session).raw_input, "n");
        retired.insert(session as usize);
        owl_msime_session_destroy(session);
    }
}

#[test]
fn session_rejects_foreign_thread_calls_and_destroy() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    let (session, error) = create_with_generation(
        &resources,
        &tmp.path().join("user"),
        &tmp.path().join("cache"),
        "thread-confined",
    );
    assert!(error.is_none(), "{error:?}");
    assert!(!session.is_null());
    let handle = session as usize;
    std::thread::spawn(move || {
        let session = handle as *mut OwlMsimeSession;
        assert!(!call_action(session, r#"{"op":"insert","ch":"h"}"#).ok);
        assert!(!call_snapshot(session).ok);
        owl_msime_session_destroy(session);
    })
    .join()
    .unwrap();
    assert!(call_action(session, r#"{"op":"insert","ch":"n"}"#).ok);
    assert_eq!(call_snapshot(session).raw_input, "n");
    owl_msime_session_destroy(session);
}

#[test]
fn removal_uses_current_visible_identity_and_survives_reopen() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    let user = tmp.path().join("msime-user");
    let cache = tmp.path().join("msime-cache");
    let (session, error) = create_with_generation(&resources, &user, &cache, "removal");
    assert!(error.is_none(), "{error:?}");
    for ch in ['n', 'i', 'h', 'a', 'o'] {
        call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    let before = call_snapshot(session);
    let index = before
        .candidates
        .iter()
        .position(|c| c.text == "你号")
        .unwrap();
    let generation = before.generation;
    let stale = call_action(
        session,
        &format!(
            r#"{{"op":"remove_token","index":{index},"generation":{}}}"#,
            generation.wrapping_add(1)
        ),
    );
    assert!(!stale.consumed);
    assert!(stale.candidates.iter().any(|c| c.text == "你号"));
    let removed = call_action(
        session,
        &format!(r#"{{"op":"remove_token","index":{index},"generation":{generation}}}"#),
    );
    assert!(removed.ok, "{:?}", removed.error);
    assert!(removed.consumed);
    assert!(!removed.candidates.iter().any(|c| c.text == "你号"));
    assert_eq!(removed.committed_text, None);
    owl_msime_session_destroy(session);
    let (reopened, error) = create_with_generation(&resources, &user, &cache, "removal");
    assert!(error.is_none(), "{error:?}");
    for ch in ['n', 'i', 'h', 'a', 'o'] {
        call_action(reopened, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    assert!(!call_snapshot(reopened)
        .candidates
        .iter()
        .any(|c| c.text == "你号"));
    owl_msime_session_destroy(reopened);
}

#[test]
fn upstream_generation_keeps_the_journal_at_user_root_and_replays_learning() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    let user = tmp.path().join("msime-user");
    let cache = tmp.path().join("msime-cache");

    let (first, error) = create_with_generation(&resources, &user, &cache, "seed-first");
    assert!(error.is_none(), "{error:?}");
    assert!(!first.is_null());
    for ch in ['n', 'i'] {
        call_action(first, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    assert_eq!(
        select_visible_text(first, "泥").committed_text.as_deref(),
        Some("泥")
    );
    msime_engine::flush_personal_learning();
    owl_msime_session_destroy(first);

    let journal = user.join(msime_engine::assets::USER_JOURNAL);
    assert!(
        journal.is_file(),
        "journal must live directly under user_data"
    );
    let journal_weight: i64 = Connection::open(&journal)
        .unwrap()
        .query_row(
            "SELECT weight FROM user_dictionary_operations
             WHERE dictionary='pinyin' AND key='ni' AND value='泥'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(journal_weight > 2000, "{journal_weight}");

    let (second, error) = create_with_generation(&resources, &user, &cache, "seed-replayed");
    assert!(error.is_none(), "{error:?}");
    assert!(!second.is_null());
    let replayed_weight: i64 = Connection::open(
        user.join("dictionaries/seed-replayed")
            .join(msime_engine::assets::MAIN_DICTIONARY),
    )
    .unwrap()
    .query_row(
        "SELECT weight FROM tbl_1_n WHERE key='ni' AND value='泥'",
        [],
        |row| row.get(0),
    )
    .unwrap();
    assert_eq!(
        replayed_weight, journal_weight,
        "a new generation must replay the learning journal"
    );
    owl_msime_session_destroy(second);
}

#[test]
fn upstream_generations_switch_without_discarding_journal_learning() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    let user = tmp.path().join("msime-user");
    let cache = tmp.path().join("msime-cache");

    let (session_a, error_a) = create_with_generation(&resources, &user, &cache, "content-a");
    assert!(error_a.is_none(), "{error_a:?}");
    assert!(!session_a.is_null());
    call_action(session_a, r#"{"op":"insert","ch":"n"}"#);

    let (session_b, error_b) = create_with_generation(&resources, &user, &cache, "content-b");
    assert!(error_b.is_none(), "{error_b:?}");
    assert!(!session_b.is_null());
    assert!(user
        .join("dictionaries/content-a")
        .join(msime_engine::assets::GENERATION_READY)
        .is_file());
    assert!(user
        .join("dictionaries/content-b")
        .join(msime_engine::assets::GENERATION_READY)
        .is_file());

    let continued = call_action(session_a, r#"{"op":"insert","ch":"i"}"#);
    assert_eq!(continued.raw_input, "ni");
    assert!(
        call_snapshot(session_a)
            .candidates
            .iter()
            .any(|candidate| candidate.text == "你"),
        "preparing a second content id must not disturb the live first session"
    );

    for ch in ['n', 'i'] {
        call_action(session_b, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    assert_eq!(
        select_visible_text(session_b, "泥")
            .committed_text
            .as_deref(),
        Some("泥")
    );
    msime_engine::flush_personal_learning();
    owl_msime_session_destroy(session_a);
    owl_msime_session_destroy(session_b);

    let (reopened_a, error) = create_with_generation(&resources, &user, &cache, "content-a");
    assert!(error.is_none(), "{error:?}");
    assert!(!reopened_a.is_null());
    let weight: i64 = Connection::open(
        user.join("dictionaries/content-a")
            .join(msime_engine::assets::MAIN_DICTIONARY),
    )
    .unwrap()
    .query_row(
        "SELECT weight FROM tbl_1_n WHERE key='ni' AND value='泥'",
        [],
        |row| row.get(0),
    )
    .unwrap();
    assert!(
        weight > 2000,
        "switching back to content-a must keep learning written while content-b was active"
    );
    owl_msime_session_destroy(reopened_a);
}

#[test]
fn upstream_generation_rejects_invalid_inputs_before_user_writes() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));

    let overlap_resources = build_minimal_test_resources(&tmp.path().join("overlap-resources"));
    let before = directory_tree(tmp.path());
    let (session, error) = create_with_generation(
        &overlap_resources,
        &overlap_resources.join("user"),
        &tmp.path().join("overlap-cache"),
        "v1",
    );
    assert!(session.is_null());
    assert!(error.is_some());
    assert_eq!(directory_tree(tmp.path()), before);

    let before = directory_tree(tmp.path());
    let (session, error) = create_with_generation(
        &resources,
        Path::new("relative-user"),
        &tmp.path().join("relative-cache"),
        "v1",
    );
    assert!(session.is_null());
    assert!(error.is_some());
    assert_eq!(directory_tree(tmp.path()), before);

    let before = directory_tree(tmp.path());
    let (session, error) = create_with_generation(
        &resources,
        &tmp.path().join("invalid-id-user"),
        &tmp.path().join("invalid-id-cache"),
        "../escape",
    );
    assert!(session.is_null());
    assert!(error.is_some());
    assert_eq!(directory_tree(tmp.path()), before);

    let missing_english = tmp.path().join("missing-english");
    fs::create_dir_all(&missing_english).unwrap();
    build_minimal_test_pinyin_db(&missing_english.join(msime_engine::assets::MAIN_DICTIONARY));
    let before = directory_tree(tmp.path());
    let (session, error) = create_with_generation(
        &missing_english,
        &tmp.path().join("missing-english-user"),
        &tmp.path().join("missing-english-cache"),
        "v1",
    );
    assert!(session.is_null());
    assert!(error
        .as_deref()
        .is_some_and(|message| message.contains("msime-english.db")));
    assert_eq!(directory_tree(tmp.path()), before);

    let missing_pinyin = tmp.path().join("missing-pinyin");
    fs::create_dir_all(&missing_pinyin).unwrap();
    ensure_english_schema(&missing_pinyin.join(msime_engine::assets::ENGLISH_DICTIONARY))
        .unwrap();
    let before = directory_tree(tmp.path());
    let (session, error) = create_with_generation(
        &missing_pinyin,
        &tmp.path().join("missing-pinyin-user"),
        &tmp.path().join("missing-pinyin-cache"),
        "v1",
    );
    assert!(session.is_null());
    assert!(error
        .as_deref()
        .is_some_and(|message| message.contains("msime-pinyin.db")));
    assert_eq!(directory_tree(tmp.path()), before);
}

#[test]
fn upstream_generation_reports_replay_failure_without_publishing() {
    let tmp = TempDir::new().unwrap();
    let resources = build_minimal_test_resources(&tmp.path().join("resources"));
    let user = tmp.path().join("msime-user");
    fs::create_dir_all(user.join("dictionaries")).unwrap();
    let journal = user.join(msime_engine::assets::USER_JOURNAL);
    Connection::open(&journal)
        .unwrap()
        .execute_batch(
            "CREATE TABLE user_dictionary_operations(bad INTEGER);
             INSERT INTO user_dictionary_operations VALUES (1);",
        )
        .unwrap();
    let user_before = file_contents(&user);

    let (session, error) = create_with_generation(
        &resources,
        &user,
        &tmp.path().join("msime-cache"),
        "broken-replay",
    );
    assert!(session.is_null());
    assert!(error
        .as_deref()
        .is_some_and(|message| message.contains("dictionary generation")));
    assert!(!user.join("dictionaries/broken-replay").exists());
    assert!(!user.join("dictionaries/broken-replay.incoming").exists());
    assert_eq!(
        file_contents(&user),
        user_before,
        "a failed replay must not rewrite the journal or user files"
    );
}
