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
profile=""
while (($#)); do
  if [[ "$1" == "--keychain-profile" ]]; then
    profile="${2:-}"
    break
  fi
  shift
done
if [[ -n "${EXPECTED_NOTARY_PROFILE:-}" && "$profile" != "$EXPECTED_NOTARY_PROFILE" ]]; then
  exit 64
fi
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
# newer than the already-installed 1.4.17 build. Pinning a literal version here goes stale at every
# release, so assert the seam's shape (both fields agree) plus the 1.4.17 floor instead.
source "$ROOT/package/common.sh"
marketing_version="$(get_marketing_version)"
app_version="$(get_app_version)"
newest_version="$(printf '%s\n' '1.4.17' "$marketing_version" | sort -V | tail -1)"
if [[ -n "$marketing_version" && "$marketing_version" == "$app_version" \
      && "$marketing_version" != "1.4.17" && "$newest_version" == "$marketing_version" ]]; then
  ok "release metadata identifies the Sparkle-enabled cohort as $marketing_version (newer than 1.4.17)"
else
  bad "release metadata must identify one Sparkle-enabled cohort newer than 1.4.17 (marketing=${marketing_version:-unset} app=${app_version:-unset})"
fi

if env -u NOTARY_PROFILE EXPECTED_NOTARY_PROFILE=xw-notary \
    PATH="$work/valid-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$GATE" --preflight-only >"$output" 2>&1; then
  ok "missing NOTARY_PROFILE uses the canonical xw-notary profile"
else
  bad "missing NOTARY_PROFILE should use the canonical xw-notary profile"
fi

if run_gate "$work/invalid-bin" NOTARY_PROFILE=fixture-profile >"$output" 2>&1; then
  bad "unusable NOTARY_PROFILE should fail"
elif grep -q 'NOTARY_PROFILE.*不可用' "$output"; then
  ok "unusable NOTARY_PROFILE is reported without credential output"
else
  bad "unusable NOTARY_PROFILE diagnostic should identify the invalid profile variable"
fi

if env LC_ALL=C LANG=C PATH="$work/valid-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    NOTARY_PROFILE=fixture-profile EXPECTED_NOTARY_PROFILE=fixture-profile \
    bash "$GATE" --preflight-only >"$output" 2>&1 &&
    grep -q 'PASS:.*\.pinyin = rime_ice' "$output"; then
  ok "explicit NOTARY_PROFILE overrides the canonical default and the locale parses"
else
  bad "explicit NOTARY_PROFILE should override the canonical default"
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
