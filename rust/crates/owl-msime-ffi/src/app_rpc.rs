use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::Deserialize;
use serde_json::{json, Value};

const APP_ABI: u32 = 1;
const APP_MAX_REQUEST: usize = 32 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum AppRequest {
    Storage {
        data_dir: String,
        storage_op: String,
        #[serde(default)]
        args: Value,
        #[serde(default)]
        fail_checkpoint: Option<String>,
    },
    ClientCapabilities {
        input: Value,
    },
    UserDataRule {
        rule: String,
        args: Value,
    },
    TemplateSessionRule {
        rule: String,
        args: Value,
    },
    AgentRule {
        rule: String,
        #[serde(default)]
        args: Value,
    },
    AiRule {
        rule: String,
        #[serde(default)]
        args: Value,
    },
    PureRule {
        rule: String,
        #[serde(default)]
        args: Value,
    },
    ProviderRule {
        rule: String,
        #[serde(default)]
        args: Value,
    },
    TemplateDuplicate {
        entry: Value,
        new_id: Option<String>,
    },
    TemplateEncode {
        library: Value,
    },
    TemplateRule {
        rule: String,
        #[serde(default)]
        args: Value,
    },
    ResourceCatalog,
    TemplateReady {
        severities: Vec<String>,
        missing_count: usize,
        needs_empty: bool,
    },
    TemplateLocation {
        body: String,
        location: usize,
    },
    TemplateParse {
        body: String,
        plain: bool,
        legacy: bool,
        pending: bool,
        definitions: Vec<owl_app_core::template::Parameter>,
    },
    TemplateRender {
        parsed: owl_app_core::template::Parsed,
        values: std::collections::BTreeMap<String, String>,
        clipboard: String,
        clipboard_text: Option<String>,
        allow_empty: bool,
        temporal: std::collections::BTreeMap<String, owl_app_core::template::TemporalFact>,
    },
    TemplateDatePlan {
        field: owl_app_core::template::TemporalField,
        default_pattern: Option<String>,
        date: Option<f64>,
    },
    TemplateDateOffset {
        current: Option<f64>,
        next: Option<f64>,
        value: i32,
    },
    TemplateDatePattern {
        pattern: String,
        values: Vec<String>,
    },
    KeyboardSelection {
        changed: String,
        raw: Value,
    },
    KeyboardOnboarding {
        schema: String,
    },
    KeyboardSchemaMarker {
        preferred: String,
        selected: bool,
    },
    KeyboardSchemaFailure {
        requested: String,
        engine_selected: bool,
        live_result: String,
        failed_schema: String,
    },
    KeyboardCatalog,
    KeyboardSchema {
        schema: String,
    },
    KeyboardEffective {
        raw: Value,
    },
    KeyboardPageSizeWrite {
        value: i64,
    },
    KeyboardBundleIds {
        raw: String,
    },
    KeyboardFuzzyMask {
        values: Vec<bool>,
    },
    KeyboardApplication {
        mode: String,
        recovery_pending: bool,
    },
    InitialAsciiMode {
        bundle_id: String,
        english_bundle_ids: Vec<String>,
        default_ascii: bool,
    },
    Utf16Range {
        text: String,
        location: usize,
        length: usize,
    },
}

fn app_error(code: &str) -> Value {
    json!({"ok": false, "error": code})
}

fn app_dispatch(bytes: &[u8]) -> Value {
    let request: AppRequest = match serde_json::from_slice(bytes) {
        Ok(request) => request,
        Err(_) => return app_error("invalid_request"),
    };
    if !matches!(request, AppRequest::Storage { .. }) && bytes.len() > APP_MAX_REQUEST {
        return app_error("invalid_request");
    }
    let result = match request {
        AppRequest::Storage {
            data_dir,
            storage_op,
            args,
            fail_checkpoint,
        } => match owl_app_core::storage::dispatch_storage(
            &data_dir,
            &storage_op,
            args,
            fail_checkpoint,
        ) {
            Ok((value, committed)) => {
                return json!({"ok": true, "value": value, "committed": committed});
            }
            Err(code) => return app_error(&code),
        },
        AppRequest::ClientCapabilities { input } => {
            owl_app_core::client_capability::evaluate(&input)
        }
        AppRequest::UserDataRule { rule, args } => owl_app_core::user_data::rule(&rule, args),
        AppRequest::TemplateSessionRule { rule, args } => {
            owl_app_core::template_session::rule(&rule, args)
        }
        AppRequest::AgentRule { rule, args } => match owl_app_core::agent::rule(&rule, args) {
            Ok(value) => value,
            Err(code) => return app_error(&code),
        },
        AppRequest::AiRule { rule, args } => owl_app_core::ai_business::rule(&rule, args),
        AppRequest::PureRule { rule, args } => {
            match owl_app_core::pure_rules::dispatch(&rule, args) {
                Ok(value) => value,
                Err(code) => return app_error(&code),
            }
        }
        AppRequest::ProviderRule { rule, args } => owl_app_core::provider_wire::rule(&rule, args),
        AppRequest::TemplateDuplicate { entry, new_id } => {
            let e = match owl_app_core::storage::decode::<owl_app_core::template_library::Entry>(
                entry,
            ) {
                Ok(e) => e,
                Err(code) => return app_error(&code),
            };
            let id = new_id.unwrap_or_else(owl_app_core::storage::next_uuid_v4);
            let copy = e.duplicated(id);
            json!(copy)
        }
        AppRequest::TemplateEncode { library } => {
            let lib = match owl_app_core::storage::decode::<
                owl_app_core::template_library::Library,
            >(library)
            {
                Ok(l) => l,
                Err(code) => return app_error(&code),
            };
            match owl_app_core::template_library::encoded(&lib) {
                Ok(bytes) => json!(bytes),
                Err(code) => return app_error(&code),
            }
        }
        AppRequest::TemplateRule { rule, args } => {
            let result = if rule.starts_with("picker_") {
                owl_app_core::picker::dispatch(&rule, args)
            } else if rule.starts_with("editor_") {
                owl_app_core::template_editor::dispatch(&rule, args)
            } else if rule.starts_with("import_") {
                owl_app_core::template_import::dispatch_rule(&rule, args)
            } else {
                owl_app_core::template_library::dispatch_rule(&rule, args)
            };
            match result {
                Ok(value) => value,
                Err(code) => return app_error(&code),
            }
        }
        AppRequest::ResourceCatalog => owl_app_core::resource_catalog::catalog(),
        AppRequest::TemplateReady {
            severities,
            missing_count,
            needs_empty,
        } => json!(owl_app_core::template::ready(
            &severities,
            missing_count,
            needs_empty
        )),
        AppRequest::TemplateLocation { body, location } => {
            json!(owl_app_core::template::location(&body, location))
        }
        AppRequest::TemplateParse {
            body,
            plain,
            legacy,
            pending,
            definitions,
        } => {
            if body.len() > 4 * 1024 * 1024 {
                return app_error("invalid_request");
            }
            json!(owl_app_core::template::parse(
                &body,
                plain,
                legacy,
                pending,
                definitions
            ))
        }
        AppRequest::TemplateRender {
            parsed,
            values,
            clipboard,
            clipboard_text,
            allow_empty,
            temporal,
        } => {
            if clipboard_text
                .as_ref()
                .is_some_and(|c| c.len() > 4 * 1024 * 1024)
                || values.values().any(|v| v.len() > 4 * 1024 * 1024)
            {
                return app_error("invalid_request");
            }
            json!(owl_app_core::template::render(
                &parsed,
                &values,
                &clipboard,
                clipboard_text.as_deref(),
                allow_empty,
                &temporal
            ))
        }
        AppRequest::TemplateDatePlan {
            field,
            default_pattern,
            date,
        } => json!(owl_app_core::template::date_plan(
            &field,
            default_pattern.as_deref(),
            date
        )),
        AppRequest::TemplateDateOffset {
            current,
            next,
            value,
        } => json!({"error":owl_app_core::template::date_offset(current,next,value)}),
        AppRequest::TemplateDatePattern { pattern, values } => {
            json!(owl_app_core::template::date_pattern(&pattern, &values))
        }
        AppRequest::KeyboardSelection { changed, raw } => {
            owl_app_core::keyboard::selection(&changed, &raw)
        }
        AppRequest::KeyboardOnboarding { schema } => owl_app_core::keyboard::onboarding(&schema),
        AppRequest::KeyboardSchemaMarker {
            preferred,
            selected,
        } => owl_app_core::keyboard::schema_marker(&preferred, selected),
        AppRequest::KeyboardSchemaFailure {
            requested,
            engine_selected,
            live_result,
            failed_schema,
        } => owl_app_core::keyboard::schema_failure(
            &requested,
            engine_selected,
            &live_result,
            &failed_schema,
        ),
        AppRequest::KeyboardCatalog => owl_app_core::keyboard::catalog().clone(),
        AppRequest::KeyboardSchema { schema } => owl_app_core::keyboard::schema(&schema),
        AppRequest::KeyboardEffective { raw } => owl_app_core::keyboard::effective(&raw),
        AppRequest::KeyboardPageSizeWrite { value } => {
            json!(owl_app_core::keyboard::page_size_write(value))
        }
        AppRequest::KeyboardBundleIds { raw } => {
            json!(owl_app_core::keyboard::normalized_bundle_ids(&raw))
        }
        AppRequest::KeyboardFuzzyMask { values } => json!(owl_app_core::keyboard::fuzzy_mask(&values)),
        AppRequest::KeyboardApplication {
            mode,
            recovery_pending,
        } => owl_app_core::keyboard::application(&mode, recovery_pending),
        AppRequest::InitialAsciiMode {
            bundle_id,
            english_bundle_ids,
            default_ascii,
        } => json!(owl_app_core::initial_ascii_mode(
            &bundle_id,
            &english_bundle_ids,
            default_ascii
        )),
        AppRequest::Utf16Range {
            text,
            location,
            length,
        } => {
            let Some(range) = owl_app_core::utf16_range(&text, location, length) else {
                return app_error("invalid_range");
            };
            json!({"start": range.start, "end": range.end})
        }
    };
    json!({"ok": true, "value": result})
}

#[no_mangle]
pub extern "C" fn owl_app_keyboard_can_apply(requires_idle: u8, composing: u8) -> u8 {
    u8::from(owl_app_core::keyboard::can_apply(
        requires_idle != 0,
        composing != 0,
    ))
}

#[no_mangle]
pub extern "C" fn owl_app_keyboard_schema_idle_action(
    current_matches: u8,
    failed_matches: u8,
) -> u32 {
    owl_app_core::keyboard::schema_idle_action(current_matches != 0, failed_matches != 0)
}

#[no_mangle]
pub extern "C" fn owl_app_keyboard_refresh(pending: u8, composing: u8) -> u32 {
    owl_app_core::keyboard::refresh_decision(pending != 0, composing != 0)
}

#[no_mangle]
pub extern "C" fn owl_app_abi_version() -> u32 {
    APP_ABI
}

#[no_mangle]
pub unsafe extern "C" fn owl_app_call(
    version: u32,
    request: *const u8,
    length: usize,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if version != APP_ABI {
            return app_error("abi_mismatch");
        }
        if request.is_null() || length == 0 || length > isize::MAX as usize {
            return app_error("invalid_request");
        }
        app_dispatch(unsafe { std::slice::from_raw_parts(request, length) })
    }))
    .unwrap_or_else(|_| app_error("internal_error"));
    CString::new(response.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}

type HostCallback = unsafe extern "C" fn(*mut std::ffi::c_void, *const c_char) -> *const c_char;
struct NativeHost {
    context: *mut std::ffi::c_void,
    callback: HostCallback,
}
impl owl_app_core::storage::Host for NativeHost {
    fn effect(&mut self, value: Value) -> Result<Value, String> {
        let request = CString::new(value.to_string()).map_err(|_| "invalid_payload")?;
        let pointer = unsafe { (self.callback)(self.context, request.as_ptr()) };
        if pointer.is_null() {
            return Err("native_effect_failed".into());
        }
        let response: Value =
            serde_json::from_slice(unsafe { CStr::from_ptr(pointer) }.to_bytes())
                .map_err(|_| "invalid_effect_response")?;
        if response["ok"] == true {
            Ok(response["value"].clone())
        } else {
            Err(response["error"]
                .as_str()
                .unwrap_or("native_effect_failed")
                .into())
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn owl_msime_host_effect_call(
    version: u32,
    request: *const u8,
    length: usize,
    context: *mut std::ffi::c_void,
    callback: Option<HostCallback>,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if version != APP_ABI {
            return app_error("abi_mismatch");
        }
        if request.is_null() || length == 0 || length > isize::MAX as usize {
            return app_error("invalid_request");
        }
        let Some(callback) = callback else {
            return app_error("invalid_request");
        };
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct EffectRequest {
            operation: String,
            args: Value,
        }
        let Ok(request) = serde_json::from_slice::<EffectRequest>(unsafe {
            std::slice::from_raw_parts(request, length)
        }) else {
            return app_error("invalid_request");
        };
        let mut host = NativeHost { context, callback };
        let result = if request.operation.starts_with("provider_") {
            owl_app_core::provider_store::dispatch(&mut host, &request.operation, request.args)
                .map(|v| json!({"result": v}))
        } else {
            Err("invalid_operation".into())
        };
        match result {
            Ok(value) => json!({"ok": true, "value": value}),
            Err(code) => app_error(&code),
        }
    }))
    .unwrap_or_else(|_| app_error("internal_error"));
    CString::new(response.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn owl_app_session_new(
    version: u32,
    request: *const u8,
    length: usize,
    output: *mut *mut c_char,
) -> *mut owl_app_core::template_session::Session {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if version != APP_ABI {
            return Err("abi_mismatch".to_string());
        }
        if request.is_null() || length == 0 || length > isize::MAX as usize {
            return Err("invalid_request".into());
        }
        let value: Value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(request, length) })
                .map_err(|_| "invalid_request")?;
        owl_app_core::template_session::Session::create(
            value["kind"].as_str().unwrap_or(""),
            value["args"].clone(),
        )
    }))
    .unwrap_or_else(|_| Err("internal_error".into()));
    let (session, response) = match result {
        Ok(session) => (
            Box::into_raw(Box::new(session)),
            json!({"ok": true, "value": true}),
        ),
        Err(code) => (std::ptr::null_mut(), app_error(&code)),
    };
    if !output.is_null() {
        unsafe {
            *output = CString::new(response.to_string()).unwrap().into_raw();
        }
    }
    session
}

#[no_mangle]
pub unsafe extern "C" fn owl_app_session_call(
    session: *mut owl_app_core::template_session::Session,
    request: *const u8,
    length: usize,
    index: *const owl_app_core::template_session::Session,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if session.is_null()
            || request.is_null()
            || length == 0
            || length > isize::MAX as usize
            || std::ptr::eq(session, index)
        {
            return app_error("invalid_request");
        }
        let limit = match unsafe { &*session } {
            owl_app_core::template_session::Session::Runtime(_) => usize::MAX,
            owl_app_core::template_session::Session::Invocation(_) => 4 * 1024 * 1024,
            _ => APP_MAX_REQUEST,
        };
        if length > limit {
            return app_error("invalid_request");
        }
        let Ok(value) =
            serde_json::from_slice::<Value>(unsafe { std::slice::from_raw_parts(request, length) })
        else {
            return app_error("invalid_request");
        };
        match unsafe { &mut *session }.event(
            value["event"].as_str().unwrap_or(""),
            value["args"].clone(),
            unsafe { index.as_ref() },
        ) {
            Ok(value) => json!({"ok": true, "value": value}),
            Err(code) => app_error(&code),
        }
    }))
    .unwrap_or_else(|_| app_error("internal_error"));
    CString::new(response.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn owl_app_session_free(
    session: *mut owl_app_core::template_session::Session,
) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

#[cfg(test)]
mod app_ffi_tests {
    use super::*;
    use std::ffi::CStr;
    use tempfile::TempDir;
    use crate::owl_msime_string_free;

    fn call(version: u32, bytes: &[u8]) -> Value {
        unsafe {
            let pointer = owl_app_call(version, bytes.as_ptr(), bytes.len());
            let value = serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()).unwrap();
            owl_msime_string_free(pointer);
            value
        }
    }

    #[test]
    fn rejects_version_bad_payload_and_range_without_echoing_content() {
        assert_eq!(call(2, b"private text"), app_error("abi_mismatch"));
        assert_eq!(call(1, b"private text"), app_error("invalid_request"));
        assert_eq!(call(1, &[0xff]), app_error("invalid_request"));
        assert_eq!(
            call(
                1,
                br#"{"operation":"utf16_range","text":"x","location":2,"length":0}"#
            ),
            app_error("invalid_range")
        );
        unsafe {
            let result = owl_app_call(1, std::ptr::null(), 0);
            assert_eq!(
                CStr::from_ptr(result).to_str().unwrap(),
                app_error("invalid_request").to_string()
            );
            owl_msime_string_free(result);
            owl_msime_string_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn template_duplicate_preserves_content_and_resets_identity_metadata() {
        for exposure in [Value::Null, json!(false), json!(true)] {
            let mut entry = json!({
                "id": "abcdefab-cdef-4abc-8def-abcdefabcdef",
                "title": "模板",
                "body": "{{topic}}",
                "bodyType": "template",
                "syntax": "legacyDoubleBraces",
                "candidateAliases": ["alias"],
                "trigger": ";;topic",
                "tags": ["work"],
                "isPinned": true,
                "category": "prompt",
                "parameters": [{"key":"topic","name":"主题","isRequired":true,
                    "defaultValue":"发布","options":["发布","复盘"]}],
                "invocationMode": "automatic",
                "expansionMode": "immediate",
                "importSource": {"version":1,"originalName":"导入",
                    "originalBody":"{{topic}}","originalKeyword":"keyword"},
                "reviewState": "pending"
            });
            if !exposure.is_null() {
                entry["exposedToAgents"] = exposure;
            }
            let expected = json!({
                "id": "supplied-id",
                "title": "模板 副本",
                "body": "{{topic}}",
                "bodyType": "template",
                "syntax": "legacyDoubleBraces",
                "candidateAliases": [],
                "tags": ["work"],
                "isPinned": true,
                "category": "prompt",
                "parameters": entry["parameters"],
                "invocationMode": "searchOnly",
                "expansionMode": "delimiterDrop",
                "reviewState": "pending"
            });
            let direct = call(1, &serde_json::to_vec(&json!({
                "operation":"template_duplicate", "entry":entry, "new_id":"supplied-id"
            })).unwrap());
            assert_eq!(direct, json!({"ok":true,"value":expected}));

            let generated = call(
                1,
                &serde_json::to_vec(&json!({"operation":"template_duplicate", "entry":entry}))
                    .unwrap(),
            );
            assert_eq!(generated["ok"], true);
            let mut copy = generated["value"].clone();
            let id = copy["id"].as_str().unwrap();
            assert!(owl_app_core::template_library::valid_id(id), "{generated}");
            assert_ne!(id, "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF");
            copy["id"] = json!("supplied-id");
            assert_eq!(copy, expected);
        }
        assert_eq!(
            call(
                1,
                &serde_json::to_vec(&json!({"operation":"template_duplicate", "entry":{"id":"invalid"}}))
                    .unwrap()
            ),
            app_error("invalid_payload")
        );
    }

    #[test]
    fn rust_native_storage_round_trips_template_library_with_0600_permissions() {
        let dir = TempDir::new().unwrap();
        let data_dir = dir.path().to_str().unwrap();
        let save_req = json!({
            "operation": "storage",
            "data_dir": data_dir,
            "storage_op": "library_save",
            "args": {
                "library": {
                    "formatVersion": 1,
                    "entries": [{
                        "id": "11111111-1111-4111-8111-111111111111",
                        "title": "测试",
                        "body": "内容",
                        "bodyType": "plainText",
                        "syntax": "standard",
                        "trigger": null,
                        "candidateAliases": [],
                        "invocationMode": "searchOnly",
                        "expansionMode": "immediate",
                        "tags": [],
                        "isPinned": false,
                        "category": "general",
                        "parameters": [],
                        "reviewState": null,
                        "importSource": null
                    }]
                }
            }
        });
        let saved = call(1, &serde_json::to_vec(&save_req).unwrap());
        assert_eq!(saved["ok"], true);
        assert_eq!(saved["committed"], true);

        let load_req = json!({
            "operation": "storage",
            "data_dir": data_dir,
            "storage_op": "library_load",
            "args": {}
        });
        let loaded = call(1, &serde_json::to_vec(&load_req).unwrap());
        assert_eq!(loaded["ok"], true);
        assert_eq!(loaded["value"]["entries"][0]["title"], "测试");
    }

    fn entry_json(id: &str, title: &str, tags: &[&str]) -> Value {
        json!({
            "id": id,
            "title": title,
            "body": "正文",
            "bodyType": "plainText",
            "syntax": "standard",
            "trigger": null,
            "candidateAliases": [],
            "invocationMode": "searchOnly",
            "expansionMode": "delimiterDrop",
            "tags": tags,
            "isPinned": false,
            "category": "general",
            "parameters": []
        })
    }

    #[test]
    fn template_rule_uses_canonical_unicode_collation_and_containment() {
        let entries = json!([
            entry_json("11111111-1111-4111-8111-111111111111", "b", &["b", "cafe\u{0301}"]),
            entry_json("22222222-2222-4222-8222-222222222222", "A", &["A"]),
            entry_json("44444444-4444-4444-8444-444444444444", "a\u{0301}", &["a\u{0301}"]),
            entry_json("33333333-3333-4333-8333-333333333333", "\u{00e1}", &["\u{00e1}", "cafe"]),
        ]);

        let sorted = call(
            1,
            &serde_json::to_vec(&json!({
                "operation": "template_rule",
                "rule": "library_sorted",
                "args": {"entries": entries}
            }))
            .unwrap(),
        );
        assert_eq!(sorted["ok"], true);
        let sorted_titles: Vec<&str> = sorted["value"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["title"].as_str().unwrap())
            .collect();
        assert_eq!(sorted_titles, vec!["A", "b", "\u{00e1}", "a\u{0301}"]);

        let tag_filtered = call(
            1,
            &serde_json::to_vec(&json!({
                "operation": "template_rule",
                "rule": "library_filtered",
                "args": {"entries": entries, "query": "", "tag": "CAF\u{00c9}", "promptOnly": false}
            }))
            .unwrap(),
        );
        assert_eq!(tag_filtered["ok"], true);
        let tag_titles: Vec<&str> = tag_filtered["value"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["title"].as_str().unwrap())
            .collect();
        assert_eq!(tag_titles, vec!["b"]);

        let query_filtered = call(
            1,
            &serde_json::to_vec(&json!({
                "operation": "template_rule",
                "rule": "library_filtered",
                "args": {
                    "entries": [
                        entry_json("55555555-5555-4555-8555-555555555555", "A\u{0301}lpha", &[]),
                        entry_json("66666666-6666-4666-8666-666666666666", "Beta", &[])
                    ],
                    "query": "\u{00e1}lp",
                    "tag": null,
                    "promptOnly": false
                }
            }))
            .unwrap(),
        );
        assert_eq!(query_filtered["ok"], true);
        assert_eq!(query_filtered["value"].as_array().unwrap().len(), 1);
        assert_eq!(query_filtered["value"][0]["title"], "A\u{0301}lpha");

        let tags = call(
            1,
            &serde_json::to_vec(&json!({
                "operation": "template_rule",
                "rule": "library_tags",
                "args": {
                    "entries": [
                        entry_json("11111111-1111-4111-8111-111111111111", "1", &["b", "A"]),
                        entry_json("22222222-2222-4222-8222-222222222222", "2", &["a\u{0301}", "\u{00e1}"])
                    ]
                }
            }))
            .unwrap(),
        );
        assert_eq!(tags["ok"], true);
        assert_eq!(tags["value"], json!(["A", "b", "a\u{0301}"]));
    }

    #[test]
    fn template_duplicate_generates_distinct_rfc4122_v4_uuids() {
        let entry = entry_json("abcdefab-cdef-4abc-8def-abcdefabcdef", "模板", &[]);
        let req = serde_json::to_vec(&json!({
            "operation": "template_duplicate",
            "entry": entry
        }))
        .unwrap();
        let first = call(1, &req);
        let second = call(1, &req);
        let id1 = first["value"]["id"].as_str().unwrap();
        let id2 = second["value"]["id"].as_str().unwrap();
        assert_ne!(id1, id2);
        for id in [id1, id2] {
            assert!(owl_app_core::template_library::valid_id(id), "{id}");
            assert_eq!(id.as_bytes()[14], b'4', "{id}");
            assert!(
                matches!(id.as_bytes()[19], b'8' | b'9' | b'A' | b'B'),
                "{id}"
            );
        }
    }

    #[test]
    fn provider_rule_evaluates_wire_and_workspace_rules_via_ffi() {
        let host = "ws-abc123.cn-beijing.maas.aliyuncs.com";
        let endpoint = "https://ws-abc123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses";
        let default_endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/responses";

        let call_rule = |rule: &str, args: Value| {
            call(
                1,
                &serde_json::to_vec(&json!({
                    "operation": "provider_rule",
                    "rule": rule,
                    "args": args,
                }))
                .unwrap(),
            )
        };

        let accepted = call_rule("httpAccepted", json!({"status": 200}));
        assert_eq!(accepted["ok"], true);
        assert_eq!(accepted["value"], json!(true));

        let rejected_http = call_rule("httpAccepted", json!({"status": 401}));
        assert_eq!(rejected_http["ok"], true);
        assert_eq!(rejected_http["value"], json!(false));

        let ws = call_rule("workspace", json!({"input": "ws-abc123"}));
        assert_eq!(ws["ok"], true);
        assert_eq!(ws["value"], json!(host));

        let ws_ep = call_rule("workspaceEndpoint", json!({"input": host}));
        assert_eq!(ws_ep["ok"], true);
        assert_eq!(ws_ep["value"], json!(endpoint));

        let resolved_blank = call_rule("resolvedWorkspace", json!({"input": ""}));
        assert_eq!(resolved_blank["ok"], true);
        assert_eq!(resolved_blank["value"], json!(default_endpoint));

        let rejected_port = call_rule(
            "workspaceEndpoint",
            json!({"input": format!("https://{host}:443/compatible-mode/v1/responses")}),
        );
        assert_eq!(rejected_port["ok"], true);
        assert_eq!(rejected_port["value"], Value::Null);
    }
}
