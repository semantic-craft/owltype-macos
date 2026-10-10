#!/usr/bin/env bash
# Regression tests for the public release gate/preflight surface. Uses only throwaway command stubs;
# no real credentials, artifacts, or Keychain profile names are read or printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-release.sh"
work="$(mktemp -d /tmp/owl-release-selftest.XXXXXX)"
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
# release, so assert both independently populated version roles plus the 1.4.17 marketing floor.
source "$ROOT/package/common.sh"
marketing_version="$(get_marketing_version)"
app_version="$(get_app_version)"
newest_version="$(printf '%s\n' '1.4.17' "$marketing_version" | sort -V | tail -1)"
if [[ -n "$marketing_version" && -n "$app_version" \
      && "$marketing_version" != "1.4.17" && "$newest_version" == "$marketing_version" ]]; then
  ok "release metadata identifies marketing $marketing_version / Sparkle build $app_version"
else
  bad "release metadata must populate both version roles with marketing newer than 1.4.17 (marketing=${marketing_version:-unset} app=${app_version:-unset})"
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

if grep -qE 'gh release|git push|curl .*responsay|CLOUDFLARE_(DIR|PATH)' "$ROOT/scripts/release.sh"; then
  bad "release entrypoint must not publish remote state"
else
  ok "release entrypoint owns the local chain without publishing remote state"
fi

if [[ "$(grep -c 'run make release-artifacts' "$ROOT/scripts/release.sh")" -ne 1 ]] ||
   grep -qE '^[[:space:]]*(run )?make[[:space:]]+(archive|dmg|package)([[:space:]]|$)' \
     "$ROOT/scripts/release.sh"; then
  bad "release entrypoint must invoke one artifact graph without component-target re-entry"
else
  ok "release entrypoint invokes one artifact graph without a second formal build"
fi

if grep -q 'create-source-archive.sh' "$ROOT/scripts/release.sh" &&
   grep -q 'check-published-release.sh.*--dry-run' "$ROOT/scripts/release.sh" &&
   grep -q 'verify-chain' "$ROOT/scripts/check-published-release.sh" &&
   ! grep -qE 'curl|gh release' "$ROOT/scripts/check-published-release.sh"; then
  ok "source and local published gates remain inside the authoritative non-publishing flow"
else
  bad "authoritative release flow must bind source and keep the published gate local"
fi

if grep -q 'release-cohort-state.py" verify-chain' "$ROOT/scripts/check-release.sh" &&
   grep -q 'RELEASE_OUTPUT_ROOT=' "$ROOT/scripts/check-release.sh"; then
  ok "release artifact gate validates the selected cohort output root"
else
  bad "release artifact gate must consume the selected verified cohort"
fi

if grep -q 'pass "G4' "$ROOT/scripts/check-release.sh"; then
  bad "automated-only gate must not label G4 as PASS"
else
  ok "automated-only gate keeps G4 visibly NEEDS_HUMAN"
fi

for distribution in Distribution Distribution-update; do
  if [[ "$(xmllint --xpath 'count(//pkg-ref[@onConclusion="RequireLogout"])' "$ROOT/package/$distribution")" == 0 ]]; then
    ok "$distribution does not require logout"
  else
    bad "$distribution must not require logout"
  fi
done

# The package state stays root-owned; session actions use the captured console user.
if grep -qF 'install -d -o root -g wheel -m 700 "$markers"' "$ROOT/scripts/preinstall" \
   && grep -qF 'set -euo pipefail' "$ROOT/scripts/preinstall" \
   && grep -qF 'set -euo pipefail' "$ROOT/scripts/postinstall" \
   && grep -qF '"$staged_app/Contents/MacOS/Owltype" --commit-install' "$ROOT/scripts/postinstall" \
   && grep -qF '"$live_app/Contents/MacOS/Owltype" --finish-install' "$ROOT/scripts/postinstall" \
   && ! grep -qE 'schedule_deferred|killall|--register-input-source' "$ROOT/scripts/postinstall"; then
  ok "package uses protected phase state, atomic file commit and user-session activation"
else
  bad "package must fail closed and separate privileged files from user-session actions"
fi
if python3 "$ROOT/scripts/check-staged-pkg.py" --self-test; then
  ok "staged payload gate rejects live overwrite and directly registerable bundles"
else
  bad "staged payload gate regression"
fi

if grep -qF '["--disable-input-source"]' "$ROOT/installer/Sources/Installer.swift"; then
  ok "GUI uninstaller disables the Owltype TIS entry before deleting its bundle"
else
  bad "GUI uninstaller must not leave an enabled ghost input source behind"
fi

if grep -qF 'pkgutil --forget im.owltype.inputmethod.Owltype' "$ROOT/scripts/uninstall-owltype.sh" \
   && grep -qF 'pkgutil --forget im.owltype.inputmethod.Owltype' "$ROOT/installer/Sources/Installer.swift" \
   && ! grep -qF 'try? fileManager.removeItem(at: url)' "$ROOT/installer/Sources/Installer.swift" \
   && ! grep -qF 'pkgutil --forget im.owltype.inputmethod.Owltype >/dev/null 2>&1 || true' \
        "$ROOT/installer/Sources/Installer.swift"; then
  ok "both uninstall paths forget the Owltype PackageKit receipt"
else
  bad "complete uninstall must not leave the Owltype package receipt behind"
fi

if grep -qF 'SPARKLE_ED25519_ACCOUNT:-owltype-ed25519' "$ROOT/package/make_archive" \
   && grep -qF 'bridge requires explicit SPARKLE_ED25519_ACCOUNT=ed25519' "$ROOT/package/make_archive" \
   && grep -qF 'successor releases must use SPARKLE_ED25519_ACCOUNT=owltype-ed25519' "$ROOT/package/make_archive" \
   && grep -qF -- '--account "$sparkle_account"' "$ROOT/package/make_archive"; then
  ok "ordinary Owltype releases sign with the Owltype-specific Sparkle key account"
else
  bad "release signing must not silently fall back to the former shared Sparkle key"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
