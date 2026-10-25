#!/usr/bin/env bash
#
# Build the static universal Rust FFI archive (lib/libowl_msime_ffi.a) and sync
# its C header (include/owl_msime_ffi.h) for Owltype (#249).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOME_DIR="${HOME:-}"
CARGO_HOME_DIR="${CARGO_HOME:-$HOME_DIR/.cargo}"
RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME_DIR/.rustup}"

native_only=0
for arg in "$@"; do
  case "$arg" in
    --native-only)
      native_only=1
      ;;
    *)
      echo "[build-rust-ffi] unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

export MACOSX_DEPLOYMENT_TARGET="14.0"
export RUSTFLAGS="--remap-path-prefix=$REPO_ROOT=. --remap-path-prefix=$HOME_DIR=/build --remap-path-prefix=$CARGO_HOME_DIR=/cargo --remap-path-prefix=$RUSTUP_HOME_DIR=/rustup"
export CFLAGS="-ffile-prefix-map=$REPO_ROOT=. -ffile-prefix-map=$HOME_DIR=/build -ffile-prefix-map=$CARGO_HOME_DIR=/cargo"

manifest_path="$REPO_ROOT/rust/Cargo.toml"
target_dir="$REPO_ROOT/rust/target"
mkdir -p "$REPO_ROOT/lib" "$REPO_ROOT/include"

if (( native_only == 1 )); then
  host_arch="$(uname -m)"
  if [[ "$host_arch" == "arm64" ]]; then
    rust_target="aarch64-apple-darwin"
  else
    rust_target="x86_64-apple-darwin"
  fi
  cargo build \
    --locked \
    --manifest-path "$manifest_path" \
    --package owl-msime-ffi \
    --release \
    --target "$rust_target"
  cp "$target_dir/$rust_target/release/libowl_msime_ffi.a" "$REPO_ROOT/lib/libowl_msime_ffi.a"
else
  for rust_target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build \
      --locked \
      --manifest-path "$manifest_path" \
      --package owl-msime-ffi \
      --release \
      --target "$rust_target"
  done
  lipo -create \
    "$target_dir/aarch64-apple-darwin/release/libowl_msime_ffi.a" \
    "$target_dir/x86_64-apple-darwin/release/libowl_msime_ffi.a" \
    -output "$REPO_ROOT/lib/libowl_msime_ffi.a"
fi

cp "$REPO_ROOT/rust/crates/owl-msime-ffi/include/owl_msime_ffi.h" "$REPO_ROOT/include/owl_msime_ffi.h"

python3 - "$REPO_ROOT/lib/libowl_msime_ffi.a" <<'PYEOF'
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
data = archive.read_bytes()
runner_prefix = b"/" + b"Users/runner/"
if runner_prefix in data:
    data = data.replace(runner_prefix, b"/build/runner/")
    archive.write_bytes(data)
needle = b"/" + b"Users/"
if needle in data:
    idx = data.find(needle)
    snippet = data[max(0, idx - 16):min(len(data), idx + 64)]
    sys.exit(f"[build-rust-ffi] ERROR: home path prefix found in {archive}: {snippet!r}")
print(f"[build-rust-ffi] verified zero home-path strings in {archive} ({len(data)} bytes)")
PYEOF
