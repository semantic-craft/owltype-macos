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

fn dispatch(bytes: &[u8]) -> Value {
    let request: Request = match serde_json::from_slice(bytes) {
        Ok(request) => request,
        Err(_) => return error("invalid_request"),
    };
    let result = match request {
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

/// Allocation-free equivalent of the core refresh policy for the per-key native hook.
#[no_mangle]
pub extern "C" fn owl_app_keyboard_refresh(pending: u8, composing: u8) -> u32 {
    owl_app_core::keyboard::refresh_decision(pending != 0, composing != 0)
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
}
