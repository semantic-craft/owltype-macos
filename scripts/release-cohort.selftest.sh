#!/usr/bin/env bash
# Cohort identity regression tests. All artifacts and command adapters are throwaway fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$ROOT/scripts/inventory-release-bundle.py"
COHORT_STATE="$ROOT/scripts/release-cohort-state.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/famo-cohort-selftest.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
output="$work/output"

ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

expect_fail() {
  local label="$1" expected="$2"
  shift 2
  if "$@" >"$output" 2>&1; then
    bad "$label"
  elif grep -qF "$expected" "$output"; then
    ok "$label"
  else
    sed 's/^/     /' "$output" >&2
    bad "$label (missing diagnostic: $expected)"
  fi
}

if PYTHONPATH="$ROOT/scripts" python3 - "$INVENTORY" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("inventory_release_bundle", sys.argv[1])
assert spec is not None and spec.loader is not None
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)

assert inventory.format_utc_timestamp("2026-08-11T16:09:47Z") == "2026-08-11T16:09:47Z"
assert inventory.format_utc_timestamp("2026-08-12T00:09:47+08:00") == "2026-08-11T16:09:47Z"
PY
then
  ok "inventory accepts ISO-8601 UTC designators and explicit offsets"
else
  bad "inventory must normalize valid Git commit timestamps"
fi

fake_bin="$work/fake-bin"
build_log="$work/xcodebuild-invocations"
mkdir -p "$fake_bin"
cat >"$fake_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# Fake App fixtures are deliberately not stapled.
exit 1
STUB
cat >"$fake_bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected build\n' >>"${BUILD_LOG:?}"
exit 90
STUB
chmod +x "$fake_bin/xcrun" "$fake_bin/xcodebuild"

cohort_root="$work/custom output root"
app="$cohort_root/Build/Products/Release/Famo.app"
plist="$app/Contents/Info.plist"
payload="$app/Contents/MacOS/Famo"
state="$cohort_root/release/FAMOTYPE-RELEASE-COHORT.json"
mkdir -p "$(dirname "$plist")" "$(dirname "$payload")"
mkdir -p "$app/Contents/SharedSupport"
printf 'fixture seed\n' >"$app/Contents/SharedSupport/seed.txt"

write_version() {
  python3 - "$plist" "$1" "${2:-$1}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": "im.famo.inputmethod.Famo",
            "CFBundleShortVersionString": sys.argv[2],
            "CFBundleVersion": sys.argv[3],
        },
        handle,
    )
PY
}

record_cohort() {
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" record "$cohort_root" >"$output" 2>&1
}

initialize_cohort() {
  python3 "$COHORT_STATE" initialize "$cohort_root" >"$output" 2>&1
}

write_version "9.8.7"
printf 'fake executable\n' >"$payload"
chmod +x "$payload"

make_trace="$work/make-trace"
if make -C "$ROOT" --no-print-directory -n release-artifacts \
    DEPS_CHECK= DEV_ID= RELEASE_OUTPUT_ROOT="$cohort_root" >"$make_trace" 2>&1 &&
   grep -qF -- "-derivedDataPath \"$cohort_root\"" "$make_trace" &&
   grep -qF "copy-famo-seed FAMO_CONFIG=Release DERIVED_DATA_PATH=\"$cohort_root\"" "$make_trace" &&
   grep -qF "\"$cohort_root/Build/Products/Release/Famo.app\"" "$make_trace" &&
   [[ "$(grep -cF "inventory-release-bundle.py record \"$cohort_root\"" "$make_trace")" -eq 1 ]] &&
   grep -qF "release-cohort-state.py initialize \"$cohort_root\"" "$make_trace" &&
   grep -qF "bash package/make_package \"$cohort_root\"" "$make_trace" &&
   grep -qF "bash package/make_dmg \"$cohort_root\"" "$make_trace" &&
   grep -qF "bash package/make_archive" "$make_trace"; then
  ok "Make propagates one custom output root through release and packaging boundaries"
else
  sed 's/^/     /' "$make_trace" >&2
  bad "Make must propagate the custom output root without a second release record"
fi

if initialize_cohort && record_cohort && [[ -s "$state" ]]; then
  ok "fake App records a cohort under a custom output root"
else
  sed 's/^/     /' "$output" >&2
  bad "fake App should record a cohort under a custom output root"
fi

if PYTHONPATH="$ROOT/scripts" python3 - "$work" <<'PY'
import os
import sys
from pathlib import Path

from famo_bundle import artifact_sha256

root = Path(sys.argv[1])
one = root / "hash-boundary-one"
two = root / "hash-boundary-two"
one.mkdir()
two.mkdir()
(one / "a").write_bytes(b"X\0F\0b\0" + b"0644\0Y")
(two / "a").write_bytes(b"X")
(two / "b").write_bytes(b"Y")
for path in (one / "a", two / "a", two / "b"):
    os.chmod(path, 0o644)
assert artifact_sha256(one) != artifact_sha256(two)
PY
then
  ok "bundle identity is prefix-free across file entry boundaries"
else
  bad "bundle identity must not collide when content mimics a following entry header"
fi

chmod a-x "$payload"
expect_fail "chmod-only executable-bit removal rejects the cohort inventory" \
  "release App executable is not executable" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$cohort_root"
chmod +x "$payload"
record_cohort

invalid_app_root="$work/invalid executable output root"
invalid_app="$invalid_app_root/Build/Products/Release/Famo.app"
mkdir -p "$invalid_app/Contents/MacOS"
cp "$plist" "$invalid_app/Contents/Info.plist"
ln -s ../Info.plist "$invalid_app/Contents/MacOS/Famo"
expect_fail "non-regular App executable is rejected at cohort initialization" \
  "release App executable is not a regular file" \
  python3 "$COHORT_STATE" initialize "$invalid_app_root"

symlink_app_root="$work/symlink App output root"
symlink_app_target="$work/symlink App target/Famo.app"
mkdir -p "$symlink_app_root/Build/Products/Release" \
  "$symlink_app_target/Contents/MacOS" "$symlink_app_target/Contents/SharedSupport"
cp "$plist" "$symlink_app_target/Contents/Info.plist"
printf 'symlink target executable\n' >"$symlink_app_target/Contents/MacOS/Famo"
chmod +x "$symlink_app_target/Contents/MacOS/Famo"
printf 'symlink target seed\n' >"$symlink_app_target/Contents/SharedSupport/seed.txt"
ln -s "$symlink_app_target" "$symlink_app_root/Build/Products/Release/Famo.app"
expect_fail "symlink App root is rejected at cohort initialization" \
  "release App root is not a regular directory" \
  python3 "$COHORT_STATE" initialize "$symlink_app_root"

before="$(shasum -a 256 "$state" | awk '{print $1}')"
if env BUILD_LOG="$build_log" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    make -C "$ROOT" --no-print-directory release-cohort-check \
      RELEASE_OUTPUT_ROOT="$cohort_root" >"$output" 2>&1 &&
   env BUILD_LOG="$build_log" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    make -C "$ROOT" --no-print-directory release-cohort-check \
      RELEASE_OUTPUT_ROOT="$cohort_root" >>"$output" 2>&1 &&
   [[ ! -e "$build_log" ]] &&
   [[ "$before" == "$(shasum -a 256 "$state" | awk '{print $1}')" ]]; then
  ok "repeated cohort preflight neither builds nor switches cohort"
else
  sed 's/^/     /' "$output" >&2
  bad "repeated cohort preflight must be read-only"
fi

python3 - "$state" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = json.loads(path.read_text())
value["revision"] = "0" * 40
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
PY
expect_fail "HEAD mismatch rejects the cohort" "cohort revision is" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$cohort_root"
initialize_cohort
record_cohort

write_version "9.8.8"
expect_fail "bundle version mismatch rejects the cohort" "cohort version is" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$cohort_root"
write_version "9.8.7"
initialize_cohort
record_cohort

write_version "9.8.7" "988"
expect_fail "bundle build-version mismatch rejects the cohort" "cohort build version is" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$cohort_root"
write_version "9.8.7"
initialize_cohort
record_cohort

printf '\n' >>"$cohort_root/release/FAMOTYPE-SBOM.spdx.json"
expect_fail "inventory mismatch rejects the cohort" "cohort inventory fingerprint does not match" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$cohort_root"
record_cohort

printf 'mutated\n' >>"$payload"
expect_fail "bundle mutation rejects the recorded inventory" "artifact app does not match its cohort binding" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$cohort_root"
printf 'fake executable\n' >"$payload"
record_cohort

moved_root="$work/moved output root"
cp -R "$cohort_root" "$moved_root"
expect_fail "moving artifacts to another output root rejects the cohort" "different output root" \
  env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    python3 "$INVENTORY" check "$moved_root"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
