//! Opt-in official-resource check at the same C ABI used by OwlRustSession.
use owl_msime_ffi::*;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::time::{Duration, Instant};

fn response(raw: *mut c_char) -> Value {
    assert!(!raw.is_null());
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    owl_msime_string_free(raw);
    serde_json::from_str(&text).unwrap()
}

struct Session(*mut OwlMsimeSession, tempfile::TempDir);
impl Session {
    fn new(resources: &Path) -> Self {
        let state = tempfile::tempdir().unwrap();
        let strings: Vec<_> = [
            resources.to_path_buf(),
            state.path().join("user"),
            state.path().join("cache"),
            "official-model-parity".into(),
        ]
        .into_iter()
        .map(|p| CString::new(p.to_str().unwrap()).unwrap())
        .collect();
        let mut error = std::ptr::null_mut();
        let session = owl_msime_session_create_with_generation(
            strings[0].as_ptr(),
            strings[1].as_ptr(),
            strings[2].as_ptr(),
            strings[3].as_ptr(),
            6,
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
        Self(session, state)
    }
    fn action(&self, action: Value) -> Value {
        let action = CString::new(action.to_string()).unwrap();
        response(owl_msime_session_handle_action_json(
            self.0,
            action.as_ptr(),
        ))
    }
    fn configure(&self, model: Option<&Path>, digest: &str, expected: &str) -> Duration {
        let start = Instant::now();
        let config = CString::new(
            json!({"keyboard": {"enabled": model.is_some(),
            "path": model.map(|p| p.to_str().unwrap()).unwrap_or(""), "expected_sha256": digest},
            "settled": {"enabled": false}})
            .to_string(),
        )
        .unwrap();
        response(owl_msime_session_configure_rerank_json(
            self.0,
            config.as_ptr(),
        ));
        loop {
            let status = response(owl_msime_session_rerank_status_json(self.0));
            if status["keyboard"]["state"] == expected {
                assert_eq!(status["keyboard"]["attached"], expected == "ready");
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(10), "{status}");
            std::thread::sleep(Duration::from_millis(1));
        }
        start.elapsed()
    }
    fn type_phrase(&self) -> (Vec<String>, Duration) {
        let start = Instant::now();
        for ch in "tadefangjian".chars() {
            assert_eq!(
                self.action(json!({"op":"insert", "ch":ch.to_string()}))["ok"],
                true
            );
        }
        let snapshot = response(owl_msime_session_snapshot_json(self.0));
        let candidates = snapshot["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["text"].as_str().unwrap().to_owned())
            .collect();
        (candidates, start.elapsed())
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        owl_msime_session_destroy(self.0);
    }
}

#[test]
#[ignore = "requires materialized official resources; set OWL_MODEL_PARITY_RESOURCES to the msime directory"]
fn official_keyboard_model_matches_pinned_host_order_and_failure_fallback() {
    let resources =
        std::env::var("OWL_MODEL_PARITY_RESOURCES").expect("explicit official resources");
    let resources = Path::new(&resources);
    let keyboard = resources.join("models/keyboard-model.bin");
    let digest = "86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1";
    // Independent oracle: macos-v0.55.0 Host API, blank state, official dict-v2.0.24,
    // all defaults except neural_keyboard=true and the explicit locked model path.
    let baseline = [
        "它的房间",
        "他的房间",
        "她的房间",
        "它的放吉安",
        "他的放吉安",
        "她的放吉安",
    ];
    let ranked = [
        "他的房间",
        "它的房间",
        "它的放吉安",
        "他的放吉安",
        "他的",
        "她的",
    ];
    let off = Session::new(resources);
    let (actual, off_typing) = off.type_phrase();
    assert_eq!(actual, baseline);
    let cold = Session::new(resources);
    let cold_load = cold.configure(Some(&keyboard), digest, "ready");
    let (actual, cold_typing) = cold.type_phrase();
    assert_eq!(actual, ranked);
    // Keep cold alive so this second session really exercises the shared model cache.
    let hot = Session::new(resources);
    let hot_load = hot.configure(Some(&keyboard), digest, "ready");
    let (actual, hot_typing) = hot.type_phrase();
    assert_eq!(actual, ranked);
    let selected = hot.action(json!({"op":"select_visible", "index":1}));
    assert_eq!(selected["committed_text"], "它的房间");
    eprintln!("keyboard off_phrase={off_typing:?}, cold_load={cold_load:?}, hot_load={hot_load:?}, cold_phrase={cold_typing:?}, hot_phrase={hot_typing:?}");
    // A schema rebuild must retain both scorers. Returning to quanpin uses the same oracle.
    assert_eq!(
        cold.action(json!({"op":"set_pinyin_scheme", "scheme":"xiaohe"}))["ok"],
        true
    );
    assert_eq!(
        cold.action(json!({"op":"set_pinyin_scheme", "scheme":"quanpin"}))["ok"],
        true
    );
    assert_eq!(cold.type_phrase().0, ranked);
    // Disable during active input: refresh without losing raw input or retaining neural rows.
    cold.configure(None, "", "disabled");
    let disabled = response(owl_msime_session_snapshot_json(cold.0));
    assert_eq!(disabled["raw_input"], "tadefangjian");
    assert_eq!(
        disabled["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["text"].as_str().unwrap())
            .collect::<Vec<_>>(),
        baseline
    );
    for failure in ["missing", "corrupt", "digest"] {
        let fallback = Session::new(resources);
        let path = fallback.1.path().join("bad-model.bin");
        if failure != "missing" {
            std::fs::write(&path, b"not safetensors").unwrap();
        }
        let expected = if failure == "digest" {
            "corrupt"
        } else {
            failure
        };
        fallback.configure(
            Some(&path),
            if failure == "digest" { digest } else { "" },
            expected,
        );
        assert_eq!(
            fallback.type_phrase().0,
            baseline,
            "{failure} must use the same non-neural engine"
        );
    }
}
