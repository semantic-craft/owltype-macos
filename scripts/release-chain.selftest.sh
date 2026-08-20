#!/usr/bin/env bash
# Full release-chain regression tests. Every artifact, credential probe, and command adapter is fake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/release-cohort-state.py"
INVENTORY="$ROOT/scripts/inventory-release-bundle.py"
RELEASE="$ROOT/scripts/release.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/owl-release-chain.XXXXXX")"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

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

dry_run="$work/dry-run"
if DEV_ID='fixture identity' NOTARY_PROFILE=fixture-profile \
    bash "$RELEASE" --dry-run --output-root "$work/dry output" >"$dry_run" 2>&1 &&
   [[ "$(grep -c 'make release-artifacts' "$dry_run")" -eq 1 ]] &&
   [[ "$(grep -c 'xcodebuild.*configuration Release' "$dry_run")" -le 1 ]] &&
   python3 - "$dry_run" <<'PY'
import sys

text = open(sys.argv[1]).read()
ordered = [
    "make test",
    "make release-artifacts",
    "create-source-archive.sh",
    "verify-chain",
    "check-release.sh",
    "check-public-source.sh",
    "check-secrets.sh --artifacts",
    "check-published-release.sh --dry-run",
]
positions = [text.index(value) for value in ordered]
assert positions == sorted(positions), positions
artifact_gate = next(line for line in text.splitlines() if "check-secrets.sh --artifacts" in line)
for required in (
    "Owltype.pkg",
    "Owltype-update.pkg",
    ".dmg",
    ".tar.gz.sha256",
    "OWLTYPE-RELEASE-COHORT.json",
):
    assert required in artifact_gate, (required, artifact_gate)
PY
then
  ok "authoritative dry-run exposes the complete release order with one artifact build"
else
  sed 's/^/     /' "$dry_run" >&2
  bad "authoritative dry-run must expose one complete ordered release chain"
fi

test_trace="$work/test-trace"
if make -C "$ROOT" --no-print-directory -n test DEPS_CHECK= \
    DERIVED_DATA_PATH="$work/test output" >"$test_trace" 2>&1 &&
   python3 - "$test_trace" <<'PY'
import sys

text = open(sys.argv[1]).read()
suites = (
    "OwlGoalBriefLiveTests",
    "OwlPromptOptimizeLiveTests",
    "OwlResponsesPromptEvaluationLiveTests",
    "OwlSkillsLiveTests",
    "OwlTriModelSelectionMatrixLiveTests",
)
assert text.count("-skip-testing:OwltypeTests/") == len(suites), text
assert "-skip-testing:OwltypeTests/OwlLiveInputTraceTests" not in text, text
for suite in suites:
    assert text.count(f"-skip-testing:OwltypeTests/{suite}") == 1, (suite, text)
PY
then
  ok "product test entrypoint excludes only the five credential-gated Live suites"
else
  sed 's/^/     /' "$test_trace" >&2
  bad "product test entrypoint must run offline privacy tests and exclude credential-gated Live suites"
fi

source_mode_repo="$work/source-mode-repo"
mkdir -p "$source_mode_repo"
git -C "$source_mode_repo" init -q
git -C "$source_mode_repo" config user.name 'Release Source Selftest'
git -C "$source_mode_repo" config user.email 'release-source-selftest@example.invalid'
printf 'regular source\n' >"$source_mode_repo/regular.txt"
printf '#!/bin/sh\nexit 0\n' >"$source_mode_repo/executable.sh"
chmod 0644 "$source_mode_repo/regular.txt"
chmod 0755 "$source_mode_repo/executable.sh"
git -C "$source_mode_repo" add regular.txt executable.sh
git -C "$source_mode_repo" commit -qm fixture
if PYTHONPATH="$ROOT/scripts" python3 - "$source_mode_repo" <<'PY'
import subprocess
import sys
from pathlib import Path

from release_source import git_source_snapshot, tree_fingerprint

repo = Path(sys.argv[1])
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
subprocess.run(["git", "config", "tar.umask", "0000"], cwd=repo, check=True)
open_snapshot, _ = git_source_snapshot(repo, revision)
subprocess.run(["git", "config", "tar.umask", "0022"], cwd=repo, check=True)
closed_snapshot, _ = git_source_snapshot(repo, revision)
assert tree_fingerprint(open_snapshot) == tree_fingerprint(closed_snapshot)
assert {path: entry.mode for path, entry in open_snapshot.items()} == {
    "executable.sh": 0o755,
    "regular.txt": 0o644,
}
assert {path: entry.mode for path, entry in closed_snapshot.items()} == {
    "executable.sh": 0o755,
    "regular.txt": 0o644,
}
PY
then
  ok "Git source digest and modes ignore repository tar.umask"
else
  bad "Git source snapshot must derive canonical modes from the Git tree"
fi

make_trace="$work/make-trace"
if make -C "$ROOT" --no-print-directory -n release-artifacts \
    DEPS_CHECK= DEV_ID=fixture NOTARY_PROFILE=fixture \
    RELEASE_OUTPUT_ROOT="$work/make output" >"$make_trace" 2>&1 &&
   [[ "$(grep -c 'xcodebuild .*configuration Release' "$make_trace")" -eq 1 ]] &&
   [[ "$(grep -c 'release-cohort-state.py initialize' "$make_trace")" -eq 1 ]] &&
   [[ "$(grep -c 'package/make_package' "$make_trace")" -eq 1 ]] &&
   [[ "$(grep -c 'package/make_dmg' "$make_trace")" -eq 1 ]] &&
   [[ "$(grep -c 'package/make_archive' "$make_trace")" -eq 1 ]]; then
  ok "Make release graph builds and initializes one cohort exactly once"
else
  sed 's/^/     /' "$make_trace" >&2
  bad "release-artifacts must be one non-duplicating Make graph"
fi

runner_bin="$work/runner-bin"
runner_log="$work/runner.log"
mkdir -p "$runner_bin"
cat >"$runner_bin/make" <<'STUB'
#!/bin/bash
printf 'make %s\n' "$*" >>"$OWL_RELEASE_TEST_LOG"
[[ "${OWL_RELEASE_TEST_FAIL:-}" != make ]]
STUB
cat >"$runner_bin/security" <<'STUB'
#!/bin/bash
printf 'security %s\n' "$*" >>"$OWL_RELEASE_TEST_LOG"
if [[ " $* " == *" -p codesigning "* ]]; then
  printf 'Developer ID Application: fixture identity\n'
else
  printf 'Developer ID Installer: fixture identity\n'
fi
STUB
cat >"$runner_bin/xcrun" <<'STUB'
#!/bin/bash
printf 'xcrun %s\n' "$*" >>"$OWL_RELEASE_TEST_LOG"
exit 0
STUB
cat >"$runner_bin/git" <<'STUB'
#!/bin/bash
printf 'git %s\n' "$*" >>"$OWL_RELEASE_TEST_LOG"
exit 0
STUB
cat >"$runner_bin/bash" <<'STUB'
#!/bin/bash
printf 'bash %s\n' "$*" >>"$OWL_RELEASE_TEST_LOG"
if [[ "${OWL_RELEASE_TEST_REAL_PUBLISHED:-}" == 1 &&
      "$*" == *"check-published-release.sh --print0"* ]]; then
  PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash "$@"
  exit $?
fi
if [[ "${OWL_RELEASE_TEST_REAL_PUBLISHED:-}" == 1 &&
      "$*" == *"check-secrets.sh --artifacts"* ]]; then
  printf '%s\0' "$@" >"${OWL_RELEASE_TEST_ARTIFACT_ARGS:?}"
  exit 0
fi
if [[ "$*" == *"check-published-release.sh --print0"* ]]; then
  for asset in Owltype.pkg Owltype-update.pkg Owltype-9.8.7.dmg appcast.xml \
      source.tar.gz source.tar.gz.sha256 manifest sbom provenance cohort.json; do
    printf '%s/%s\0' "${OWL_RELEASE_TEST_ASSET_ROOT:-/tmp}" "$asset"
  done
fi
if [[ "$*" == *"${OWL_RELEASE_TEST_FAIL:-__never__}"* ]]; then
  exit 71
fi
exit 0
STUB
cat >"$runner_bin/python3" <<'STUB'
#!/bin/bash
printf 'python3 %s\n' "$*" >>"$OWL_RELEASE_TEST_LOG"
if [[ "$*" == *" output-path "* ]]; then
  printf '%s\n' "${OWL_RELEASE_TEST_SOURCE:?}"
fi
if [[ "$*" == *"${OWL_RELEASE_TEST_FAIL:-__never__}"* ]]; then
  exit 72
fi
exit 0
STUB
chmod +x "$runner_bin"/*
touch "$work/fake-source.tar.gz"

if env PATH="$runner_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OWL_RELEASE_TEST_LOG="$runner_log" \
    OWL_RELEASE_TEST_SOURCE="$work/fake-source.tar.gz" \
    DEV_ID='fixture identity' NOTARY_PROFILE=fixture-profile \
    /bin/bash "$RELEASE" --output-root "$work/runner output" >"$output" 2>&1 &&
   [[ "$(grep -c '^make release-artifacts ' "$runner_log")" -eq 1 ]] &&
   ! grep -Eq '^make (dmg|archive|package)( |$)' "$runner_log"; then
  ok "authoritative execution invokes the release artifact graph only once"
else
  sed 's/^/     /' "$runner_log" >&2
  sed 's/^/     /' "$output" >&2
  bad "release execution must not re-enter phony component targets"
fi

: >"$runner_log"
expect_fail "release chain stops at the first failed composition step" "" \
  env PATH="$runner_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OWL_RELEASE_TEST_LOG="$runner_log" \
    OWL_RELEASE_TEST_SOURCE="$work/fake-source.tar.gz" \
    OWL_RELEASE_TEST_FAIL=create-source-archive.sh \
    DEV_ID='fixture identity' NOTARY_PROFILE=fixture-profile \
    /bin/bash "$RELEASE" --output-root "$work/failed runner output"
if grep -q 'create-source-archive.sh' "$runner_log" &&
   ! grep -qE 'verify-chain|check-release\.sh|check-public-source\.sh|check-published-release\.sh' "$runner_log"; then
  ok "failed release step short-circuits every downstream gate"
else
  sed 's/^/     /' "$runner_log" >&2
  bad "release failure must stop before downstream validation"
fi

fake_bin="$work/fake-bin"
mock_adapter="$work/mock-apple-tool-adapter"
mkdir -p "$fake_bin"
cat >"$fake_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$mock_adapter" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
action="${1:?}"
kind="${2:?}"
case "$action" in
  cohort-id)
    cat "${3:?}.embedded-cohort-id"
    ;;
  sign)
    source_artifact="${4:?}"
    signed_artifact="${5:?}"
    if [[ "$source_artifact" != "$signed_artifact" ]]; then
      cp "$source_artifact" "$signed_artifact"
    fi
    ;;
  notarize|staple)
    ;;
  *)
    exit 64
    ;;
esac
STUB
chmod +x "$fake_bin/xcrun" "$mock_adapter"

cohort_root="$work/cohort"
app="$cohort_root/Build/Products/Release/Owltype.app"
release_dir="$cohort_root/release"
artifact_dir="$cohort_root/artifacts"
mkdir -p "$app/Contents/MacOS" "$app/Contents/SharedSupport/licenses" \
  "$release_dir" "$artifact_dir"
printf 'fake app\n' >"$app/Contents/MacOS/Owltype"
chmod +x "$app/Contents/MacOS/Owltype"
printf 'fixture generated seed\n' >"$app/Contents/SharedSupport/seed.txt"
printf 'fixture seed license\n' >"$app/Contents/SharedSupport/licenses/fixture.txt"
private_key="$work/synthetic-ed25519-private-key"
key_generator="$work/generate-synthetic-key.swift"
cat >"$key_generator" <<'SWIFT'
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
public_key="$(/usr/bin/swift "$key_generator" "$private_key")"
python3 - "$app/Contents/Info.plist" "$public_key" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": "im.owltype.inputmethod.Owltype",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "987",
            "SUPublicEDKey": sys.argv[2],
        },
        handle,
    )
PY

run_state() {
  env OWL_APPLE_TOOL_ADAPTER="$mock_adapter" OWL_RELEASE_RETRY_DELAY_SECONDS=0 \
    python3 "$STATE" "$@"
}

run_state initialize "$cohort_root" >"$output"
run_state seal "$cohort_root" app fixture-id fixture-profile >>"$output"
env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  python3 "$INVENTORY" record "$cohort_root" >>"$output"
cohort_id="$(run_state id "$cohort_root")"
cohort_id="${cohort_id##*$'\n'}"

printf 'foreign version DMG\n' >"$artifact_dir/Owltype-9.8.8.dmg"
printf '%s\n' "$cohort_id" >"$artifact_dir/Owltype-9.8.8.dmg.embedded-cohort-id"
expect_fail "versioned artifact name mismatch is rejected before registration" \
  "artifact dmg is named 'Owltype-9.8.8.dmg', expected 'Owltype-9.8.7.dmg'" \
  run_state register "$cohort_root" dmg "$artifact_dir/Owltype-9.8.8.dmg"
rm -f "$artifact_dir/Owltype-9.8.8.dmg" "$artifact_dir/Owltype-9.8.8.dmg.embedded-cohort-id"

for spec in 'installer-pkg:Owltype.pkg' 'update-pkg:Owltype-update.pkg' 'dmg:Owltype-9.8.7.dmg'; do
  kind="${spec%%:*}"
  artifact="$artifact_dir/${spec##*:}"
  printf 'fake %s\n' "$kind" >"$artifact"
  printf '%s\n' "$cohort_id" >"$artifact.embedded-cohort-id"
  run_state register "$cohort_root" "$kind" "$artifact" >>"$output"
  run_state seal "$cohort_root" "$kind" fixture-id fixture-profile >>"$output"
done

app_manifest_sha="$(shasum -a 256 "$release_dir/OWLTYPE-FILE-MANIFEST.sha256" | awk '{print $1}')"
appcast="$artifact_dir/appcast.xml"
update_length="$(stat -f '%z' "$artifact_dir/Owltype-update.pkg")"
update_sha="$(shasum -a 256 "$artifact_dir/Owltype-update.pkg" | awk '{print $1}')"
sparkle_signer="$ROOT/download/bin/sign_update"
[[ -x "$sparkle_signer" ]] || {
  echo >&2 "missing pinned Sparkle sign_update; run make bootstrap"
  exit 1
}
sparkle_signature="$("$sparkle_signer" --ed-key-file "$private_key" -p \
  "$artifact_dir/Owltype-update.pkg")"
write_appcast() {
  local version="$1" build_version="$2" identity="$3" destination="$4"
  local package_sha="${5:-$update_sha}"
  local installation_type="${6:-package}"
  local signature="${7:-$sparkle_signature}"
  cat >"$destination" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
  xmlns:owl="https://responsay.com/owltype/release-cohort">
  <channel><item>
    <sparkle:version>${build_version}</sparkle:version>
    <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
    <owl:releaseCohort>${identity}</owl:releaseCohort>
    <owl:updatePackageSha256>${package_sha}</owl:updatePackageSha256>
    <enclosure url="https://downloads.responsay.com/owltype/releases/${build_version}/Owltype-update.pkg"
      sparkle:version="${build_version}" sparkle:shortVersionString="${version}"
      sparkle:installationType="${installation_type}" sparkle:edSignature="${signature}" length="${update_length}"/>
  </item></channel>
</rss>
XML
}

validate_appcast_fixture() {
  PYTHONPATH="$ROOT/scripts" python3 - "$1" "$cohort_root" \
    "$release_dir/OWLTYPE-RELEASE-COHORT.json" "$ROOT/scripts/release-cohort-state.py" <<'PY'
import json
import importlib.util
import sys
from pathlib import Path

module_path = Path(sys.argv[4])
spec = importlib.util.spec_from_file_location("release_cohort_state", module_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

try:
    module.validate_appcast(Path(sys.argv[1]), json.loads(Path(sys.argv[3]).read_text()), Path(sys.argv[2]))
except module.CohortError as error:
    raise SystemExit(f"FAIL: {error}") from error
PY
}

foreign_appcast="$work/foreign-appcast.xml"
write_appcast 9.8.8 988 "$cohort_id" "$foreign_appcast"
expect_fail "appcast version mismatch is rejected before binding" "appcast version" \
  run_state register-output "$cohort_root" appcast "$foreign_appcast"
write_appcast 9.8.7 987 foreign-cohort "$foreign_appcast"
expect_fail "appcast cohort mismatch is rejected before binding" "appcast embeds a different cohort identity" \
  run_state register-output "$cohort_root" appcast "$foreign_appcast"
write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast" "$(printf '0%.0s' {1..64})"
expect_fail "appcast update package hash mismatch is rejected before binding" \
  "appcast update package hash does not match the release cohort" \
  run_state register-output "$cohort_root" appcast "$foreign_appcast"

random_signature="$(python3 - <<'PY'
import base64
print(base64.b64encode(bytes(64)).decode())
PY
)"
write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast" "$update_sha" package "$random_signature"
expect_fail "random non-empty Sparkle signature is rejected" \
  "appcast EdDSA signature does not verify with the App public key" \
  validate_appcast_fixture "$foreign_appcast"

printf 'another package with equal-ish fixture content\n' >"$work/other-update.pkg"
other_signature="$("$sparkle_signer" --ed-key-file "$private_key" -p "$work/other-update.pkg")"
write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast" "$update_sha" package "$other_signature"
expect_fail "signature over a different package is rejected" \
  "appcast EdDSA signature does not verify with the App public key" \
  validate_appcast_fixture "$foreign_appcast"

write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast" "$update_sha" application
expect_fail "non-package Sparkle installation type is rejected" \
  "appcast installation type must be package" \
  validate_appcast_fixture "$foreign_appcast"

write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast"
python3 - "$foreign_appcast" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
foreign = """<item>
    <sparkle:version>999</sparkle:version>
    <sparkle:shortVersionString>99.9.9</sparkle:shortVersionString>
    <owl:releaseCohort>foreign-cohort</owl:releaseCohort>
    <owl:updatePackageSha256>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</owl:updatePackageSha256>
    <enclosure url="https://attacker.invalid/Owltype-update.pkg"
      sparkle:version="999" sparkle:shortVersionString="99.9.9"
      sparkle:edSignature="foreign" length="1"/>
  </item>"""
open(path, "w").write(text.replace("</channel>", f"{foreign}</channel>"))
PY
expect_fail "appcast with a foreign second item is rejected before binding" \
  "appcast must contain exactly one channel and one item" \
  run_state register-output "$cohort_root" appcast "$foreign_appcast"

write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast"
python3 - "$foreign_appcast" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
foreign = """<enclosure url="https://attacker.invalid/Owltype-update.pkg"
      sparkle:version="999" sparkle:shortVersionString="99.9.9"
      sparkle:edSignature="foreign" length="1"/>"""
open(path, "w").write(text.replace("</item>", f"{foreign}</item>"))
PY
expect_fail "appcast with a foreign second enclosure is rejected before binding" \
  "appcast item must contain exactly one enclosure" \
  run_state register-output "$cohort_root" appcast "$foreign_appcast"

write_appcast 9.8.7 987 "$cohort_id" "$appcast"
run_state register-output "$cohort_root" appcast "$appcast" >>"$output"

source_root="$work/Owltype-macOS-9.8.7-source"
source_archive="$release_dir/Owltype-macOS-9.8.7-source.tar.gz"
SOURCE_TOOL="$ROOT/scripts/release_source.py"
mkdir -p "$source_root/Owltype.xcodeproj"
cat >"$source_root/OWLTYPE-SOURCE-PROVENANCE.txt" <<EOF
Owltype source release 9.8.7
build-version 987
root $(git -C "$ROOT" rev-parse HEAD)
cohort foreign-cohort
app-manifest $app_manifest_sha
EOF
printf 'source\n' >"$source_root/source.txt"
printf 'fixture project\n' >"$source_root/Owltype.xcodeproj/project.pbxproj"
printf 'fixture license\n' >"$source_root/LICENSE.txt"
printf 'fixture make\n' >"$source_root/Makefile"
printf 'fixture notices\n' >"$source_root/THIRD_PARTY_NOTICES.md"
mkdir -p "$source_root/data/owl-rime/licenses"
cp "$app/Contents/SharedSupport/seed.txt" "$source_root/data/owl-rime/seed.txt"
cp "$app/Contents/SharedSupport/licenses/fixture.txt" \
  "$source_root/data/owl-rime/licenses/fixture.txt"
write_source_manifest() {
  python3 - "$source_root" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = root / "OWLTYPE-SOURCE-MANIFEST.sha256"
files = sorted(
    (path for path in root.rglob("*") if path.is_file() and path != manifest),
    key=lambda path: path.relative_to(root).as_posix(),
)
manifest.write_text(
    "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
        f"{path.relative_to(root).as_posix()}\n"
        for path in files
    )
)
PY
}
write_source_manifest
archive_source() {
  python3 "$SOURCE_TOOL" archive "$source_root" "$source_archive"
  (
    cd "$release_dir"
    shasum -a 256 "$(basename "$source_archive")" >"$(basename "$source_archive").sha256"
  )
}
archive_source
expect_fail "source archive cohort mismatch is rejected before binding" \
  "source archive embeds a different cohort identity" \
  run_state register-output "$cohort_root" source-archive "$source_archive"

python3 - "$source_root/OWLTYPE-SOURCE-PROVENANCE.txt" "$cohort_id" <<'PY'
import sys

path, cohort = sys.argv[1:]
text = open(path).read().replace("cohort foreign-cohort", f"cohort {cohort}")
open(path, "w").write(text)
PY
archive_source
expect_fail "source archive internal manifest mismatch is rejected before binding" \
  "source archive manifest mismatch" \
  run_state register-output "$cohort_root" source-archive "$source_archive"
write_source_manifest

validate_source_archive_fixture() {
  PYTHONPATH="$ROOT/scripts" python3 - "$source_archive" "$release_dir" \
    "$release_dir/OWLTYPE-RELEASE-COHORT.json" "$ROOT/scripts/release-cohort-state.py" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_cohort_state", Path(sys.argv[4]))
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    module.validate_source_archive(
        Path(sys.argv[1]), json.loads(Path(sys.argv[3]).read_text()), Path(sys.argv[2])
    )
except module.CohortError as error:
    raise SystemExit(f"FAIL: {error}") from error
PY
}

archive_source
expect_fail "arbitrary self-consistent source archive is rejected" \
  "source archive tracked source does not match the cohort revision" \
  validate_source_archive_fixture

rm -rf "$source_root"
python3 "$SOURCE_TOOL" stage "$ROOT" "$(git -C "$ROOT" rev-parse HEAD)" "$source_root"
mkdir -p "$source_root/data/owl-rime"
rsync -a "$app/Contents/SharedSupport/." "$source_root/data/owl-rime/"
python3 - "$source_root/OWLTYPE-SOURCE-PROVENANCE.txt" \
  "$release_dir/OWLTYPE-RELEASE-COHORT.json" "$app_manifest_sha" <<'PY'
import json
import sys
from pathlib import Path

destination, cohort_path, app_manifest = map(Path, sys.argv[1:])
cohort = json.loads(cohort_path.read_text())
destination.write_text(
    f"Owltype source release {cohort['version']}\n"
    f"build-version {cohort['buildVersion']}\n"
    f"root {cohort['revision']}\n"
    f"cohort {cohort['cohortId']}\n"
    f"source-tree {cohort['sourceSha256']}\n"
    f"seed-tree {cohort['seedSha256']}\n"
    f"app-manifest {app_manifest}\n"
)
PY
write_source_manifest
archive_source

cp "$source_root/Makefile" "$work/original-source-Makefile"
printf 'replaced root source\n' >"$source_root/Makefile"
write_source_manifest
archive_source
expect_fail "replaced root source fails after manifest and sidecar recomputation" \
  "source archive tracked source does not match the cohort revision" \
  validate_source_archive_fixture
cp "$work/original-source-Makefile" "$source_root/Makefile"

cp "$source_root/Sparkle/LICENSE" "$work/original-sparkle-license"
printf 'replaced submodule source\n' >"$source_root/Sparkle/LICENSE"
write_source_manifest
archive_source
expect_fail "replaced submodule source fails after manifest and sidecar recomputation" \
  "source archive tracked source does not match the cohort revision" \
  validate_source_archive_fixture
cp "$work/original-sparkle-license" "$source_root/Sparkle/LICENSE"

cp "$source_root/data/owl-rime/seed.txt" "$work/original-seed"
printf 'replaced seed\n' >"$source_root/data/owl-rime/seed.txt"
write_source_manifest
archive_source
expect_fail "replaced seed fails after manifest and sidecar recomputation" \
  "source archive seed does not match the release App" \
  validate_source_archive_fixture
cp "$work/original-seed" "$source_root/data/owl-rime/seed.txt"
write_source_manifest
archive_source

make_special_source_archive() {
  local member_type="$1"
  archive_source
  python3 - "$source_archive" "$member_type" <<'PY'
import gzip
import io
import os
import sys
import tarfile
from pathlib import Path

archive_path = Path(sys.argv[1])
member_type = sys.argv[2]
with tarfile.open(archive_path, "r:gz") as archive:
    members = []
    for member in archive.getmembers():
        extracted = archive.extractfile(member) if member.isfile() else None
        members.append((member, extracted.read() if extracted is not None else None))

root = members[0][0].name
special = tarfile.TarInfo(f"{root}/zz-outside-{member_type}")
special.type = tarfile.SYMTYPE if member_type == "symlink" else tarfile.LNKTYPE
special.linkname = "../../escape"
special.mode = 0o644
special.uid = 0
special.gid = 0
special.uname = "root"
special.gname = "root"
special.mtime = 0
members.append((special, None))

temporary = archive_path.with_name(f".{archive_path.name}.special")
with temporary.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for member, data in sorted(members, key=lambda item: item[0].name.encode()):
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
os.replace(temporary, archive_path)
PY
  (
    cd "$release_dir"
    shasum -a 256 "$(basename "$source_archive")" >"$(basename "$source_archive").sha256"
  )
}

make_special_source_archive symlink
expect_fail "source archive with an outside-root symlink is rejected before binding" \
  "source archive contains unsupported member type" \
  run_state register-output "$cohort_root" source-archive "$source_archive"
make_special_source_archive hardlink
expect_fail "source archive with an outside-root hardlink is rejected before binding" \
  "source archive contains unsupported member type" \
  run_state register-output "$cohort_root" source-archive "$source_archive"

archive_source
run_state register-output "$cohort_root" source-archive "$source_archive" >>"$output"

if run_state verify-chain "$cohort_root" >"$output" 2>&1; then
  ok "complete chain verifies app, packages, DMG, inventory, source, and appcast as one cohort"
else
  sed 's/^/     /' "$output" >&2
  bad "complete synthetic cohort should pass the full-chain verifier"
fi

published_stdout="$work/published-assets.nul"
published_stderr="$work/published-assets.stderr"
if bash "$ROOT/scripts/check-published-release.sh" --print0 "$cohort_root" \
    >"$published_stdout" 2>"$published_stderr" &&
   python3 - "$published_stdout" "$published_stderr" <<'PY'
import sys
from pathlib import Path

stdout = Path(sys.argv[1]).read_bytes()
stderr = Path(sys.argv[2]).read_text()
assert b"PASS:" not in stdout and b"FAIL:" not in stdout, stdout
records = stdout.split(b"\0")
assert records[-1] == b"", records
assets = [Path(record.decode()) for record in records[:-1]]
assert len(assets) == 10, assets
assert all(asset.exists() for asset in assets), assets
assert assets[0].name == "Owltype.pkg", assets
assert "PASS:" in stderr, stderr
PY
then
  ok "production print0 emits exactly ten existing assets and diagnostics only on stderr"
else
  sed 's/^/     /' "$published_stderr" >&2
  bad "production print0 stdout must contain only ten NUL-delimited asset paths"
fi

artifact_args="$work/release-artifact-args.nul"
: >"$runner_log"
if env PATH="$runner_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OWL_RELEASE_TEST_LOG="$runner_log" \
    OWL_RELEASE_TEST_SOURCE="$source_archive" \
    OWL_RELEASE_TEST_REAL_PUBLISHED=1 \
    OWL_RELEASE_TEST_ARTIFACT_ARGS="$artifact_args" \
    DEV_ID='fixture identity' NOTARY_PROFILE=fixture-profile \
    /bin/bash "$RELEASE" --output-root "$cohort_root" >"$output" 2>&1 &&
   python3 - "$artifact_args" "$app" <<'PY'
import sys
from pathlib import Path

records = Path(sys.argv[1]).read_bytes().split(b"\0")
assert records[-1] == b"", records
arguments = [record.decode() for record in records[:-1]]
assert Path(arguments[0]).name == "check-secrets.sh", arguments
assert arguments[1] == "--artifacts", arguments
targets = [Path(value) for value in arguments[2:]]
assert len(targets) == 11, targets
assert targets[0] == Path(sys.argv[2]), targets
assert all(target.exists() for target in targets), targets
assert targets[1].name == "Owltype.pkg", targets
PY
then
  ok "release secret-gate seam receives App plus all ten existing published assets"
else
  sed 's/^/     /' "$output" >&2
  bad "release secret gate must receive App and ten unpolluted published asset paths"
fi

if bash "$ROOT/scripts/check-published-release.sh" --dry-run "$cohort_root" \
    >"$output" 2>&1 &&
   [[ "$(grep -c '^WOULD_PUBLISH:' "$output")" -eq 10 ]] &&
   grep -q 'nothing was published' "$output"; then
  ok "published gate verifies and enumerates ten local assets without remote I/O"
else
  sed 's/^/     /' "$output" >&2
  bad "published gate must stay local and enumerate the complete cohort contract"
fi

: >"$runner_log"
if env PATH="$runner_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OWL_RELEASE_TEST_LOG="$runner_log" \
    OWL_RELEASE_TEST_SOURCE="$source_archive" \
    DEV_ID='fixture identity' NOTARY_PROFILE=fixture-profile \
    /bin/bash "$RELEASE" --output-root "$cohort_root" >"$output" 2>&1 &&
   [[ "$(grep -c '^make test ' "$runner_log")" -eq 1 ]] &&
   ! grep -qE '^make (owl-seed|release-artifacts)( |$)' "$runner_log" &&
   ! grep -q 'create-source-archive.sh' "$runner_log" &&
   grep -q 'verify-chain' "$runner_log"; then
  ok "repeated invocation reruns tests but does not rebuild the verified Release cohort"
else
  sed 's/^/     /' "$runner_log" >&2
  bad "repeated release invocation must validate rather than rebuild the cohort"
fi

printf 'mutated\n' >>"$source_archive"
source_size="$(( $(stat -f '%z' "$source_archive") - 8 ))"
truncate -s "$source_size" "$source_archive"
cp "$release_dir/OWLTYPE-SBOM.spdx.json" "$work/original-sbom.json"
printf '\n' >>"$release_dir/OWLTYPE-SBOM.spdx.json"
expect_fail "inventory mutation fails the complete chain" \
  "cohort inventory fingerprint does not match" \
  run_state verify-chain "$cohort_root"
cp "$work/original-sbom.json" "$release_dir/OWLTYPE-SBOM.spdx.json"
printf 'mutated\n' >>"$source_archive"
expect_fail "bound source archive mutation fails the complete chain" \
  "output source-archive does not match its cohort binding" \
  run_state verify-chain "$cohort_root"

if grep -qE 'check-secrets\.sh" --artifacts' "$RELEASE" &&
   ! grep -q 'check-secrets.sh' "$ROOT/scripts/create-source-archive.sh" &&
   grep -q 'secret-finding-policy.py' "$ROOT/scripts/check-artifact-secrets.sh"; then
  ok "one artifact gate applies the centralized secret policy to App and source outputs"
else
  bad "App and source archive must share one centralized artifact secret-policy invocation"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
