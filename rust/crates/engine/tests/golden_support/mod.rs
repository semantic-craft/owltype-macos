//! Support for `tests/golden.rs`. The recorder's JSON shapes are the contract (`tools/engine-golden/recorder.cpp`); this module reproduces them from the Rust engine and compares structurally, so key order and absent-versus-default fields never cause a false diff.

pub mod diff;
pub mod fixture;
pub mod real;
pub mod replay;
pub mod snapshot;

use std::path::PathBuf;

/// `crates/engine/tests/golden`.
pub fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("golden")
}
