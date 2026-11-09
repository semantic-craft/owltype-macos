use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use serde_json::{json, Value};

use crate::session_runtime::{cstr_to_string, error_response, into_c_string_ptr, OwlMsimeSession};
use crate::sessions::{destroy_session, live_sessions, register_session, session_lifecycle, with_session};
use crate::smart_punctuation;

pub(crate) fn store_ffi_error(error_out: *mut *mut c_char, message: &str) {
    if error_out.is_null() {
        return;
    }
    let message = CString::new(message)
        .unwrap_or_else(|_| CString::new("session creation failed").expect("static C string"));
    unsafe {
        *error_out = message.into_raw();
    }
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create(
    pinyin_db_path: *const c_char,
    english_db_path: *const c_char,
    user_data_dir: *const c_char,
    page_size: u32,
) -> *mut OwlMsimeSession {
    catch_unwind(AssertUnwindSafe(|| {
        let _lifecycle = session_lifecycle()
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pinyin = cstr_to_string(pinyin_db_path).unwrap_or_default();
        let english = cstr_to_string(english_db_path).unwrap_or_default();
        let user = cstr_to_string(user_data_dir).unwrap_or_default();
        match OwlMsimeSession::create(&pinyin, &english, &user, page_size) {
            Ok(session) => register_session(session),
            Err(_) => ptr::null_mut(),
        }
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create_with_roots(
    pinyin_db_path: *const c_char,
    english_db_path: *const c_char,
    resources_dir: *const c_char,
    user_data_dir: *const c_char,
    cache_dir: *const c_char,
    dictionaries_dir: *const c_char,
    page_size: u32,
    error_out: *mut *mut c_char,
) -> *mut OwlMsimeSession {
    if !error_out.is_null() {
        unsafe {
            *error_out = ptr::null_mut();
        }
    }
    let lifecycle = session_lifecycle()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let created = catch_unwind(AssertUnwindSafe(|| {
        let pinyin = cstr_to_string(pinyin_db_path).unwrap_or_default();
        let english = cstr_to_string(english_db_path).unwrap_or_default();
        let resources = cstr_to_string(resources_dir).unwrap_or_default();
        let user = cstr_to_string(user_data_dir).unwrap_or_default();
        let cache = cstr_to_string(cache_dir).unwrap_or_default();
        let dictionaries = cstr_to_string(dictionaries_dir).unwrap_or_default();
        OwlMsimeSession::create_with_explicit_roots(
            &pinyin,
            &english,
            &resources,
            &user,
            &cache,
            &dictionaries,
            page_size,
        )
    }));
    let session = match created {
        Ok(Ok(session)) => register_session(session),
        Ok(Err(message)) => {
            store_ffi_error(error_out, &message);
            ptr::null_mut()
        }
        Err(_) => {
            store_ffi_error(error_out, "panic in session creation with explicit roots");
            ptr::null_mut()
        }
    };
    drop(lifecycle);
    session
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create_with_generation(
    resources_dir: *const c_char,
    user_data_dir: *const c_char,
    cache_dir: *const c_char,
    content_id: *const c_char,
    page_size: u32,
    error_out: *mut *mut c_char,
) -> *mut OwlMsimeSession {
    owl_msime_session_create_with_auxiliary_resources(
        resources_dir,
        resources_dir,
        user_data_dir,
        cache_dir,
        content_id,
        page_size,
        error_out,
    )
}

#[no_mangle]
pub extern "C" fn owl_msime_session_create_with_auxiliary_resources(
    resources_dir: *const c_char,
    auxiliary_resources_dir: *const c_char,
    user_data_dir: *const c_char,
    cache_dir: *const c_char,
    content_id: *const c_char,
    page_size: u32,
    error_out: *mut *mut c_char,
) -> *mut OwlMsimeSession {
    if !error_out.is_null() {
        unsafe {
            *error_out = ptr::null_mut();
        }
    }
    let lifecycle = session_lifecycle()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let created = catch_unwind(AssertUnwindSafe(|| {
        let resources = cstr_to_string(resources_dir).unwrap_or_default();
        let user = cstr_to_string(user_data_dir).unwrap_or_default();
        let cache = cstr_to_string(cache_dir).unwrap_or_default();
        let content_id = cstr_to_string(content_id).unwrap_or_default();
        let auxiliary = cstr_to_string(auxiliary_resources_dir).unwrap_or_default();
        OwlMsimeSession::create_with_generation(
            &resources,
            &auxiliary,
            &user,
            &cache,
            &content_id,
            page_size,
        )
    }));
    let session = match created {
        Ok(Ok(session)) => register_session(session),
        Ok(Err(message)) => {
            store_ffi_error(error_out, &message);
            ptr::null_mut()
        }
        Err(_) => {
            store_ffi_error(error_out, "panic in session creation with generation");
            ptr::null_mut()
        }
    };
    drop(lifecycle);
    session
}

#[no_mangle]
pub extern "C" fn owl_msime_session_destroy(session: *mut OwlMsimeSession) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let _lifecycle = session_lifecycle()
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        destroy_session(session);
    }));
}

/// Closes process-wide database caches after every session has been destroyed.
///
/// Returns false without touching any cache while a session is live. Returns true after
/// `msime_engine::close_cached_databases` completes, and is safe to call repeatedly.
#[no_mangle]
pub extern "C" fn owl_msime_engine_finalize() -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let _lifecycle = session_lifecycle()
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let sessions = live_sessions()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !sessions.is_empty() {
            return false;
        }
        msime_engine::close_cached_databases();
        true
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn owl_msime_session_handle_action_json(
    session: *mut OwlMsimeSession,
    action_json: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let response = with_session(session, |session| {
            let Some(action) = cstr_to_string(action_json) else {
                return error_response("action_json is null");
            };
            session.handle_action_json(&action)
        })
        .unwrap_or_else(|| error_response("session is null or destroyed"));
        into_c_string_ptr(&response)
    }))
    .unwrap_or_else(|_| into_c_string_ptr(&error_response("panic in handle_action_json")))
}

#[no_mangle]
pub extern "C" fn owl_msime_session_snapshot_json(session: *const OwlMsimeSession) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let response = with_session(session, |session| session.snapshot())
            .unwrap_or_else(|| error_response("session is null or destroyed"));
        into_c_string_ptr(&response)
    }))
    .unwrap_or_else(|_| into_c_string_ptr(&error_response("panic in snapshot_json")))
}

fn rerank_response(
    session: *const OwlMsimeSession,
    operation: impl FnOnce(&mut OwlMsimeSession) -> Value,
) -> *mut c_char {
    let response = with_session(session, operation)
        .unwrap_or_else(|| json!({"ok": false, "error": "session is null or destroyed"}));
    into_c_string_ptr(&response)
}

#[no_mangle]
pub extern "C" fn owl_msime_session_configure_rerank_json(
    session: *mut OwlMsimeSession,
    config_json: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        rerank_response(session, |session| {
            let Some(config) = cstr_to_string(config_json) else {
                return json!({"ok": false, "error": "config_json is null"});
            };
            session.configure_rerank(&config)
        })
    }))
    .unwrap_or_else(|_| {
        into_c_string_ptr(&json!({"ok": false, "error": "panic in configure_rerank_json"}))
    })
}

#[no_mangle]
pub extern "C" fn owl_msime_session_rerank_status_json(
    session: *mut OwlMsimeSession,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        rerank_response(session, OwlMsimeSession::rerank_status)
    }))
    .unwrap_or_else(|_| {
        into_c_string_ptr(&json!({"ok": false, "error": "panic in rerank_status_json"}))
    })
}

#[no_mangle]
pub extern "C" fn owl_msime_session_start_settled_rerank_json(
    session: *mut OwlMsimeSession,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| rerank_response(session, OwlMsimeSession::start_settled_rerank)))
        .unwrap_or_else(|_| into_c_string_ptr(&json!({"status": "done", "current": false, "moved": false, "error": "panic in start_settled_rerank_json"})))
}

#[no_mangle]
pub extern "C" fn owl_msime_session_poll_settled_rerank_json(
    session: *mut OwlMsimeSession,
    token: u64,
    accept: bool,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| rerank_response(session, |session| session.poll_settled_rerank(token, accept))))
        .unwrap_or_else(|_| into_c_string_ptr(&json!({"status": "done", "current": false, "moved": false, "error": "panic in poll_settled_rerank_json"})))
}

/// Stateless transport for the pinned host punctuation policy.
#[no_mangle]
pub extern "C" fn owl_msime_smart_punctuation_json(request: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return std::ptr::null_mut();
        }
        let Ok(request) = (unsafe { CStr::from_ptr(request) }).to_str() else {
            return std::ptr::null_mut();
        };
        let Ok(request) = serde_json::from_str::<Value>(request) else {
            return std::ptr::null_mut();
        };
        into_c_string_ptr(&smart_punctuation::dispatch(&request))
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Convert a JSON string using the pinned upstream OpenCC standard configuration.
/// Returns an owned UTF-8 string, or null for invalid input/panic.
#[no_mangle]
pub extern "C" fn owl_msime_simplified_to_traditional_json(text: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if text.is_null() {
            return std::ptr::null_mut();
        }
        let Ok(text) = (unsafe { CStr::from_ptr(text) }).to_str() else {
            return std::ptr::null_mut();
        };
        let Ok(text) = serde_json::from_str::<String>(text) else {
            return std::ptr::null_mut();
        };
        into_c_string_ptr(&msime_client_core::chinese_conversion::simplified_to_traditional(&text))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn owl_msime_string_free(ptr: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !ptr.is_null() {
            unsafe {
                drop(CString::from_raw(ptr));
            }
        }
    }));
}
