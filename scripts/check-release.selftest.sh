#!/usr/bin/env bash
# Regression tests for the public release gate/preflight surface. Uses only throwaway command stubs;
# no real credentials, artifacts, or Keychain profile names are read or printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-release.sh"
work="$(mktemp -d /tmp/famo-release-selftest.XXXXXX)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

mkdir -p "$work/valid-bin" "$work/invalid-bin"
cat > "$work/valid-bin/xcrun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$work/invalid-bin/xcrun" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$work/valid-bin/xcrun" "$work/invalid-bin/xcrun"

run_gate() {
  local bin_dir="$1"
  shift
  env PATH="$bin_dir:/usr/bin:/bin:/usr/sbin:/sbin" "$@" bash "$GATE" --preflight-only
}

output="$work/output"

# Public version seam used by package/appcast/release tooling. The replacement cohort must compare
# newer than the already-installed 1.4.17 build.
source "$ROOT/package/common.sh"
if [[ "$(get_marketing_version)" == "1.4.23" && "$(get_app_version)" == "1.4.23" ]]; then
  ok "release metadata identifies the Sparkle-enabled cohort as 1.4.23"
else
  bad "release metadata must identify the Sparkle-enabled cohort as 1.4.23"
fi

if env -u NOTARY_PROFILE PATH="$work/valid-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$GATE" --preflight-only >"$output" 2>&1; then
  bad "missing NOTARY_PROFILE should fail"
elif grep -q 'NOTARY_PROFILE' "$output"; then
  ok "missing NOTARY_PROFILE names the missing variable"
else
  bad "missing NOTARY_PROFILE diagnostic should name the variable"
fi

if run_gate "$work/invalid-bin" NOTARY_PROFILE=fixture-profile >"$output" 2>&1; then
  bad "unusable NOTARY_PROFILE should fail"
elif grep -q 'NOTARY_PROFILE.*不可用' "$output"; then
  ok "unusable NOTARY_PROFILE is reported without credential output"
else
  bad "unusable NOTARY_PROFILE diagnostic should identify the invalid profile variable"
fi

if env LC_ALL=C LANG=C PATH="$work/valid-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    NOTARY_PROFILE=fixture-profile bash "$GATE" --preflight-only >"$output" 2>&1 &&
    grep -q 'PASS:.*\.pinyin = rime_ice' "$output"; then
  ok "default locale parses and reports the expected pinyin schema"
else
  bad "default locale should complete the expected-pinyin preflight"
fi

if grep -qE '^NOTARY_PROFILE[[:space:]]*\?=[[:space:]]*\$\(DEV_ID\)' "$ROOT/Makefile"; then
  bad "Makefile must not infer NOTARY_PROFILE from DEV_ID/Team ID"
else
  ok "Makefile has no DEV_ID fallback for NOTARY_PROFILE"
fi

if grep -qE 'gh release|git archive|CLOUDFLARE_(DIR|PATH)|responsay.*appcast' "$ROOT/scripts/release.sh"; then
  bad "App release entrypoint must not own GitHub/source-archive/website composition"
else
  ok "App release entrypoint stays inside build/sign/notarize/package ownership"
fi

if grep -qE '^[[:space:]]*make[[:space:]]+archive([[:space:]]|$)' "$ROOT/scripts/release.sh"; then
  bad "App release entrypoint must not rebuild the phony package target while generating appcast"
else
  ok "App release entrypoint generates appcast without a second formal build"
fi

if grep -qE '^[[:space:]]*make[[:space:]]+package/sign_update([[:space:]]|$)' "$ROOT/scripts/release.sh"; then
  ok "App release entrypoint materializes the Sparkle signing helper explicitly"
else
  bad "App release entrypoint must materialize the Sparkle signing helper before appcast generation"
fi

if grep -q 'pass "G4' "$ROOT/scripts/check-release.sh"; then
  bad "automated-only gate must not label G4 as PASS"
else
  ok "automated-only gate keeps G4 visibly NEEDS_HUMAN"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
