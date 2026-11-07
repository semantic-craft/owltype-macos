//! Keyboard policy. The host supplies raw preferences and executes returned effects.
use serde_json::{json, Value};
use std::sync::OnceLock;

fn source_catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("keyboard_catalog.json")).expect("keyboard catalog")
    })
}

pub fn schema(id: &str) -> Value {
    let mut result = source_catalog()["schemas"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == id)
        .cloned()
        .unwrap_or_else(|| json!({"id": id, "name": id}));
    let double = match id {
        "double_pinyin_flypy" => "xiaohe",
        "double_pinyin_mspy" => "microsoft",
        "double_pinyin_shoudao" => "shoudao",
        "double_pinyin" => "ziranma",
        "double_pinyin_abc" => "abc",
        "double_pinyin_sogou" | "double_pinyin_ziguang" | "double_pinyin_jiajia" => "custom",
        _ => "quanpin",
    };
    let pinyin = match id {
        "wubi86_jidian_pinyin"
        | "wubi86_jidian_trad_pinyin"
        | "wubi98_pinyin"
        | "wubi98_trad_pinyin" => "wubi_pinyin",
        "wubi86_jidian" | "wubi86_jidian_trad" | "wubi98" | "wubi98_trad" => "wubi",
        _ => double,
    };
    result["validConfigID"] =
        json!(!id.is_empty() && !id.starts_with('.') && !id.contains('/') && !id.contains(".."));
    result["inputMode"] = json!(if id.starts_with("wubi") {
        "wubi"
    } else {
        "chinese"
    });
    result["wubiProfile"] = json!(if id.starts_with("wubi98") {
        "wubi98"
    } else {
        "wubi86"
    });
    result["doublePinyinScheme"] = json!(double);
    result["pinyinScheme"] = json!(pinyin);
    result["traditional"] = json!(matches!(
        id,
        "wubi86_jidian_trad" | "wubi86_jidian_trad_pinyin" | "wubi98_trad" | "wubi98_trad_pinyin"
    ));
    result
}

pub fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(build_catalog)
}

fn build_catalog() -> Value {
    let mut value = source_catalog().clone();
    value["schemas"] = value["schemas"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| schema(row["id"].as_str().unwrap()))
        .collect();
    value["exportTargets"] = source_catalog()["schemas"].as_array().unwrap().iter()
      .filter(|row| row["id"].as_str().unwrap().starts_with("wubi86"))
      .map(|row| json!({"schemaID":row["id"],"fileName":format!("{}.custom.yaml",row["id"].as_str().unwrap()),"displayName":row["name"]})).collect();
    value["doublePinyinSchemas"] = json!({"flypy":"double_pinyin_flypy", "mspy":"double_pinyin_mspy", "shoudao":"double_pinyin_shoudao", "ziranma":"double_pinyin", "sogou":"double_pinyin_sogou", "abc":"double_pinyin_abc", "ziguang":"double_pinyin_ziguang", "jiajia":"double_pinyin_jiajia"});
    value["wubiSchemas"] = json!({"jidian86":"wubi86_jidian", "pinyinMix":"wubi86_jidian_pinyin", "jidian98":"wubi98", "pinyinMix98":"wubi98_pinyin"});
    value["candidateFilters"] = json!({"normal":null, "singleFirst":"lua_filter@*wubi86_jidian_single_char_first_filter", "singleOnly":"lua_filter@*wubi86_jidian_single_char_only"});
    value
}

pub fn effective(raw: &Value) -> Value {
    let input = match raw["inputMethod"].as_str().unwrap_or("") {
        "doublePinyin" => "doublePinyin",
        "wubi" | "wubi86" | "wubiPinyin" => "wubi",
        _ => "pinyin",
    };
    let wubi = match raw["wubiScheme"].as_str().unwrap_or("") {
        "jidian86" => "jidian86",
        "pinyinMix" => "pinyinMix",
        "jidian98" => "jidian98",
        "pinyinMix98" => "pinyinMix98",
        _ if raw["inputMethod"] == "wubiPinyin" => "pinyinMix",
        _ => "jidian86",
    };
    let double = match raw["doublePinyin"].as_str().unwrap_or("") {
        "mspy" => "mspy",
        "shoudao" => "shoudao",
        "ziranma" => "ziranma",
        "sogou" => "sogou",
        "abc" => "abc",
        "ziguang" => "ziguang",
        "jiajia" => "jiajia",
        _ => "flypy",
    };
    let candidate = match raw["candidateMode"].as_str().unwrap_or("") {
        "singleFirst" => "singleFirst",
        "singleOnly" => "singleOnly",
        _ => "normal",
    };
    let stored_page = raw["pageSize"].as_i64().unwrap_or(0);
    let page = if stored_page == 0 {
        4
    } else {
        stored_page.clamp(3, 9)
    };
    let catalog = catalog();
    let preferred = match input {
        "doublePinyin" => catalog["doublePinyinSchemas"][double].as_str().unwrap(),
        "wubi" => catalog["wubiSchemas"][wubi].as_str().unwrap(),
        _ => "rime_ice",
    };
    json!({"inputMethod":input,"wubiScheme":wubi,"doublePinyin":double,"candidateMode":candidate,"pageSize":page,"preferredSchemaID":preferred})
}

pub fn page_size_write(value: i64) -> i64 {
    value.clamp(3, 9)
}

pub fn normalized_bundle_ids(raw: &str) -> Vec<String> {
    let mut result = Vec::new();
    for value in raw.split([',', ';', '\n', '\r', '\t', ' ']) {
        if !value.is_empty()
            && value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-._".contains(&c))
            && !result.iter().any(|existing| existing == value)
        {
            result.push(value.to_owned());
        }
    }
    result
}

pub fn fuzzy_mask(values: &[bool]) -> u32 {
    // UI order is zh/z, ch/c, sh/s, n/l, r/l, f/h, an/ang, en/eng, in/ing.
    [0, 1, 2, 3, 5, 4, 6, 7, 8]
        .iter()
        .zip(values)
        .fold(
            0,
            |mask, (bit, enabled)| {
                if *enabled {
                    mask | (1 << bit)
                } else {
                    mask
                }
            },
        )
}

pub fn application(mode: &str, recovery_pending: bool) -> Value {
    if recovery_pending {
        return json!({"blocked":true,"effects":[]});
    }
    let effects = if mode == "fuzzy" {
        vec!["maintenance", "join_if_succeeded", "refresh"]
    } else {
        vec!["deploy", "refresh"]
    };
    json!({"blocked":false,"effects":effects})
}

/// Pending work belongs to the host's completion queue; Rust decides when it may execute.
pub fn refresh_decision(pending: bool, composing: bool) -> u32 {
    match (pending, composing) {
        (false, _) => 0,
        (true, true) => 1,
        (true, false) => 2,
    }
}

/// Rebuilding an engine cannot replay partially selected phrase progress from raw input.
pub fn can_apply(requires_idle: bool, composing: bool) -> bool {
    !requires_idle || !composing
}

pub fn selection(changed: &str, raw: &Value) -> Value {
    let effective = effective(raw);
    let applies = changed == "inputMethod"
        || (changed == "doublePinyin" && effective["inputMethod"] == "doublePinyin")
        || (changed == "wubiScheme" && effective["inputMethod"] == "wubi");
    json!({"schema": if applies { effective["preferredSchemaID"].clone() } else { Value::Null }})
}

/// Onboarding writes only the choices represented by its three existing rows.
pub fn onboarding(schema: &str) -> Value {
    match schema {
        "wubi86_jidian" => {
            json!({"OwlKeyboardInputMethod":"wubi", "OwlKeyboardWubiScheme":"jidian86"})
        }
        "double_pinyin" => {
            json!({"OwlKeyboardInputMethod":"doublePinyin", "OwlKeyboardDoublePinyin":"ziranma"})
        }
        _ => json!({"OwlKeyboardInputMethod":"pinyin"}),
    }
}

pub fn schema_idle_action(current_matches: bool, failed_matches: bool) -> u32 {
    if current_matches {
        0
    } else if failed_matches {
        2
    } else {
        1
    }
}

pub fn schema_marker(preferred: &str, selected: bool) -> Value {
    json!({"schema": if selected { None } else { Some(preferred) }})
}

pub fn schema_failure(
    requested: &str,
    engine_selected: bool,
    live_result: &str,
    failed_schema: &str,
) -> Value {
    let failed = if requested.is_empty() {
        None
    } else {
        match live_result {
            "ok" => None,
            "failed" => Some(failed_schema),
            _ if engine_selected => None,
            _ => Some(requested),
        }
    };
    json!({"schema":failed})
}
