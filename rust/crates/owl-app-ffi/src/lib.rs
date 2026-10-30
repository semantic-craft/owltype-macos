//! Versioned, synchronous App ABI. Host effects stay outside the pure request dispatcher.
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

const ABI: u32 = 1;
const MAX_REQUEST: usize = 4 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    ClientCapabilities {
        input: Value,
    },
    ResourceRule {
        rule: String,
        args: Value,
    },
    UserDataRule {
        rule: String,
        args: Value,
    },
    ProviderRule {
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
    TemplateValidate {
        library: Value,
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
    QuickEdit {
        entry: Value,
        entries: Vec<Value>,
        editing: Option<String>,
        #[serde(default)]
        delete: bool,
    },
    QuickEditResult {
        #[serde(default)]
        applied: bool,
        #[serde(default)]
        delete: bool,
        editing: Option<String>,
        code: Option<String>,
    },
    QuickEntry {
        entry: Value,
    },
    PromptRule {
        rule: String,
        #[serde(default)]
        args: Value,
    },
    BackupDecode {
        bytes: Vec<u8>,
    },
    WriterNeverTouch {
        name: String,
    },
    UserMigrationLimitations,
    ResourceContract {
        contract: String,
        #[serde(default)]
        args: Value,
    },
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
    TemplateQuoted {
        value: String,
    },
    KeyboardExport {
        kind: String,
        snapshot: owl_app_core::keyboard_export::Snapshot,
        target: Option<owl_app_core::keyboard_export::Target>,
    },
    KeyboardExportPlan {
        snapshot: owl_app_core::keyboard_export::Snapshot,
    },
    KeyboardManagedBlock {
        yaml: String,
        marker: String,
    },
    KeyboardSelection {
        changed: String,
        raw: Value,
    },
    KeyboardRenderManaged {
        original: String,
        marker: String,
        lines: Vec<String>,
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

fn error(code: &str) -> Value {
    json!({"ok": false, "error": code})
}

struct StatelessHost;
impl owl_app_core::storage::Host for StatelessHost {
    fn effect(&mut self, value: Value) -> Result<Value, String> {
        let op = value["operation"].as_str().unwrap_or("");
        match op {
            "uuid" => {
                use std::time::{SystemTime, UNIX_EPOCH};
                let d = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                Ok(json!(format!(
                    "{:08X}-{:04X}-4000-8000-{:012X}",
                    (d & 0xFFFFFFFF) as u32,
                    ((d >> 32) & 0xFFFF) as u16,
                    (d >> 48) as u64 & 0xFFFFFFFFFFFF
                )))
            }
            "case_contains" => {
                let values = value["args"]["values"].as_array();
                let target = value["args"]["value"].as_str().unwrap_or("");
                let found = values.map_or(false, |arr| {
                    arr.iter().any(|v| v.as_str().unwrap_or("").eq_ignore_ascii_case(target))
                });
                Ok(json!(found))
            }
            "localized_contains" => {
                let text = value["args"]["text"].as_str().unwrap_or("").to_lowercase();
                let query = value["args"]["query"].as_str().unwrap_or("").to_lowercase();
                Ok(json!(text.contains(&query)))
            }
            "title_ranks" => {
                let titles = value["args"]["titles"].as_array();
                if let Some(titles) = titles {
                    let mut order: Vec<usize> = (0..titles.len()).collect();
                    order.sort_by(|&a, &b| {
                        let sa = titles[a].as_str().unwrap_or("");
                        let sb = titles[b].as_str().unwrap_or("");
                        sa.cmp(sb)
                    });
                    let mut ranks = vec![0; titles.len()];
                    let mut rank = 0;
                    for (pos, &idx) in order.iter().enumerate() {
                        if pos > 0 {
                            let prev_idx = order[pos - 1];
                            if titles[prev_idx].as_str() != titles[idx].as_str() {
                                rank += 1;
                            }
                        }
                        ranks[idx] = rank;
                    }
                    Ok(json!(ranks))
                } else {
                    Ok(json!([]))
                }
            }
            _ => Err("stateless_host_unsupported_effect".into()),
        }
    }
}

fn dispatch(bytes: &[u8]) -> Value {
    let request: Request = match serde_json::from_slice(bytes) {
        Ok(request) => request,
        Err(_) => return error("invalid_request"),
    };
    let result = match request {
        Request::ClientCapabilities { input } => owl_app_core::client_capability::evaluate(&input),
        Request::ResourceRule { rule, args } => owl_app_core::resource_lifecycle::rule(&rule, args),
        Request::UserDataRule { rule, args } => owl_app_core::user_data::rule(&rule, args),
        Request::ProviderRule { rule, args } => {
            json!({"result": owl_app_core::provider_wire::rule(&rule, args)})
        }
        Request::TemplateSessionRule { rule, args } => {
            owl_app_core::template_session::rule(&rule, args)
        }
        Request::AgentRule { rule, args } => match owl_app_core::agent::rule(&rule, args) {
            Ok(value) => value,
            Err(code) => return error(&code),
        },
        Request::AiRule { rule, args } => owl_app_core::ai_business::rule(&rule, args),
        Request::PureRule { rule, args } => match owl_app_core::pure_rules::dispatch(&rule, args) {
            Ok(value) => value,
            Err(code) => return error(&code),
        },
        Request::TemplateValidate { library } => {
            let lib = match owl_app_core::storage::decode::<owl_app_core::template_library::Library>(library) {
                Ok(l) => l,
                Err(code) => return error(&code),
            };
            match owl_app_core::template_library::validate(&lib) {
                Ok(()) => json!(true),
                Err(code) => return error(&code),
            }
        }
        Request::TemplateDuplicate { entry, new_id } => {
            let e = match owl_app_core::storage::decode::<owl_app_core::template_library::Entry>(entry) {
                Ok(e) => e,
                Err(code) => return error(&code),
            };
            let id = new_id.unwrap_or_else(|| {
                use std::time::{SystemTime, UNIX_EPOCH};
                let d = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                format!(
                    "{:08X}-{:04X}-4000-8000-{:012X}",
                    (d & 0xFFFFFFFF) as u32,
                    ((d >> 32) & 0xFFFF) as u16,
                    (d >> 48) as u64 & 0xFFFFFFFFFFFF
                )
            });
            let mut copy = owl_app_core::template_library::Entry::new(id, e.title + " 副本", e.body);
            copy.body_type = e.body_type;
            copy.syntax = e.syntax;
            copy.tags = e.tags;
            copy.is_pinned = e.is_pinned;
            copy.category = e.category;
            copy.parameters = e.parameters;
            copy.review_state = e.review_state;
            json!(copy)
        }
        Request::TemplateEncode { library } => {
            let lib = match owl_app_core::storage::decode::<owl_app_core::template_library::Library>(library) {
                Ok(l) => l,
                Err(code) => return error(&code),
            };
            match owl_app_core::template_library::encoded(&lib) {
                Ok(bytes) => json!(bytes),
                Err(code) => return error(&code),
            }
        }
        Request::TemplateRule { rule, args } => {
            let mut host = StatelessHost;
            match owl_app_core::template_library::dispatch(&mut host, &rule, args) {
                Ok(value) => value,
                Err(code) => return error(&code),
            }
        }
        Request::QuickEdit {
            entry,
            entries,
            editing,
            delete,
        } => {
            let mut host = StatelessHost;
            let args = json!({
                "entry": entry,
                "entries": entries,
                "editing": editing,
                "delete": delete
            });
            match owl_app_core::quick_send::dispatch(&mut host, "quick_edit", args) {
                Ok(value) => value,
                Err(code) => return error(&code),
            }
        }
        Request::QuickEditResult {
            applied,
            delete,
            editing,
            code,
        } => {
            let mut host = StatelessHost;
            let args = json!({
                "applied": applied,
                "delete": delete,
                "editing": editing,
                "code": code
            });
            match owl_app_core::quick_send::dispatch(&mut host, "quick_edit_result", args) {
                Ok(value) => value,
                Err(code) => return error(&code),
            }
        }
        Request::QuickEntry { entry } => {
            let mut host = StatelessHost;
            let args = json!({ "entry": entry });
            match owl_app_core::quick_send::dispatch(&mut host, "quick_entry", args) {
                Ok(value) => value,
                Err(code) => return error(&code),
            }
        }
        Request::PromptRule { rule, args } => {
            let mut host = StatelessHost;
            match owl_app_core::prompt_store::dispatch(&mut host, &rule, args) {
                Ok(value) => value,
                Err(code) => return error(&code),
            }
        }
        Request::BackupDecode { bytes } => {
            match owl_app_core::template_backup::decode_backup(&bytes) {
                Ok(library) => json!(library),
                Err(code) => return error(&code),
            }
        }
        Request::WriterNeverTouch { name } => {
            json!(owl_app_core::config_writer::never_touch(&name))
        }
        Request::UserMigrationLimitations => {
            let mut host = StatelessHost;
            match owl_app_core::user_data::dispatch(&mut host, "user_migration_limitations", json!({})) {
                Ok(val) => val,
                Err(code) => return error(&code),
            }
        }
        Request::ResourceContract { contract, args } => {
            let op = if contract.starts_with("resource_contract_") {
                contract
            } else {
                format!("resource_contract_{contract}")
            };
            match owl_app_core::resource_contract::dispatch(&op, args) {
                Ok(value) => value,
                Err(code) => return error(&code),
            }
        }
        Request::TemplateReady {
            severities,
            missing_count,
            needs_empty,
        } => json!(owl_app_core::template::ready(
            &severities,
            missing_count,
            needs_empty
        )),
        Request::TemplateLocation { body, location } => {
            json!(owl_app_core::template::location(&body, location))
        }
        Request::TemplateParse {
            body,
            plain,
            legacy,
            pending,
            definitions,
        } => json!(owl_app_core::template::parse(
            &body,
            plain,
            legacy,
            pending,
            definitions
        )),
        Request::TemplateRender {
            parsed,
            values,
            clipboard,
            clipboard_text,
            allow_empty,
            temporal,
        } => json!(owl_app_core::template::render(
            &parsed,
            &values,
            &clipboard,
            clipboard_text.as_deref(),
            allow_empty,
            &temporal
        )),
        Request::TemplateDatePlan {
            field,
            default_pattern,
            date,
        } => json!(owl_app_core::template::date_plan(
            &field,
            default_pattern.as_deref(),
            date
        )),
        Request::TemplateDateOffset {
            current,
            next,
            value,
        } => json!({"error":owl_app_core::template::date_offset(current,next,value)}),
        Request::TemplateDatePattern { pattern, values } => {
            json!(owl_app_core::template::date_pattern(&pattern, &values))
        }
        Request::TemplateQuoted { value } => json!(owl_app_core::template::quoted(&value)),
        Request::KeyboardExport {
            kind,
            snapshot,
            target,
        } => {
            use owl_app_core::keyboard_export::*;
            json!(match kind.as_str() {
                "default" => default_yaml(&snapshot),
                "apps" => app_options_yaml(&snapshot),
                "fuzzy" => fuzzy_yaml(&snapshot),
                "wubi" => match target {
                    Some(target) => wubi_yaml(&snapshot, &target),
                    None => return error("invalid_request"),
                },
                _ => return error("invalid_request"),
            })
        }
        Request::KeyboardExportPlan { snapshot } => owl_app_core::keyboard_export::plan(&snapshot),
        Request::KeyboardManagedBlock { yaml, marker } => {
            owl_app_core::keyboard_export::managed_block(&yaml, &marker)
        }
        Request::KeyboardSelection { changed, raw } => {
            owl_app_core::keyboard::selection(&changed, &raw)
        }
        Request::KeyboardRenderManaged {
            original,
            marker,
            lines,
        } => {
            let Some(rendered) =
                owl_app_core::keyboard_export::render_managed(&original, &marker, &lines)
            else {
                return error("invalid_patch");
            };
            json!(rendered)
        }
        Request::KeyboardOnboarding { schema } => owl_app_core::keyboard::onboarding(&schema),
        Request::KeyboardSchemaMarker {
            preferred,
            selected,
        } => owl_app_core::keyboard::schema_marker(&preferred, selected),
        Request::KeyboardSchemaFailure {
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
        Request::KeyboardCatalog => owl_app_core::keyboard::catalog().clone(),
        Request::KeyboardSchema { schema } => owl_app_core::keyboard::schema(&schema),
        Request::KeyboardEffective { raw } => owl_app_core::keyboard::effective(&raw),
        Request::KeyboardPageSizeWrite { value } => {
            json!(owl_app_core::keyboard::page_size_write(value))
        }
        Request::KeyboardBundleIds { raw } => {
            json!(owl_app_core::keyboard::normalized_bundle_ids(&raw))
        }
        Request::KeyboardFuzzyMask { values } => json!(owl_app_core::keyboard::fuzzy_mask(&values)),
        Request::KeyboardApplication {
            mode,
            recovery_pending,
        } => owl_app_core::keyboard::application(&mode, recovery_pending),
        Request::InitialAsciiMode {
            bundle_id,
            english_bundle_ids,
            default_ascii,
        } => json!(owl_app_core::initial_ascii_mode(
            &bundle_id,
            &english_bundle_ids,
            default_ascii
        )),
        Request::Utf16Range {
            text,
            location,
            length,
        } => {
            let Some(range) = owl_app_core::utf16_range(&text, location, length) else {
                return error("invalid_range");
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

/// Allocation-free equivalent of the core refresh policy for the per-key native hook.
#[no_mangle]
pub extern "C" fn owl_app_keyboard_refresh(pending: u8, composing: u8) -> u32 {
    owl_app_core::keyboard::refresh_decision(pending != 0, composing != 0)
}

#[no_mangle]
pub extern "C" fn owl_app_marked_text_should_send(prev_len: usize, next_len: usize) -> u8 {
    u8::from(owl_app_core::pure_rules::marked_text_resend::should_resend_lengths(prev_len, next_len))
}

#[no_mangle]
pub extern "C" fn owl_app_abi_version() -> u32 {
    ABI
}

/// # Safety
/// A non-null request must point to at least length readable bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn owl_app_call(
    version: u32,
    request: *const u8,
    length: usize,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if version != ABI {
            return error("abi_mismatch");
        }
        if request.is_null() || length == 0 || length > MAX_REQUEST {
            return error("invalid_request");
        }
        // SAFETY: caller contract; no read occurs before validating version, null and size.
        dispatch(unsafe { std::slice::from_raw_parts(request, length) })
    }))
    .unwrap_or_else(|_| error("internal_error"));
    // JSON serialization escapes embedded NULs. Value serialization is infallible here.
    CString::new(response.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}

/// # Safety
/// response is null or an unfreed pointer returned by owl_app_call, never an interior pointer.
#[no_mangle]
pub unsafe extern "C" fn owl_app_string_free(response: *mut c_char) {
    if !response.is_null() {
        drop(unsafe { CString::from_raw(response) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    fn call(version: u32, bytes: &[u8]) -> Value {
        unsafe {
            let pointer = owl_app_call(version, bytes.as_ptr(), bytes.len());
            let value = serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()).unwrap();
            owl_app_string_free(pointer);
            value
        }
    }
    #[test]
    fn rejects_version_bad_payload_and_range_without_echoing_content() {
        assert_eq!(call(2, b"private text"), error("abi_mismatch"));
        assert_eq!(call(1, b"private text"), error("invalid_request"));
        assert_eq!(call(1, &[0xff]), error("invalid_request"));
        assert_eq!(
            call(
                1,
                br#"{"operation":"utf16_range","text":"x","location":2,"length":0}"#
            ),
            error("invalid_range")
        );
        unsafe {
            let result = owl_app_call(1, std::ptr::null(), 0);
            assert_eq!(
                CStr::from_ptr(result).to_str().unwrap(),
                error("invalid_request").to_string()
            );
            owl_app_string_free(result);
            owl_app_string_free(std::ptr::null_mut());
        }
    }
    #[test]
    fn independent_calls_return_owned_buffers() {
        for _ in 0..100 {
            assert_eq!(call(1, br#"{"operation":"initial_ascii_mode","bundle_id":"editor","english_bundle_ids":["editor"],"default_ascii":false}"#)["value"], true);
        }
    }
    #[test]
    fn agent_rules_dispatch_and_return_expected_results() {
        let res = call(
            1,
            br#"{"operation":"agent_rule","rule":"outcome_title","args":{"outcome":"delivered"}}"#,
        );
        assert_eq!(res["ok"], true);
        assert_eq!(res["value"]["title"], "已写入");

        let err = call(
            1,
            br#"{"operation":"agent_rule","rule":"unknown_rule_xyz","args":{}}"#,
        );
        assert_eq!(err["ok"], false);
        assert_eq!(err["error"], "unknown_agent_rule:unknown_rule_xyz");
    }

    #[test]
    fn stateless_ai_and_pure_rules_dispatch_cleanly() {
        // Test pure rule: auto_pair
        let res = call(
            1,
            r#"{"operation":"pure_rule","rule":"auto_pair_decide","args":{"enabled":true,"commit_text":"（","right_neighbor":null,"caret_move_allowed":true}}"#.as_bytes(),
        );
        assert_eq!(res["ok"], true);
        assert_eq!(res["value"]["action"], "pair");
        assert_eq!(res["value"]["open"], "（");
        assert_eq!(res["value"]["close"], "）");

        // Test C-ABI: marked_text_should_send
        assert_eq!(owl_app_marked_text_should_send(0, 0), 0);
        assert_eq!(owl_app_marked_text_should_send(1, 0), 1);
        assert_eq!(owl_app_marked_text_should_send(0, 2), 1);
    }

    #[test]
    fn stateless_in_memory_operations_dispatch_without_host() {
        // Test writer_never_touch
        let res = call(
            1,
            br#"{"operation":"writer_never_touch","name":"user.yaml"}"#,
        );
        assert_eq!(res["ok"], true);
        assert_eq!(res["value"], true);

        let res2 = call(
            1,
            br#"{"operation":"writer_never_touch","name":"custom.yaml"}"#,
        );
        assert_eq!(res2["ok"], true);
        assert_eq!(res2["value"], false);

        // Test user_migration_limitations
        let res3 = call(
            1,
            br#"{"operation":"user_migration_limitations"}"#,
        );
        assert_eq!(res3["ok"], true);
    }
}


/// Synchronous host service. Its returned JSON pointer is borrowed until the next callback
/// (or the end of the enclosing call), never freed by Rust and never retained.
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
            serde_json::from_slice(unsafe { std::ffi::CStr::from_ptr(pointer) }.to_bytes())
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
/// # Safety
/// Input and context are borrowed for this synchronous call; callback follows HostCallback's
/// lifetime contract. No pointer is stored globally or passed to another thread.
#[no_mangle]
pub unsafe extern "C" fn owl_app_storage_call(
    version: u32,
    request: *const u8,
    length: usize,
    context: *mut std::ffi::c_void,
    callback: Option<HostCallback>,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if version != ABI {
            return error("abi_mismatch");
        }
        if request.is_null() || length == 0 || length > isize::MAX as usize {
            return error("invalid_request");
        }
        let Some(callback) = callback else {
            return error("invalid_request");
        };
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct StorageRequest {
            operation: String,
            args: Value,
        }
        let Ok(request) = serde_json::from_slice::<StorageRequest>(unsafe {
            std::slice::from_raw_parts(request, length)
        }) else {
            return error("invalid_request");
        };
        let mut host = NativeHost { context, callback };
        let result = if request.operation.starts_with("resource_") {
            owl_app_core::resource::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("user_") {
            owl_app_core::user_data::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("provider_") {
            owl_app_core::provider_store::dispatch(&mut host, &request.operation, request.args)
                .map(|v| json!({"result":v}))
        } else if request.operation.starts_with("writer_") {
            owl_app_core::config_writer::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("picker_") {
            owl_app_core::picker::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("quick_") {
            owl_app_core::quick_send::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("editor_") {
            owl_app_core::template_editor::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("prompt_") {
            owl_app_core::prompt_store::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("import_") {
            owl_app_core::template_import::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("backup_") {
            owl_app_core::template_backup::dispatch(&mut host, &request.operation, request.args)
        } else if request.operation.starts_with("migration_") {
            owl_app_core::template_migration::dispatch(&mut host, &request.operation, request.args)
        } else {
            owl_app_core::template_library::dispatch(&mut host, &request.operation, request.args)
        };
        match result {
            Ok(value) => json!({"ok":true,"value":value}),
            Err(code) => error(&code),
        }
    }))
    .unwrap_or_else(|_| error("internal_error"));
    CString::new(response.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}

/// # Safety
/// Requests are borrowed readable bytes. Output must point to writable pointer storage.
/// Sessions are uniquely owned and serialized by the caller; no concurrent events/free.
#[no_mangle]
pub unsafe extern "C" fn owl_app_session_new(
    version: u32,
    request: *const u8,
    length: usize,
    output: *mut *mut c_char,
) -> *mut owl_app_core::template_session::Session {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if version != ABI {
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
            json!({"ok":true,"value":true}),
        ),
        Err(code) => (std::ptr::null_mut(), error(&code)),
    };
    if !output.is_null() {
        unsafe {
            *output = CString::new(response.to_string()).unwrap().into_raw();
        }
    }
    session
}
/// # Safety
/// Session and optional index are live owned handles, distinct pointers, serialized by caller.
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
            return error("invalid_request");
        }
        // Library snapshots retain the storage ABI's size semantics. Other session
        // events use the same request bound as the pure dispatcher.
        if length > MAX_REQUEST
            && !matches!(
                unsafe { &*session },
                owl_app_core::template_session::Session::Runtime(_)
            )
        {
            return error("invalid_request");
        }
        let Ok(value) =
            serde_json::from_slice::<Value>(unsafe { std::slice::from_raw_parts(request, length) })
        else {
            return error("invalid_request");
        };
        match unsafe { &mut *session }.event(
            value["event"].as_str().unwrap_or(""),
            value["args"].clone(),
            unsafe { index.as_ref() },
        ) {
            Ok(value) => json!({"ok":true,"value":value}),
            Err(code) => error(&code),
        }
    }))
    .unwrap_or_else(|_| error("internal_error"));
    CString::new(response.to_string()).unwrap().into_raw()
}
/// # Safety
/// NULL or a live uniquely owned session returned by owl_app_session_new, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn owl_app_session_free(
    session: *mut owl_app_core::template_session::Session,
) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}
