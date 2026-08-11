#!/usr/bin/env bash
# Signing/notarization state-machine tests. The Apple adapter and every artifact are disposable fakes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/release-cohort-state.py"
INVENTORY="$ROOT/scripts/inventory-release-bundle.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/famo-cohort-transition.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
output="$work/output"
mock_log="$work/apple-tools.log"
mock_counts="$work/mock-counts"
fake_bin="$work/fake-bin"
mkdir -p "$mock_counts" "$fake_bin"
cat >"$fake_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$fake_bin/xcrun"

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

mock_adapter="$work/mock-apple-tool-adapter"
apply_marker() {
  local artifact="$1" marker="$2"
  if [[ -d "$artifact" ]]; then
    printf '%s\n' "$marker" >>"$artifact/Contents/MacOS/Famo"
  else
    printf '%s\n' "$marker" >>"$artifact"
  fi
}
export -f apply_marker

cat >"$mock_adapter" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

action="${1:?}"
kind="${2:?}"
scenario="${MOCK_SCENARIO:-success}"
key="${scenario}-${action}-${kind}"
counter="$MOCK_COUNT_DIR/$key"
attempt=1
if [[ -f "$counter" ]]; then
  attempt=$(( $(cat "$counter") + 1 ))
fi
printf '%s\n' "$attempt" >"$counter"
printf '%s %s %s %s\n' "$scenario" "$action" "$kind" "$attempt" >>"$MOCK_LOG"

if [[ "$action" == cohort-id ]]; then
  cat "${3:?}.embedded-cohort-id"
  exit 0
fi

if [[ "$scenario" == tsa-retry && "$action" == sign && "$kind" == app && "$attempt" -lt 3 ]]; then
  exit 75
fi
if [[ "$scenario" == notary-retry && "$action" == notarize && "$kind" == update-pkg && "$attempt" -lt 3 ]]; then
  exit 75
fi
if [[ "$scenario" == reject && "$action" == notarize ]]; then
  exit 65
fi
if [[ "$scenario" == timeout && "$action" == notarize ]]; then
  exit 75
fi

case "$action" in
  sign)
    source_artifact="${4:?}"
    signed_artifact="${5:?}"
    if [[ "$kind" == installer-pkg || "$kind" == update-pkg ]]; then
      cp "$source_artifact" "$signed_artifact"
      apply_marker "$signed_artifact" "signed:$kind"
    else
      apply_marker "$source_artifact" "signed:$kind"
    fi
    ;;
  notarize)
    ;;
  staple)
    apply_marker "${3:?}" "stapled:$kind"
    ;;
  *)
    exit 64
    ;;
esac
MOCK
chmod +x "$mock_adapter"

make_fixture() {
  local root="$1" version="${2:-9.8.7}"
  local app="$root/Build/Products/Release/Famo.app"
  mkdir -p "$app/Contents/MacOS"
  printf 'fake executable\n' >"$app/Contents/MacOS/Famo"
  python3 - "$app/Contents/Info.plist" "$version" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": "im.famo.inputmethod.Famo",
            "CFBundleShortVersionString": sys.argv[2],
        },
        handle,
    )
PY
  python3 "$STATE" initialize "$root" >"$output"
}

run_state() {
  local scenario="$1"
  shift
  env \
    FAMO_APPLE_TOOL_ADAPTER="$mock_adapter" \
    FAMO_RELEASE_RETRY_DELAY_SECONDS=0 \
    MOCK_SCENARIO="$scenario" \
    MOCK_LOG="$mock_log" \
    MOCK_COUNT_DIR="$mock_counts" \
    python3 "$STATE" "$@"
}

embed_fake_cohort_id() {
  local root="$1" artifact="$2"
  run_state success id "$root" >"$artifact.embedded-cohort-id"
}

production_bin="$work/production-adapter-bin"
production_log="$work/production-adapter.log"
mkdir -p "$production_bin"
cat >"$production_bin/codesign" <<'STUB'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >>"$APPLE_TOOL_LOG"
[[ " $* " == *" --verify "* ]] && exit 0
case "${APPLE_ADAPTER_SCENARIO:-accepted}" in
  tsa) echo 'timestamp service temporarily unavailable' >&2; exit 1 ;;
  sign-error) echo 'The specified item could not be found in the keychain.' >&2; exit 1 ;;
esac
exit 0
STUB
cat >"$production_bin/productsign" <<'STUB'
#!/usr/bin/env bash
printf 'productsign %s\n' "$*" >>"$APPLE_TOOL_LOG"
args=("$@")
source_artifact="${args[${#args[@]}-2]}"
signed_artifact="${args[${#args[@]}-1]}"
cp "$source_artifact" "$signed_artifact"
STUB
cat >"$production_bin/pkgutil" <<'STUB'
#!/usr/bin/env bash
printf 'pkgutil %s\n' "$*" >>"$APPLE_TOOL_LOG"
if [[ "${1:-}" == --expand ]]; then
  mkdir -p "$3/Resources"
  printf '%s\n' "${EMBEDDED_COHORT_ID:?}" >"$3/Resources/FAMOTYPE-RELEASE-COHORT-ID"
fi
exit 0
STUB
cat >"$production_bin/ditto" <<'STUB'
#!/usr/bin/env bash
printf 'ditto %s\n' "$*" >>"$APPLE_TOOL_LOG"
destination="${!#}"
printf 'fake zip\n' >"$destination"
STUB
cat >"$production_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >>"$APPLE_TOOL_LOG"
if [[ "${1:-}" == notarytool ]]; then
  case "${APPLE_ADAPTER_SCENARIO:-accepted}" in
    accepted) printf '{"status":"Accepted"}\n'; exit 0 ;;
    rejected) printf '{"status":"Invalid"}\n'; exit 1 ;;
    timeout) printf '{"status":"In Progress"}\n'; exit 1 ;;
    network) printf 'network connection timed out\n'; exit 1 ;;
    credentials) printf 'No Keychain password item found for profile\n'; exit 1 ;;
    malformed) printf '{not-json\n'; exit 1 ;;
  esac
fi
exit 0
STUB
cat >"$production_bin/spctl" <<'STUB'
#!/usr/bin/env bash
printf 'spctl %s\n' "$*" >>"$APPLE_TOOL_LOG"
printf 'accepted\n'
STUB
cat >"$production_bin/hdiutil" <<'STUB'
#!/usr/bin/env bash
printf 'hdiutil %s\n' "$*" >>"$APPLE_TOOL_LOG"
if [[ "${1:-}" == attach ]]; then
  args=("$@")
  for ((index = 0; index < ${#args[@]}; index++)); do
    if [[ "${args[index]}" == -mountpoint ]]; then
      mount_point="${args[index + 1]}"
      mkdir -p "$mount_point"
      printf '%s\n' "${EMBEDDED_COHORT_ID:?}" >"$mount_point/FAMOTYPE-RELEASE-COHORT-ID"
      break
    fi
  done
fi
exit 0
STUB
chmod +x "$production_bin"/*

run_production_adapter() {
  local scenario="$1"
  shift
  env APPLE_ADAPTER_SCENARIO="$scenario" APPLE_TOOL_LOG="$production_log" \
    EMBEDDED_COHORT_ID=fixture-cohort-id \
    PATH="$production_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/package/apple_tool_adapter" "$@"
}

production_app="$work/production Famo.app"
mkdir -p "$production_app/Contents/MacOS"
printf 'app\n' >"$production_app/Contents/MacOS/Famo"
if run_production_adapter accepted notarize app fixture-profile "$production_app" >"$output" 2>&1 &&
   grep -q -- '--wait --timeout 20m --output-format json' "$production_log"; then
  ok "production Apple adapter zips App and accepts structured notarization success"
else
  sed 's/^/     /' "$output" >&2
  bad "production adapter should submit App zip with bounded JSON wait"
fi

printf 'package\n' >"$work/inspect.pkg"
printf 'dmg\n' >"$work/inspect.dmg"
if [[ "$(run_production_adapter accepted cohort-id installer-pkg "$work/inspect.pkg")" == fixture-cohort-id ]] &&
   [[ "$(run_production_adapter accepted cohort-id dmg "$work/inspect.dmg")" == fixture-cohort-id ]]; then
  ok "production Apple adapter reads cohort identity from expanded pkg and mounted DMG"
else
  bad "production adapter must inspect embedded pkg and DMG cohort identity"
fi

for scenario_and_exit in rejected:65 timeout:75 network:75 credentials:70 malformed:70; do
  scenario="${scenario_and_exit%%:*}"
  expected_exit="${scenario_and_exit##*:}"
  if run_production_adapter "$scenario" notarize update-pkg fixture-profile "$work/fake.pkg" \
      >"$output" 2>&1; then
    bad "production adapter should reject notarization scenario $scenario"
  elif [[ "$?" -eq "$expected_exit" ]]; then
    ok "production Apple adapter maps $scenario notarization to exit $expected_exit"
  else
    sed 's/^/     /' "$output" >&2
    bad "production adapter returned the wrong status for $scenario"
  fi
done

printf 'package\n' >"$work/source.pkg"
if run_production_adapter accepted sign installer-pkg fixture-id \
    "$work/source.pkg" "$work/signed.pkg" >"$output" 2>&1 && [[ -s "$work/signed.pkg" ]]; then
  ok "production Apple adapter signs and verifies package output through PATH fakes"
else
  sed 's/^/     /' "$output" >&2
  bad "production package adapter CLI should be covered by fakes"
fi

if run_production_adapter tsa sign app fixture-id "$production_app" "$production_app" \
    >"$output" 2>&1; then
  bad "production adapter should surface TSA failure"
elif [[ "$?" -eq 75 ]]; then
  ok "production Apple adapter classifies TSA signing failure as retryable"
else
  bad "TSA signing failure should map to retryable exit 75"
fi
if run_production_adapter sign-error sign app fixture-id "$production_app" "$production_app" \
    >"$output" 2>&1; then
  bad "production adapter should surface deterministic signing failure"
elif [[ "$?" -eq 70 ]]; then
  ok "production Apple adapter keeps deterministic signing failure terminal"
else
  bad "deterministic signing failure should not be retried as TSA"
fi

printf 'dmg\n' >"$work/production.dmg"
if run_production_adapter accepted staple dmg "$work/production.dmg" >"$output" 2>&1 &&
   grep -q '^spctl ' "$production_log"; then
  ok "production Apple adapter validates stapled DMG with Gatekeeper"
else
  sed 's/^/     /' "$output" >&2
  bad "production DMG staple adapter should include Gatekeeper validation"
fi

if ! grep -Eq 'notarytool submit|productsign|stapler staple' \
      "$ROOT/Makefile" "$ROOT/package/sign_app" "$ROOT/package/make_package" \
      "$ROOT/package/make_update_package" "$ROOT/package/make_dmg" &&
   grep -qF 'release-cohort-state.py" seal' "$ROOT/package/sign_app" &&
   grep -qF 'release-cohort-state.py seal "$(RELEASE_OUTPUT_ROOT)" installer-pkg' "$ROOT/Makefile" &&
   grep -qF 'release-cohort-state.py seal "$(RELEASE_OUTPUT_ROOT)" update-pkg' "$ROOT/Makefile" &&
   grep -qF '"$COHORT_STATE" seal "$RELEASE_OUTPUT_ROOT" dmg' "$ROOT/package/make_dmg" &&
   grep -qF 'release-cohort-state.py" appcast-ready' "$ROOT/package/make_archive"; then
  ok "Make and package entrypoints delegate all four artifacts and appcast guard to cohort state"
else
  bad "release entrypoints must not retain copied Apple-tool transition sequences"
fi

success_root="$work/success cohort"
make_fixture "$success_root"
run_state tsa-retry seal "$success_root" app fixture-id fixture-profile >"$output" 2>&1
env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  python3 "$INVENTORY" record "$success_root" >>"$output" 2>&1
mkdir -p "$success_root/artifacts"
printf 'installer package\n' >"$success_root/artifacts/Famo.pkg"
printf 'update package\n' >"$success_root/artifacts/Famo-update.pkg"
embed_fake_cohort_id "$success_root" "$success_root/artifacts/Famo.pkg"
embed_fake_cohort_id "$success_root" "$success_root/artifacts/Famo-update.pkg"
run_state success register "$success_root" installer-pkg "$success_root/artifacts/Famo.pkg" >>"$output"
run_state success register "$success_root" update-pkg "$success_root/artifacts/Famo-update.pkg" >>"$output"
run_state success seal "$success_root" installer-pkg fixture-id fixture-profile >>"$output" 2>&1
run_state notary-retry seal "$success_root" update-pkg fixture-id fixture-profile >>"$output" 2>&1
printf 'disk image\n' >"$success_root/artifacts/Famo.dmg"
embed_fake_cohort_id "$success_root" "$success_root/artifacts/Famo.dmg"
run_state success register "$success_root" dmg "$success_root/artifacts/Famo.dmg" >>"$output"
run_state success seal "$success_root" dmg fixture-id fixture-profile >>"$output" 2>&1
python3 "$INVENTORY" check "$success_root" >>"$output" 2>&1

if python3 - "$success_root/release/FAMOTYPE-RELEASE-COHORT.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1]))
expected = {"app", "installer-pkg", "update-pkg", "dmg"}
assert state["status"] == "complete", state
assert set(state["artifacts"]) == expected, state
assert all(record["state"] == "stapled" for record in state["artifacts"].values()), state
PY
then
  ok "App, both packages, and DMG reach stapled through one cohort state machine"
else
  sed 's/^/     /' "$output" >&2
  bad "all four release artifacts should complete the shared state machine"
fi

if [[ "$(grep -c '^tsa-retry sign app ' "$mock_log")" -eq 3 ]] &&
   [[ "$(grep -c '^notary-retry notarize update-pkg ' "$mock_log")" -eq 3 ]]; then
  ok "TSA and notarization transient failures retry before succeeding"
else
  sed 's/^/     /' "$mock_log" >&2
  bad "transient Apple-tool failures should use bounded retries"
fi

printf 'replaced after completion\n' >>"$success_root/artifacts/Famo-update.pkg"
expect_fail "production appcast entrypoint rejects a replaced update package" \
  "artifact update-pkg does not match its cohort binding" \
  env RELEASE_OUTPUT_ROOT="$success_root" bash "$ROOT/package/make_archive"

cohort_a="$work/cohort A"
cohort_b="$work/cohort B"
make_fixture "$cohort_a"
run_state success seal "$cohort_a" app fixture-id fixture-profile >/dev/null
printf 'cohort A package\n' >"$cohort_a/Famo.pkg"
embed_fake_cohort_id "$cohort_a" "$cohort_a/Famo.pkg"

make_fixture "$cohort_b"
run_state success seal "$cohort_b" app fixture-id fixture-profile >/dev/null
cp "$cohort_a/Famo.pkg" "$cohort_b/Famo.pkg"
cp "$cohort_a/Famo.pkg.embedded-cohort-id" "$cohort_b/Famo.pkg.embedded-cohort-id"
before_release_calls="$(grep -Ec ' (sign|notarize|staple) ' "$mock_log" || true)"
expect_fail "full public registration rejects an unchanged artifact from another cohort" \
  "embeds a different cohort identity" \
  run_state success register "$cohort_b" installer-pkg "$cohort_b/Famo.pkg"
after_release_calls="$(grep -Ec ' (sign|notarize|staple) ' "$mock_log" || true)"
if [[ "$before_release_calls" -eq "$after_release_calls" ]]; then
  ok "foreign artifact rejection does not invoke signing or notarization"
else
  bad "foreign artifact rejection must happen before Apple tools"
fi

reject_root="$work/rejected cohort"
make_fixture "$reject_root"
expect_fail "notarization rejection fails the cohort" "notarize rejected" \
  run_state reject seal "$reject_root" app fixture-id fixture-profile
if [[ "$(grep -c '^reject notarize app ' "$mock_log")" -eq 1 ]] &&
   ! grep -q '^reject staple app ' "$mock_log" &&
   python3 - "$reject_root/release/FAMOTYPE-RELEASE-COHORT.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1]))
assert state["status"] == "failed", state
assert state["failure"] == {"artifact": "app", "phase": "notarize", "reason": "rejected"}, state
PY
then
  ok "rejected notarization is terminal and never staples"
else
  bad "rejected notarization must record one terminal failure without staple"
fi

if RELEASE_OUTPUT_ROOT="$reject_root" bash "$ROOT/package/make_archive" >"$output" 2>&1; then
  bad "failed cohort should not pass the production appcast entrypoint"
elif grep -q 'cohort is failed' "$output"; then
  ok "production appcast entrypoint rejects a failed cohort before Sparkle signing"
else
  sed 's/^/     /' "$output" >&2
  bad "production appcast entrypoint must stop before appcast generation"
fi

timeout_root="$work/timeout cohort"
make_fixture "$timeout_root"
expect_fail "notarization timeout exhausts its bounded retry budget" "notarize timeout" \
  run_state timeout seal "$timeout_root" app fixture-id fixture-profile
if [[ "$(grep -c '^timeout notarize app ' "$mock_log")" -eq 3 ]] &&
   ! grep -q '^timeout staple app ' "$mock_log" &&
   python3 - "$timeout_root/release/FAMOTYPE-RELEASE-COHORT.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1]))
assert state["status"] == "failed", state
assert state["failure"]["reason"] == "timeout", state
PY
then
  ok "notarization timeout fails without staple after three attempts"
else
  bad "notarization timeout must be bounded, terminal, and unstapled"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
