//! Binary-owned compatible resource set and model metadata.
//! Pinned Wubi identity: dict-v2.0.39: both official 86/98 tables.
use serde_json::Value;

pub fn catalog() -> Value {
    serde_json::from_str(include_str!("resource_catalog.json")).expect("bundled catalog")
}
