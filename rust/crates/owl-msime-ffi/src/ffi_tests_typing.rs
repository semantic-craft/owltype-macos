use std::ffi::CString;

use rusqlite::Connection;
use tempfile::TempDir;

use crate::ffi_tests_support::*;
use crate::*;

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
    assert_eq!(
        selected.committed_text.as_deref(),
        Some(second_text.as_str())
    );
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
fn ffi_partial_phrase_selection_stays_in_preedit_until_the_phrase_ends() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    for ch in ['n', 'i', 'h', 'a', 'o'] {
        call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    let held = select_visible_text(session, "你");
    assert!(held.consumed);
    assert_eq!(
        held.committed_text, None,
        "a candidate that consumes only the first syllable must stay in the composition"
    );
    assert_eq!(held.raw_input, "hao");
    assert_eq!(held.preedit, "你hao");
    assert_eq!(held.preedit_caret_byte, "你hao".len());

    // Continuing and then editing the remaining spelling must keep the chosen piece held.
    let continued = call_action(session, r#"{"op":"insert","ch":"n"}"#);
    assert_eq!(continued.committed_text, None);
    assert_eq!(continued.raw_input, "haon");
    assert_eq!(continued.preedit, "你hao'n");
    let edited = call_action(session, r#"{"op":"backspace"}"#);
    assert_eq!(edited.committed_text, None);
    assert_eq!(edited.raw_input, "hao");
    assert_eq!(edited.preedit, "你hao");

    // Ordinary Backspace retreats the latest selection when the tail reaches one character.
    let shorter = call_action(session, r#"{"op":"backspace"}"#);
    assert_eq!(shorter.committed_text, None);
    assert_eq!(shorter.preedit, "你ha");
    let shorter = call_action(session, r#"{"op":"backspace"}"#);
    assert_eq!(shorter.committed_text, None);
    assert_eq!(shorter.preedit, "你h");
    let restored = call_action(session, r#"{"op":"backspace"}"#);
    assert_eq!(restored.committed_text, None);
    assert_eq!(restored.raw_input, "ni");
    assert_eq!(restored.preedit, "ni");

    // Select the same piece again and finish the phrase; the pieces go out as one commit.
    for ch in ['h', 'a', 'o'] {
        call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    select_visible_text(session, "你");
    let committed = select_visible_text(session, "好");
    assert_eq!(committed.committed_text.as_deref(), Some("你好"));
    assert!(committed.raw_input.is_empty());
    assert!(committed.preedit.is_empty());

    // Escape discards both the unfinished spelling and the held piece.
    for ch in ['n', 'i', 'h', 'a', 'o'] {
        call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    select_visible_text(session, "你");
    let cancelled = call_action(session, r#"{"op":"clear"}"#);
    assert!(cancelled.cleared);
    assert_eq!(cancelled.committed_text, None);
    assert!(cancelled.raw_input.is_empty());
    assert!(cancelled.preedit.is_empty());

    owl_msime_session_destroy(session);
}

#[test]
fn peek_preserves_published_generation_and_selection_with_withheld_candidates() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let conn = Connection::open(&db_path).unwrap();
    for index in 0..60 {
        let word = char::from_u32(0x4e00 + index).unwrap().to_string();
        conn.execute(
            "INSERT INTO tbl_1_n (key, jp, value, weight) VALUES ('ni', 'n', ?1, ?2)",
            rusqlite::params![word, 10000 - index],
        )
        .unwrap();
    }
    drop(conn);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());
    call_action(session, r#"{"op":"insert","ch":"n"}"#);
    call_action(session, r#"{"op":"turn_page","delta":1}"#);
    let before = call_snapshot(session);
    let expected = before.candidates[0].text.clone();
    let peek = call_action(session, r#"{"op":"peek_candidates","start":10,"count":20}"#);
    let after = call_snapshot(session);
    assert_eq!(
        peek.generation, before.generation,
        "passive prefetch must not expand or retag displayed rows"
    );
    assert_eq!(after.generation, before.generation);
    assert_eq!(after.page, before.page);
    assert_eq!(after.candidates[0].text, expected);
    let selected = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":0,"generation":{}}}"#,
            before.generation
        ),
    );
    assert_eq!(selected.committed_text.as_deref(), Some(expected.as_str()));
    // The passive read must not permanently hide the withheld tail: real paging still releases it.
    call_action(session, r#"{"op":"insert","ch":"n"}"#);
    for _ in 0..6 {
        call_action(session, r#"{"op":"turn_page","delta":1}"#);
    }
    let tail = call_snapshot(session);
    assert!(
        tail.page >= 5,
        "paging must reach beyond the initial 24 candidates"
    );
    let tail_text = tail.candidates[0].text.clone();
    let absolute = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":{},"is_absolute":true,"generation":{}}}"#,
            tail.page * tail.page_size,
            tail.generation
        ),
    );
    assert_eq!(absolute.committed_text.as_deref(), Some(tail_text.as_str()));
    owl_msime_session_destroy(session);
}

#[test]
fn builtin_date_is_enabled_and_expression_uses_upstream_disabled_default() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    let date_mode = call_action(session, r#"{"op":"insert","ch":"T"}"#);
    assert!(date_mode.ok);
    assert!(date_mode.consumed);
    assert_eq!(date_mode.local_mode, "date_time");
    for ch in ["r", "q"] {
        let response = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(response.ok, "{response:?}");
    }
    let date = call_snapshot(session);
    assert!(date.candidates.iter().any(|candidate| {
        candidate.text.contains('年')
            && candidate.text.contains('月')
            && candidate.text.contains('日')
    }));

    assert!(call_action(session, r#"{"op":"clear"}"#).ok);
    let expression_mode = call_action(session, r#"{"op":"insert","ch":"V"}"#);
    assert!(expression_mode.ok);
    assert_ne!(expression_mode.local_mode, "expression");
    assert!(!expression_mode.spelling_symbols.contains('0'));

    owl_msime_session_destroy(session);
}

#[test]
fn traditional_pin_ranks_its_simplified_source_candidate() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    assert!(
        call_action(
            session,
            r#"{"op":"set_option","name":"traditional","value":true}"#,
        )
        .ok
    );
    assert!(call_action(
        session,
        r#"{"op":"set_pinned_words","text":"shi\t1\t時","traditional_sources":[{"code":"shi","text":"時","source":"时"}]}"#,
    )
    .ok);
    for ch in ["s", "h", "i"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let pinned = call_snapshot(session);
    assert_eq!(pinned.candidates[0].text, "时");
    assert_eq!(pinned.candidates[0].comment.as_deref(), Some("置顶"));

    owl_msime_session_destroy(session);
}

#[test]
fn uncertified_traditional_pin_never_ranks_a_lossy_simplified_source() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    assert!(
        call_action(
            session,
            r#"{"op":"set_option","name":"traditional","value":true}"#,
        )
        .ok
    );
    assert!(call_action(session, r#"{"op":"set_pinned_words","text":"shi\t1\t髮"}"#).ok);
    for ch in ["s", "h", "i"] {
        assert!(call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#)).ok);
    }
    let candidates = call_snapshot(session).candidates;
    assert!(
        !candidates
            .iter()
            .any(|candidate| candidate.comment.as_deref() == Some("置顶")),
        "the lossy simplified source must not be promoted without a host-verified mapping"
    );

    owl_msime_session_destroy(session);
}

#[test]
fn supports_tokens_peek_pinned_words_punctuation_and_caret() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();

    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    // Pin "拟好" to the front for "ni hao"
    let pin_res = call_action(
        session,
        r#"{"op":"set_pinned_words","text":"nihao\t0\t拟好"}"#,
    );
    assert!(pin_res.ok);

    for ch in ['n', 'i', 'h', 'a', 'o'] {
        let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }

    let snap = call_snapshot(session);
    assert!(snap.ok);
    assert_eq!(snap.raw_input, "nihao");
    assert_eq!(snap.preedit, "ni'hao");
    assert_eq!(snap.caret_position, 5);
    assert_eq!(snap.preedit_caret_byte, 6);
    assert!(snap.generation > 0);
    assert_eq!(snap.candidates[0].text, "拟好");
    assert_eq!(snap.candidates[0].comment.as_deref(), Some("置顶"));

    // Peek candidates across pages
    let peeked = call_action(session, r#"{"op":"peek_candidates","start":0,"count":6}"#);
    assert!(peeked.ok);
    assert_eq!(peeked.candidates.len(), 6);
    assert_eq!(peeked.candidates[0].text, "拟好");
    assert_eq!(peeked.candidates[5].text, "逆号");

    // Move caret left and home, then end
    let moved_left = call_action(session, r#"{"op":"move_caret","target":"left"}"#);
    assert!(moved_left.ok);
    assert!(moved_left.consumed);
    assert_eq!(moved_left.caret_position, 4);
    assert_eq!(moved_left.preedit_caret_byte, 5);

    let moved_home = call_action(session, r#"{"op":"move_caret","target":"home"}"#);
    assert_eq!(moved_home.caret_position, 0);
    assert_eq!(moved_home.preedit_caret_byte, 0);

    let set_caret = call_action(session, r#"{"op":"set_caret","pos":5}"#);
    assert_eq!(set_caret.caret_position, 5);
    assert_eq!(set_caret.preedit_caret_byte, 6);

    // Stale generation token must be rejected without committing
    let stale_gen = snap.generation + 999;
    let stale = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":0,"is_absolute":false,"generation":{stale_gen}}}"#
        ),
    );
    assert!(stale.ok);
    assert!(!stale.consumed);
    assert!(stale.committed_text.is_none());

    // Valid token selects pinned candidate ("拟好")
    let cur_gen = call_snapshot(session).generation;
    let selected_pinned = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":0,"is_absolute":false,"generation":{cur_gen}}}"#
        ),
    );
    assert!(selected_pinned.ok);
    assert!(selected_pinned.consumed);
    assert_eq!(selected_pinned.committed_text.as_deref(), Some("拟好"));

    // Absolute token across pages (index 5 -> "逆号")
    for ch in ['n', 'i', 'h', 'a', 'o'] {
        let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    let gen2 = call_snapshot(session).generation;
    let selected_abs = call_action(
        session,
        &format!(r#"{{"op":"select_token","index":5,"is_absolute":true,"generation":{gen2}}}"#),
    );
    assert!(selected_abs.ok);
    assert!(selected_abs.consumed);
    assert_eq!(selected_abs.committed_text.as_deref(), Some("逆号"));

    // Chinese punctuation while composing commits highlighted candidate + full-width punctuation
    for ch in ['n', 'i', 'h', 'a', 'o'] {
        let _ = call_action(session, &format!("{{\"op\":\"insert\",\"ch\":\"{ch}\"}}"));
    }
    let punct_cn = call_action(session, r#"{"op":"punctuation","ch":",","ascii":false}"#);
    assert!(punct_cn.ok);
    assert!(punct_cn.consumed);
    assert_eq!(punct_cn.committed_text.as_deref(), Some("拟好，"));

    owl_msime_session_destroy(session);
}

#[test]
fn punctuation_menus_cycle_commit_and_yield_to_typing() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    let slash = call_action(session, r#"{"op":"punctuation_menu","ch":"/"}"#);
    assert!(slash.ok);
    assert!(slash.consumed);
    assert_eq!(slash.raw_input, "/");
    assert_eq!(slash.preedit, "/");
    assert_eq!(
        slash
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>(),
        ["、", "/", "／", "÷"]
    );
    assert_eq!(slash.highlighted_index, 0);

    let cycled = call_action(session, r#"{"op":"punctuation_menu","ch":"/"}"#);
    assert_eq!(cycled.highlighted_index, 1);
    assert_ne!(cycled.generation, slash.generation);
    assert!(cycled.candidates == slash.candidates);

    let selected = call_action(session, r#"{"op":"select_visible","index":1}"#);
    assert!(selected.ok);
    assert!(selected.consumed);
    assert_eq!(selected.committed_text.as_deref(), Some("/"));
    assert!(selected.raw_input.is_empty());
    assert!(selected.candidates.is_empty());

    let angle = call_action(session, r#"{"op":"punctuation_menu","ch":"<"}"#);
    assert_eq!(
        angle
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>(),
        ["《", "〈", "<", "「", "“"]
    );
    let stale = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":0,"generation":{}}}"#,
            angle.generation + 1
        ),
    );
    assert!(stale.ok);
    assert!(!stale.consumed);
    assert!(stale.committed_text.is_none());
    assert_eq!(stale.candidates.len(), 5);

    let typed = call_action(session, r#"{"op":"insert","ch":"a"}"#);
    assert!(typed.ok);
    assert!(typed.consumed);
    assert_eq!(typed.committed_text.as_deref(), Some("《"));
    assert_eq!(typed.raw_input, "a");
    assert_eq!(typed.preedit, "a");

    owl_msime_session_destroy(session);
}

#[test]
fn host_generation_namespace_rejects_cross_mode_tokens() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    let runtime = call_snapshot(session);
    assert!(runtime.generation > 0);
    let menu = call_action(session, r#"{"op":"punctuation_menu","ch":"<"}"#);
    assert!(menu.ok);
    assert_eq!(menu.raw_input, "<");

    // A candidate token published by the composition must not become valid merely
    // because the first punctuation menu happened to use the same counter value.
    let stale_runtime = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":1,"generation":{}}}"#,
            runtime.generation
        ),
    );
    assert!(stale_runtime.ok);
    assert!(!stale_runtime.consumed);
    assert!(stale_runtime.committed_text.is_none());
    assert_eq!(stale_runtime.raw_input, "<");

    // The reverse direction must fail too: a menu token cannot select a candidate
    // from a runtime composition after the menu has closed.
    let closed = call_action(session, r#"{"op":"clear"}"#);
    assert!(closed.cleared);
    for ch in ['n', 'i'] {
        let typed = call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
        assert!(typed.ok);
    }
    let composed = call_snapshot(session);
    assert!(!composed.candidates.is_empty());
    let stale_menu = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":0,"generation":{}}}"#,
            menu.generation
        ),
    );
    assert!(stale_menu.ok);
    assert!(!stale_menu.consumed);
    assert!(stale_menu.committed_text.is_none());
    assert_eq!(stale_menu.raw_input, composed.raw_input);

    owl_msime_session_destroy(session);
}

#[test]
fn currency_menu_offers_dollar_then_yuan() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 5);
    assert!(!session.is_null());

    let currency = call_action(session, r#"{"op":"punctuation_menu","ch":"$"}"#);
    assert!(currency.ok);
    assert_eq!(
        currency
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>(),
        ["$", "¥"]
    );
    let selected = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":1,"generation":{}}}"#,
            currency.generation
        ),
    );
    assert!(selected.consumed);
    assert_eq!(selected.committed_text.as_deref(), Some("¥"));

    owl_msime_session_destroy(session);
}

#[test]
fn punctuation_menu_pages_and_rejects_invalid_triggers_without_losing_state() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("test-pinyin.db");
    build_minimal_test_pinyin_db(&db_path);
    let c_pinyin = CString::new(db_path.to_str().unwrap()).unwrap();
    let c_empty = CString::new("").unwrap();
    let session =
        owl_msime_session_create(c_pinyin.as_ptr(), c_empty.as_ptr(), c_empty.as_ptr(), 3);
    assert!(!session.is_null());

    let angle = call_action(session, r#"{"op":"punctuation_menu","ch":"<"}"#);
    assert_eq!(angle.page, 0);
    assert!(angle.has_more_pages);
    assert_eq!(
        angle
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>(),
        ["《", "〈", "<"]
    );

    let invalid = call_action(session, r#"{"op":"punctuation_menu","ch":";"}"#);
    assert!(!invalid.ok);
    assert!(invalid
        .error
        .as_deref()
        .is_some_and(|error| error.contains("unsupported punctuation menu trigger")));
    let preserved = call_snapshot(session);
    assert_eq!(preserved.raw_input, "<");
    assert_eq!(preserved.candidates.len(), 3);

    let page = call_action(session, r#"{"op":"turn_page","delta":1}"#);
    assert!(page.ok);
    assert!(page.consumed);
    assert_eq!(page.page, 1);
    assert_eq!(page.highlighted_index, 0);
    assert!(!page.has_more_pages);
    assert_eq!(
        page.candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect::<Vec<_>>(),
        ["「", "“"]
    );

    let past_last_page = call_action(session, r#"{"op":"turn_page","delta":1}"#);
    assert!(past_last_page.consumed);
    assert_eq!(past_last_page.page, 1);

    let selected = call_action(
        session,
        &format!(
            r#"{{"op":"select_token","index":1,"generation":{}}}"#,
            page.generation
        ),
    );
    assert!(selected.consumed);
    assert_eq!(selected.committed_text.as_deref(), Some("“"));

    for ch in ['n', 'i'] {
        call_action(session, &format!(r#"{{"op":"insert","ch":"{ch}"}}"#));
    }
    let composed = call_snapshot(session);
    let expected = composed.candidates[0].text.clone();
    let menu_while_composing = call_action(session, r#"{"op":"punctuation_menu","ch":"<"}"#);
    assert_eq!(
        menu_while_composing.committed_text.as_deref(),
        Some(expected.as_str())
    );
    assert_eq!(menu_while_composing.raw_input, "<");
    assert_eq!(menu_while_composing.candidates[0].text, "《");

    owl_msime_session_destroy(session);
}
