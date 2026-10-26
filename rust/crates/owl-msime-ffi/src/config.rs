#![allow(unsafe_code)]

use std::collections::BTreeMap;
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr;

use yaml_rust2::yaml::Hash;
use yaml_rust2::{Yaml, YamlLoader};

#[derive(Debug)]
pub struct OwlMsimeConfig {
    root: Yaml,
}

impl OwlMsimeConfig {
    fn open(base_path: &Path, patch_path: &Path) -> Result<Self, String> {
        let base = load_document(base_path, true)?
            .ok_or_else(|| format!("base config is empty: {}", base_path.display()))?;
        let mut root = normalize_slashes(base);

        if let Some(patch_document) = load_document(patch_path, false)? {
            let patch = patch_body(&patch_document, patch_path)?;
            overlay(&mut root, &patch);
        }

        Ok(Self { root })
    }

    fn node(&self, path: &str) -> Option<&Yaml> {
        let mut node = &self.root;
        for component in path.split('/').filter(|component| !component.is_empty()) {
            node = map_get(node, component)?;
        }
        Some(node)
    }

    fn get_bool(&self, path: &str) -> Option<bool> {
        self.node(path).and_then(|node| match node {
            Yaml::Boolean(value) => Some(*value),
            _ => None,
        })
    }

    fn get_double(&self, path: &str) -> Option<f64> {
        self.node(path).and_then(|node| match node {
            Yaml::Real(value) => value.parse().ok(),
            Yaml::Integer(value) => Some(*value as f64),
            _ => None,
        })
    }

    fn get_string(&self, path: &str) -> Option<String> {
        self.node(path).and_then(|node| match node {
            Yaml::String(value) => Some(value.clone()),
            Yaml::Boolean(value) => Some(value.to_string()),
            Yaml::Integer(value) => Some(value.to_string()),
            Yaml::Real(value) => Some(value.clone()),
            _ => None,
        })
    }

    fn has_map(&self, path: &str) -> bool {
        matches!(self.node(path), Some(Yaml::Hash(_)))
    }

    fn app_options_json(&self, bundle_id: &str) -> String {
        let path = format!("app_options/{bundle_id}");
        let mut options = BTreeMap::new();
        if let Some(Yaml::Hash(values)) = self.node(&path) {
            for (key, value) in values {
                let (Yaml::String(key), Yaml::Boolean(value)) = (key, value) else {
                    continue;
                };
                options.insert(key.clone(), *value);
            }
        }
        serde_json::to_string(&options).expect("serializing a string-to-bool map cannot fail")
    }
}

fn load_document(path: &Path, required: bool) -> Result<Option<Yaml>, String> {
    let source = match fs::read_to_string(path) {
        Ok(source) => source,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && !required => {
            return Ok(None);
        }
        Err(error) => {
            return Err(format!("cannot read {}: {error}", path.display()));
        }
    };
    let documents = YamlLoader::load_from_str(&source)
        .map_err(|error| format!("invalid YAML in {}: {error}", path.display()))?;
    match documents.as_slice() {
        [] => Ok(None),
        [Yaml::BadValue] => Ok(None),
        [document] => Ok(Some(document.clone())),
        _ => Err(format!(
            "{} must contain exactly one YAML document",
            path.display()
        )),
    }
}

fn patch_body(document: &Yaml, path: &Path) -> Result<Yaml, String> {
    let Yaml::Hash(root) = document else {
        return Err(format!("{} must contain a patch map", path.display()));
    };
    let Some(patch) = root.get(&Yaml::String("patch".to_owned())) else {
        return Err(format!("{} is missing the root patch map", path.display()));
    };
    let Yaml::Hash(_) = patch else {
        return Err(format!("{} patch must be a map", path.display()));
    };
    Ok(normalize_slashes(patch.clone()))
}

fn normalize_slashes(node: Yaml) -> Yaml {
    match node {
        Yaml::Hash(values) => {
            let mut normalized = Hash::new();
            for (key, value) in values {
                let value = normalize_slashes(value);
                let Yaml::String(path) = key else {
                    insert_normalized(&mut normalized, key, value);
                    continue;
                };
                insert_path(&mut normalized, &path, value);
            }
            Yaml::Hash(normalized)
        }
        Yaml::Array(values) => Yaml::Array(values.into_iter().map(normalize_slashes).collect()),
        scalar => scalar,
    }
}

fn insert_path(root: &mut Hash, path: &str, value: Yaml) {
    let components = path
        .split('/')
        .filter(|component| !component.is_empty())
        .collect::<Vec<_>>();
    if components.len() <= 1 {
        insert_normalized(root, Yaml::String(path.to_owned()), value);
        return;
    }

    let mut current = root;
    for component in &components[..components.len() - 1] {
        let key = Yaml::String((*component).to_owned());
        let entry = current
            .entry(key)
            .or_insert_with(|| Yaml::Hash(Hash::new()));
        if !matches!(entry, Yaml::Hash(_)) {
            *entry = Yaml::Hash(Hash::new());
        }
        let Yaml::Hash(next) = entry else {
            unreachable!("entry was just made a map");
        };
        current = next;
    }
    insert_normalized(
        current,
        Yaml::String(components.last().expect("non-empty path").to_string()),
        value,
    );
}

fn insert_normalized(root: &mut Hash, key: Yaml, value: Yaml) {
    if let Yaml::Hash(children) = value {
        let entry = root.entry(key).or_insert_with(|| Yaml::Hash(Hash::new()));
        if !matches!(entry, Yaml::Hash(_)) {
            *entry = Yaml::Hash(Hash::new());
        }
        let Yaml::Hash(target) = entry else {
            unreachable!("entry was just made a map");
        };
        for (child_key, child_value) in children {
            insert_normalized(target, child_key, child_value);
        }
    } else {
        root.insert(key, value);
    }
}

fn overlay(base: &mut Yaml, patch: &Yaml) {
    let replacement = patch.clone();
    let (Yaml::Hash(base), Yaml::Hash(patch)) = (&mut *base, patch) else {
        *base = replacement;
        return;
    };
    for (key, patch_value) in patch {
        if let (Some(Yaml::Hash(_)), Yaml::Hash(_)) = (base.get(key), patch_value) {
            let base_value = base
                .get_mut(key)
                .expect("the matching base key was just found");
            overlay(base_value, patch_value);
        } else {
            base.insert(key.clone(), patch_value.clone());
        }
    }
}

fn map_get<'a>(node: &'a Yaml, key: &str) -> Option<&'a Yaml> {
    match node {
        Yaml::Hash(values) => values.get(&Yaml::String(key.to_owned())),
        _ => None,
    }
}

fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned(),
    )
}

fn allocated_error(message: impl Into<String>, error_out: *mut *mut c_char) -> *mut OwlMsimeConfig {
    if !error_out.is_null() {
        let message = CString::new(message.into())
            .unwrap_or_else(|_| CString::new("config error").expect("static string"));
        unsafe {
            *error_out = message.into_raw();
        }
    }
    ptr::null_mut()
}

fn clear_error(error_out: *mut *mut c_char) {
    if !error_out.is_null() {
        unsafe {
            *error_out = ptr::null_mut();
        }
    }
}

#[no_mangle]
pub extern "C" fn owl_msime_config_open(
    base_path: *const c_char,
    patch_path: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut OwlMsimeConfig {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let Some(base_path) = cstr_to_string(base_path) else {
            return allocated_error("base config path is null", error_out);
        };
        let patch_path = cstr_to_string(patch_path).unwrap_or_else(|| String::from("/nonexistent"));
        match OwlMsimeConfig::open(Path::new(&base_path), Path::new(&patch_path)) {
            Ok(config) => {
                clear_error(error_out);
                Box::into_raw(Box::new(config))
            }
            Err(error) => allocated_error(error, error_out),
        }
    }));
    result.unwrap_or_else(|_| allocated_error("config open panicked", error_out))
}

#[no_mangle]
pub extern "C" fn owl_msime_config_destroy(config: *mut OwlMsimeConfig) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !config.is_null() {
            unsafe {
                drop(Box::from_raw(config));
            }
        }
    }));
}

#[no_mangle]
pub extern "C" fn owl_msime_config_get_bool(
    config: *const OwlMsimeConfig,
    path: *const c_char,
    value_out: *mut bool,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(config) = (unsafe { config.as_ref() }) else {
            return false;
        };
        let Some(path) = cstr_to_string(path) else {
            return false;
        };
        let Some(value) = config.get_bool(&path) else {
            return false;
        };
        if !value_out.is_null() {
            unsafe {
                *value_out = value;
            }
        }
        true
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn owl_msime_config_get_double(
    config: *const OwlMsimeConfig,
    path: *const c_char,
    value_out: *mut f64,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(config) = (unsafe { config.as_ref() }) else {
            return false;
        };
        let Some(path) = cstr_to_string(path) else {
            return false;
        };
        let Some(value) = config.get_double(&path) else {
            return false;
        };
        if !value_out.is_null() {
            unsafe {
                *value_out = value;
            }
        }
        true
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn owl_msime_config_get_string(
    config: *const OwlMsimeConfig,
    path: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(config) = (unsafe { config.as_ref() }) else {
            return ptr::null_mut();
        };
        let Some(path) = cstr_to_string(path) else {
            return ptr::null_mut();
        };
        config
            .get_string(&path)
            .and_then(|value| CString::new(value).ok())
            .map_or(ptr::null_mut(), CString::into_raw)
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn owl_msime_config_has_map(
    config: *const OwlMsimeConfig,
    path: *const c_char,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(config) = (unsafe { config.as_ref() }) else {
            return false;
        };
        let Some(path) = cstr_to_string(path) else {
            return false;
        };
        config.has_map(&path)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn owl_msime_config_app_options_json(
    config: *const OwlMsimeConfig,
    bundle_id: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(config) = (unsafe { config.as_ref() }) else {
            return ptr::null_mut();
        };
        let Some(bundle_id) = cstr_to_string(bundle_id) else {
            return ptr::null_mut();
        };
        CString::new(config.app_options_json(&bundle_id)).map_or(ptr::null_mut(), CString::into_raw)
    }))
    .unwrap_or(ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn config_with(base: &str, patch: &str) -> OwlMsimeConfig {
        let directory = TempDir::new().unwrap();
        let base_path = directory.path().join("owltype.yaml");
        let patch_path = directory.path().join("owltype.custom.yaml");
        fs::write(&base_path, base).unwrap();
        fs::write(&patch_path, patch).unwrap();
        OwlMsimeConfig::open(&base_path, &patch_path).unwrap()
    }

    #[test]
    fn overlays_flat_and_nested_paths_including_app_options() {
        let config = config_with(
            r#"
keyboard_layout: last
style:
  inline_preedit: false
  inline_candidate: false
app_options:
  com.example.App:
    ascii_mode: false
"#,
            r#"
patch:
  # comments, anchors and typed scalars
  defaults: &defaults
    text_orientation: vertical
  style: *defaults
  style/inline_preedit: true
  "app_options/com.example.App/ascii_mode": true
  "app_options/com.example.Other/ascii_mode": true
"#,
        );

        assert_eq!(
            config.get_string("keyboard_layout").as_deref(),
            Some("last")
        );
        assert_eq!(
            config.get_string("style/text_orientation").as_deref(),
            Some("vertical")
        );
        assert_eq!(config.get_bool("style/inline_preedit"), Some(true));
        assert_eq!(config.get_bool("style/inline_candidate"), Some(false));
        let options: BTreeMap<String, bool> =
            serde_json::from_str(&config.app_options_json("com.example.App")).unwrap();
        assert_eq!(options.get("ascii_mode"), Some(&true));
    }

    #[test]
    fn custom_patch_body_merges_nested_maps_and_empty_patch_is_valid() {
        let config = config_with(
            r#"
style:
  inline_preedit: false
  inline_candidate: false
chord_duration: 0.1
"#,
            r#"
patch:
  style:
    inline_candidate: true
  chord_duration: 0.25
"#,
        );
        assert_eq!(config.get_bool("style/inline_preedit"), Some(false));
        assert_eq!(config.get_bool("style/inline_candidate"), Some(true));
        assert_eq!(config.get_double("chord_duration"), Some(0.25));

        let empty = config_with("style: {}\n", "patch: {}\n");
        assert!(empty.has_map("style"));
    }

    #[test]
    fn schema_overlay_replaces_scalars_without_losing_global_sections() {
        let config = config_with(
            r#"
style:
  candidate_list_layout: stacked
  text_orientation: horizontal
  inline_preedit: true
"#,
            r#"
patch:
  style/text_orientation: vertical
  style/inline_preedit: false
"#,
        );
        assert_eq!(
            config.get_string("style/candidate_list_layout").as_deref(),
            Some("stacked")
        );
        assert_eq!(
            config.get_string("style/text_orientation").as_deref(),
            Some("vertical")
        );
        assert_eq!(config.get_bool("style/inline_preedit"), Some(false));
    }

    #[test]
    fn missing_patch_is_allowed_but_missing_or_invalid_base_is_reported() {
        let directory = TempDir::new().unwrap();
        let base = directory.path().join("owltype.yaml");
        let patch = directory.path().join("missing.custom.yaml");
        fs::write(&base, "style: {}\n").unwrap();
        assert!(OwlMsimeConfig::open(&base, &patch).is_ok());

        let missing = OwlMsimeConfig::open(&directory.path().join("missing.yaml"), &patch);
        assert!(missing.unwrap_err().contains("cannot read"));

        fs::write(&base, "style: [\n").unwrap();
        let malformed = OwlMsimeConfig::open(&base, &patch);
        assert!(malformed.unwrap_err().contains("invalid YAML"));
    }

    #[test]
    fn patch_must_have_a_mapping_body_and_typed_getters_do_not_coerce() {
        let config = config_with("style:\n  inline_preedit: false\n", "patch: {}\n");
        assert!(config
            .node("style/inline_preedit")
            .is_some_and(|value| matches!(value, Yaml::Boolean(false))));

        let directory = TempDir::new().unwrap();
        let base = directory.path().join("base.yaml");
        let patch = directory.path().join("patch.yaml");
        fs::write(&base, "style: {}\n").unwrap();
        fs::write(&patch, "style/inline_preedit: true\n").unwrap();
        let invalid = OwlMsimeConfig::open(&base, &patch);
        assert!(invalid.unwrap_err().contains("root patch map"));

        fs::write(&base, "value: text\n").unwrap();
        fs::write(&patch, "patch:\n  value: true\n").unwrap();
        let config = OwlMsimeConfig::open(&base, &patch).unwrap();
        assert_eq!(config.get_bool("value"), Some(true));
        assert_eq!(config.get_string("value").as_deref(), Some("true"));
        assert_eq!(config.get_double("value"), None);
    }
}
