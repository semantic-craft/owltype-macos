#!/usr/bin/env bash
# Full release-chain regression tests. Every artifact, credential probe, and command adapter is fake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/release-cohort-state.py"
INVENTORY="$ROOT/scripts/inventory-release-bundle.py"
RELEASE="$ROOT/scripts/release.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/famo-release-chain.XXXXXX")"
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
PY
then
  ok "authoritative dry-run exposes the complete release order with one artifact build"
else
  sed 's/^/     /' "$dry_run" >&2
  bad "authoritative dry-run must expose one complete ordered release chain"
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
printf 'make %s\n' "$*" >>"$FAMO_RELEASE_TEST_LOG"
[[ "${FAMO_RELEASE_TEST_FAIL:-}" != make ]]
STUB
cat >"$runner_bin/security" <<'STUB'
#!/bin/bash
printf 'security %s\n' "$*" >>"$FAMO_RELEASE_TEST_LOG"
if [[ " $* " == *" -p codesigning "* ]]; then
  printf 'Developer ID Application: fixture identity\n'
else
  printf 'Developer ID Installer: fixture identity\n'
fi
STUB
cat >"$runner_bin/xcrun" <<'STUB'
#!/bin/bash
printf 'xcrun %s\n' "$*" >>"$FAMO_RELEASE_TEST_LOG"
exit 0
STUB
cat >"$runner_bin/git" <<'STUB'
#!/bin/bash
printf 'git %s\n' "$*" >>"$FAMO_RELEASE_TEST_LOG"
exit 0
STUB
cat >"$runner_bin/bash" <<'STUB'
#!/bin/bash
printf 'bash %s\n' "$*" >>"$FAMO_RELEASE_TEST_LOG"
if [[ "$*" == *"${FAMO_RELEASE_TEST_FAIL:-__never__}"* ]]; then
  exit 71
fi
exit 0
STUB
cat >"$runner_bin/python3" <<'STUB'
#!/bin/bash
printf 'python3 %s\n' "$*" >>"$FAMO_RELEASE_TEST_LOG"
if [[ "$*" == *" output-path "* ]]; then
  printf '%s\n' "${FAMO_RELEASE_TEST_SOURCE:?}"
fi
if [[ "$*" == *"${FAMO_RELEASE_TEST_FAIL:-__never__}"* ]]; then
  exit 72
fi
exit 0
STUB
chmod +x "$runner_bin"/*
touch "$work/fake-source.tar.gz"

if env PATH="$runner_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAMO_RELEASE_TEST_LOG="$runner_log" \
    FAMO_RELEASE_TEST_SOURCE="$work/fake-source.tar.gz" \
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
    FAMO_RELEASE_TEST_LOG="$runner_log" \
    FAMO_RELEASE_TEST_SOURCE="$work/fake-source.tar.gz" \
    FAMO_RELEASE_TEST_FAIL=create-source-archive.sh \
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
app="$cohort_root/Build/Products/Release/Famo.app"
release_dir="$cohort_root/release"
artifact_dir="$cohort_root/artifacts"
mkdir -p "$app/Contents/MacOS" "$release_dir" "$artifact_dir"
printf 'fake app\n' >"$app/Contents/MacOS/Famo"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": "im.famo.inputmethod.Famo",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "987",
        },
        handle,
    )
PY

run_state() {
  env FAMO_APPLE_TOOL_ADAPTER="$mock_adapter" FAMO_RELEASE_RETRY_DELAY_SECONDS=0 \
    python3 "$STATE" "$@"
}

run_state initialize "$cohort_root" >"$output"
run_state seal "$cohort_root" app fixture-id fixture-profile >>"$output"
env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  python3 "$INVENTORY" record "$cohort_root" >>"$output"
cohort_id="$(run_state id "$cohort_root")"
cohort_id="${cohort_id##*$'\n'}"

printf 'foreign version DMG\n' >"$artifact_dir/Famo-9.8.8.dmg"
printf '%s\n' "$cohort_id" >"$artifact_dir/Famo-9.8.8.dmg.embedded-cohort-id"
expect_fail "versioned artifact name mismatch is rejected before registration" \
  "artifact dmg is named 'Famo-9.8.8.dmg', expected 'Famo-9.8.7.dmg'" \
  run_state register "$cohort_root" dmg "$artifact_dir/Famo-9.8.8.dmg"
rm -f "$artifact_dir/Famo-9.8.8.dmg" "$artifact_dir/Famo-9.8.8.dmg.embedded-cohort-id"

for spec in 'installer-pkg:Famo.pkg' 'update-pkg:Famo-update.pkg' 'dmg:Famo-9.8.7.dmg'; do
  kind="${spec%%:*}"
  artifact="$artifact_dir/${spec##*:}"
  printf 'fake %s\n' "$kind" >"$artifact"
  printf '%s\n' "$cohort_id" >"$artifact.embedded-cohort-id"
  run_state register "$cohort_root" "$kind" "$artifact" >>"$output"
  run_state seal "$cohort_root" "$kind" fixture-id fixture-profile >>"$output"
done

app_manifest_sha="$(shasum -a 256 "$release_dir/FAMOTYPE-FILE-MANIFEST.sha256" | awk '{print $1}')"
appcast="$artifact_dir/appcast.xml"
update_length="$(stat -f '%z' "$artifact_dir/Famo-update.pkg")"
update_sha="$(shasum -a 256 "$artifact_dir/Famo-update.pkg" | awk '{print $1}')"
write_appcast() {
  local version="$1" build_version="$2" identity="$3" destination="$4"
  local package_sha="${5:-$update_sha}"
  cat >"$destination" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
  xmlns:famo="https://responsay.com/famo/release-cohort">
  <channel><item>
    <sparkle:version>${build_version}</sparkle:version>
    <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
    <famo:releaseCohort>${identity}</famo:releaseCohort>
    <famo:updatePackageSha256>${package_sha}</famo:updatePackageSha256>
    <enclosure url="https://github.com/semantic-craft/famotype-macos/releases/download/${build_version}/Famo-update.pkg"
      sparkle:version="${build_version}" sparkle:shortVersionString="${version}"
      sparkle:installationType="package" sparkle:edSignature="fixture" length="${update_length}"/>
  </item></channel>
</rss>
XML
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

write_appcast 9.8.7 987 "$cohort_id" "$foreign_appcast"
python3 - "$foreign_appcast" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
foreign = """<item>
    <sparkle:version>999</sparkle:version>
    <sparkle:shortVersionString>99.9.9</sparkle:shortVersionString>
    <famo:releaseCohort>foreign-cohort</famo:releaseCohort>
    <famo:updatePackageSha256>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</famo:updatePackageSha256>
    <enclosure url="https://attacker.invalid/Famo-update.pkg"
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
foreign = """<enclosure url="https://attacker.invalid/Famo-update.pkg"
      sparkle:version="999" sparkle:shortVersionString="99.9.9"
      sparkle:edSignature="foreign" length="1"/>"""
open(path, "w").write(text.replace("</item>", f"{foreign}</item>"))
PY
expect_fail "appcast with a foreign second enclosure is rejected before binding" \
  "appcast item must contain exactly one enclosure" \
  run_state register-output "$cohort_root" appcast "$foreign_appcast"

write_appcast 9.8.7 987 "$cohort_id" "$appcast"
run_state register-output "$cohort_root" appcast "$appcast" >>"$output"

source_root="$work/Famotype-macOS-9.8.7-source"
source_archive="$release_dir/Famotype-macOS-9.8.7-source.tar.gz"
mkdir -p "$source_root/Famo.xcodeproj"
cat >"$source_root/FAMOTYPE-SOURCE-PROVENANCE.txt" <<EOF
Famotype source release 9.8.7
build-version 987
root $(git -C "$ROOT" rev-parse HEAD)
cohort foreign-cohort
app-manifest $app_manifest_sha
EOF
printf 'source\n' >"$source_root/source.txt"
printf 'fixture project\n' >"$source_root/Famo.xcodeproj/project.pbxproj"
printf 'fixture license\n' >"$source_root/LICENSE.txt"
printf 'fixture make\n' >"$source_root/Makefile"
printf 'fixture notices\n' >"$source_root/THIRD_PARTY_NOTICES.md"
write_source_manifest() {
  python3 - "$source_root" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = root / "FAMOTYPE-SOURCE-MANIFEST.sha256"
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
COPYFILE_DISABLE=1 tar -czf "$source_archive" -C "$work" "$(basename "$source_root")"
(
  cd "$release_dir"
  shasum -a 256 "$(basename "$source_archive")" >"$(basename "$source_archive").sha256"
)
expect_fail "source archive cohort mismatch is rejected before binding" \
  "source archive embeds a different cohort identity" \
  run_state register-output "$cohort_root" source-archive "$source_archive"

python3 - "$source_root/FAMOTYPE-SOURCE-PROVENANCE.txt" "$cohort_id" <<'PY'
import sys

path, cohort = sys.argv[1:]
text = open(path).read().replace("cohort foreign-cohort", f"cohort {cohort}")
open(path, "w").write(text)
PY
COPYFILE_DISABLE=1 tar -czf "$source_archive" -C "$work" "$(basename "$source_root")"
(
  cd "$release_dir"
  shasum -a 256 "$(basename "$source_archive")" >"$(basename "$source_archive").sha256"
)
expect_fail "source archive internal manifest mismatch is rejected before binding" \
  "source archive manifest mismatch" \
  run_state register-output "$cohort_root" source-archive "$source_archive"
write_source_manifest

make_special_source_archive() {
  local member_type="$1"
  python3 - "$source_root" "$source_archive" "$member_type" <<'PY'
import sys
import tarfile
from pathlib import Path

source_root = Path(sys.argv[1])
archive_path = Path(sys.argv[2])
member_type = sys.argv[3]
with tarfile.open(archive_path, "w:gz") as archive:
    archive.add(source_root, arcname=source_root.name)
    member = tarfile.TarInfo(f"{source_root.name}/outside-{member_type}")
    member.type = tarfile.SYMTYPE if member_type == "symlink" else tarfile.LNKTYPE
    member.linkname = "../../escape"
    archive.addfile(member)
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

COPYFILE_DISABLE=1 tar -czf "$source_archive" -C "$work" "$(basename "$source_root")"
(
  cd "$release_dir"
  shasum -a 256 "$(basename "$source_archive")" >"$(basename "$source_archive").sha256"
)
run_state register-output "$cohort_root" source-archive "$source_archive" >>"$output"

if run_state verify-chain "$cohort_root" >"$output" 2>&1; then
  ok "complete chain verifies app, packages, DMG, inventory, source, and appcast as one cohort"
else
  sed 's/^/     /' "$output" >&2
  bad "complete synthetic cohort should pass the full-chain verifier"
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
    FAMO_RELEASE_TEST_LOG="$runner_log" \
    FAMO_RELEASE_TEST_SOURCE="$source_archive" \
    DEV_ID='fixture identity' NOTARY_PROFILE=fixture-profile \
    /bin/bash "$RELEASE" --output-root "$cohort_root" >"$output" 2>&1 &&
   [[ "$(grep -c '^make test ' "$runner_log")" -eq 1 ]] &&
   ! grep -qE '^make (famo-seed|release-artifacts)( |$)' "$runner_log" &&
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
cp "$release_dir/FAMOTYPE-SBOM.spdx.json" "$work/original-sbom.json"
printf '\n' >>"$release_dir/FAMOTYPE-SBOM.spdx.json"
expect_fail "inventory mutation fails the complete chain" \
  "cohort inventory fingerprint does not match" \
  run_state verify-chain "$cohort_root"
cp "$work/original-sbom.json" "$release_dir/FAMOTYPE-SBOM.spdx.json"
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
