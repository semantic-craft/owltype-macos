#!/usr/bin/env bash
# Read-only release artifact gate. It audits the current Release app/pkg; it does
# not sign, notarize, staple, install, or submit anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/owl-identity.sh
. "$ROOT/scripts/owl-identity.sh"

RELEASE_OUTPUT_ROOT="${RELEASE_OUTPUT_ROOT:-$ROOT/build}"
APP="$RELEASE_OUTPUT_ROOT/Build/Products/Release/Owltype.app"
PKG="$ROOT/package/Owltype.pkg"
UPDATE_PKG="$ROOT/package/Owltype-update.pkg"
APPCAST="$ROOT/package/appcast.xml"
CHINESE_IME_LM_CRATE_LICENSE_SHA256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
PYTHON_PINYIN_LICENSE_SHA256="1e6c90014b4912815c296ee64bb6f6280af47e6d4c5d80e86232dfc5defe764c"
WUBI86_JIDIAN_LICENSE_SHA256="43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"
# Manual smoke evidence lives outside the public tree; point OWL_MANUAL_SMOKE at the current
# release's manual-host-app-smoke document.
MANUAL_SMOKE="${OWL_MANUAL_SMOKE:-}"
DOMAIN="$OWL_BUNDLE_ID"
blocked=0
preflight_only=0
automated_only=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
block() { printf 'BLOCKED: %s\n' "$1"; blocked=1; }
needs_human() { printf 'NEEDS_HUMAN: %s\n' "$1"; }

usage() {
  printf 'usage: %s [--preflight-only | --automated-only]\n' "${0##*/}"
}

case "${1:-}" in
  "") ;;
  --preflight-only) preflight_only=1 ;;
  --automated-only) automated_only=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; fail "unknown argument: $1" ;;
esac

NOTARY_PROFILE="${NOTARY_PROFILE:-owltype-notary}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  pass "NOTARY_PROFILE keychain profile is available"
else
  fail "NOTARY_PROFILE 指向的 notarytool keychain profile 不可用"
fi

if (( preflight_only )); then
  pass "release environment preflight complete"
  exit 0
fi

# Receipt and UUIDs survive release signing; reject the old prebuilt Updater.
python3 "$ROOT/scripts/build-sparkle.py" --check "$APP/Contents/Frameworks/Sparkle.framework"

python3 "$ROOT/scripts/release-cohort-state.py" verify-chain "$RELEASE_OUTPUT_ROOT"

[[ -d "$APP" ]] || fail "Release app not found: $APP"
[[ -f "$PKG" ]] || fail "package not found: $PKG"
[[ -f "$UPDATE_PKG" ]] || fail "update package not found: $UPDATE_PKG"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
pass "Release app codesign verifies"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[[ "$bundle_id" == "$DOMAIN" ]] || fail "unexpected bundle id: $bundle_id"
pass "Release bundle id is $DOMAIN"

[[ -s "$APP/Contents/Resources/LICENSE.txt" ]] || fail "Release app missing LICENSE.txt"
[[ -s "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || fail "Release app missing THIRD_PARTY_NOTICES.md"
source_crate_license="$APP/Contents/SharedSupport/licenses/chinese-ime-lm.LICENSE"
[[ -s "$source_crate_license" ]] ||
  fail "Release app missing chinese-ime-lm source crate LICENSE"
printf '%s  %s\n' "$CHINESE_IME_LM_CRATE_LICENSE_SHA256" "$source_crate_license" |
  shasum -a 256 --check --status ||
  fail "Release app chinese-ime-lm source crate LICENSE differs from the pinned text"
python_pinyin_license="$APP/Contents/SharedSupport/python-pinyin.LICENSE"
[[ -s "$python_pinyin_license" ]] ||
  fail "Release app missing python-pinyin LICENSE"
printf '%s  %s\n' "$PYTHON_PINYIN_LICENSE_SHA256" "$python_pinyin_license" |
  shasum -a 256 --check --status ||
  fail "Release app python-pinyin LICENSE differs from the pinned text"
wubi_license="$APP/Contents/SharedSupport/wubi86-jidian.LICENSE"
[[ -s "$wubi_license" ]] ||
  fail "Release app missing rime-wubi86-jidian LICENSE"
printf '%s  %s\n' "$WUBI86_JIDIAN_LICENSE_SHA256" "$wubi_license" |
  shasum -a 256 --check --status ||
  fail "Release app rime-wubi86-jidian LICENSE differs from the pinned text"
pass "Release app carries license, third-party notices, and pinned component licenses"

python3 "$ROOT/scripts/check-rust-delivery.py" "$APP"
pass "Release app delivers the Rust engine without the legacy Rime runtime"

python3 "$ROOT/scripts/fetch-rerank-models.py" --check \
  --out "$APP/Contents/SharedSupport/msime/models"
pass "Release app rerank models and notices match the lock"

codesign_details=$(/usr/bin/codesign -dv --verbose=2 "$APP" 2>&1)
if grep -q '^Authority=Developer ID Application:' <<<"$codesign_details"; then
  pass "Release app is Developer ID Application signed"
else
  block "Release app is not Developer ID Application signed"
fi

# #208: OwlAgentBridge accepts a connection only from code signed by the App's own team, so the
# helper must carry the same Team ID, under the hardened runtime, as the App.
helper="$APP/Contents/Helpers/owltype-mcp"
/usr/bin/codesign --verify --strict --verbose=2 "$helper" || fail "MCP helper codesign does not verify"
helper_details=$(/usr/bin/codesign -dv --verbose=2 "$helper" 2>&1)
app_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$codesign_details")
helper_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_details")
if [[ -z "$app_team" || "$app_team" == "not set" ]]; then
  block "Release app has no Team ID, so the MCP helper's team cannot be checked"
fi
[[ "$helper_team" == "$app_team" ]] ||
  fail "MCP helper Team ID ${helper_team:-none} differs from the App's $app_team"
grep -q '^CodeDirectory .*flags=.*runtime' <<<"$helper_details" ||
  fail "MCP helper is not signed with the hardened runtime"
pass "MCP helper is signed by the App's team ($app_team) with the hardened runtime"

# #116：Apple Events 授权前置。1.4.7 发货了「更新后强推注销」（OwlUpdateLogoutPrompt），但 hardened
# runtime 下缺 entitlement 或 usage string，发 Apple 事件直接 errAEEventNotPermitted (-1743) 且 TCC
# 连授权框都不弹 —— 主按钮从未生效过，每次都体面地退化成「请手动注销」，失败被 fallback 文案掩盖着。
# 必须查【产物】不查源文件：Xcode 处理 Info.plist、codesign 把 entitlement 落进签名，只有从产物读回
# 来的才是真会出厂的东西（同 07-08 app_options 的教训：只断言写出去的 patch 是假覆盖）。
assert_apple_events_prereqs() {
  local app="$1" label="$2" usage
  /usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null |
    grep -q 'com.apple.security.automation.apple-events' ||
    fail "$label 签名缺 com.apple.security.automation.apple-events（hardened runtime 下注销必 -1743，主按钮点不动）"
  usage=$(/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$app/Contents/Info.plist" 2>/dev/null || true)
  [[ -n "$usage" ]] ||
    fail "$label Info.plist 缺 NSAppleEventsUsageDescription（缺它 TCC 不弹授权框，主按钮点不动）"
  pass "$label 带齐 Apple Events 授权前置（automation.apple-events + NSAppleEventsUsageDescription）"
}
assert_apple_events_prereqs "$APP" "Release app"

if /usr/sbin/spctl -a -vv -t exec "$APP"; then
  pass "Gatekeeper accepts Release app"
else
  block "Gatekeeper rejects Release app"
fi

if xcrun stapler validate "$APP"; then
  pass "Release app stapled notarization ticket validates"
else
  block "Release app has no valid stapled notarization ticket"
fi

# The package carries the pinned official full pinyin/English/context set, Owl Wubi,
# and the audited emoji derivative. Restricted auxiliary catalogs stay excluded.
tmp_parent=$(mktemp -d "${TMPDIR:-/tmp}/owl-pkg.XXXXXX")
tmp="$tmp_parent/expanded"
tmp_update_parent=$(mktemp -d "${TMPDIR:-/tmp}/owl-update-pkg.XXXXXX")
tmp_update="$tmp_update_parent/expanded"
cleanup_packages() {
  local status=$?
  trap - EXIT
  for path in "$tmp_parent" "$tmp_update_parent"; do
    if ! python3 "$ROOT/scripts/cleanup_app_registrations.py" --remove "$path"; then
      [[ "$status" != 0 ]] || status=1
    fi
  done
  exit "$status"
}
trap cleanup_packages EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pkgutil --expand-full "$PKG" "$tmp"
package_info="$tmp/Owltype-component.pkg/PackageInfo"
grep -q 'identifier="im.owltype.inputmethod.Owltype"' "$package_info" || fail "pkg identifier mismatch"
pkg_app="$(python3 "$ROOT/scripts/check-staged-pkg.py" "$tmp/Owltype-component.pkg" --extract-to "$tmp/checked-app")"
pass "pkg metadata is Owltype with an inert archive payload at the root install location"

# Audit the actual archived App contents, not only the outer archive filename.
payload=$(cd "$tmp/checked-app" && find ./Owltype.app -print)
for path in \
	  './Owltype.app/Contents/Resources/LICENSE.txt' \
	  './Owltype.app/Contents/Resources/THIRD_PARTY_NOTICES.md' \
	  './Owltype.app/Contents/SharedSupport/licenses/chinese-ime-lm.LICENSE' \
	  './Owltype.app/Contents/SharedSupport/wubi86-jidian.LICENSE' \
	  './Owltype.app/Contents/SharedSupport/rime-kaomoji.LICENSE' \
	  './Owltype.app/Contents/SharedSupport/python-pinyin.LICENSE' \
	  './Owltype.app/Contents/SharedSupport/OWLTYPE-SEED-MANIFEST.txt' \
	  './Owltype.app/Contents/SharedSupport/msime-others-NOTICE.txt' \
	  './Owltype.app/Contents/SharedSupport/msime/msime-pinyin.db' \
	  './Owltype.app/Contents/SharedSupport/msime/msime-wubi.db' \
	  './Owltype.app/Contents/SharedSupport/msime/msime-english.db' \
	  './Owltype.app/Contents/SharedSupport/msime/msime-others.db' \
	  './Owltype.app/Contents/SharedSupport/msime/msime-bigram.bin' \
	  './Owltype.app/Contents/SharedSupport/msime/msime-trigram.bin' \
	  './Owltype.app/Contents/SharedSupport/msime/OWLTYPE-UPSTREAM-RESOURCES.json' \
	  './Owltype.app/Contents/SharedSupport/msime-resources-NOTICE.md' \
	  './Owltype.app/Contents/SharedSupport/licenses/CC-BY-SA-4.0.txt'
do
  grep -qxF "$path" <<<"$payload" || fail "pkg payload missing $path"
done
pkg_source_crate_license="$tmp/checked-app/Owltype.app/Contents/SharedSupport/licenses/chinese-ime-lm.LICENSE"
printf '%s  %s\n' "$CHINESE_IME_LM_CRATE_LICENSE_SHA256" "$pkg_source_crate_license" |
  shasum -a 256 --check --status ||
  fail "pkg payload chinese-ime-lm source crate LICENSE differs from the pinned text"
pkg_python_pinyin_license="$tmp/checked-app/Owltype.app/Contents/SharedSupport/python-pinyin.LICENSE"
printf '%s  %s\n' "$PYTHON_PINYIN_LICENSE_SHA256" "$pkg_python_pinyin_license" |
  shasum -a 256 --check --status ||
  fail "pkg payload python-pinyin LICENSE differs from the pinned text"
pkg_wubi_license="$tmp/checked-app/Owltype.app/Contents/SharedSupport/wubi86-jidian.LICENSE"
printf '%s  %s\n' "$WUBI86_JIDIAN_LICENSE_SHA256" "$pkg_wubi_license" |
  shasum -a 256 --check --status ||
  fail "pkg payload rime-wubi86-jidian LICENSE differs from the pinned text"
for forbidden in \
  '/cn_dicts/' \
  '/en_dicts/' \
  '/lua/' \
  '/opencc/' \
  '\.yaml$' \
  '\.lua$' \
  '\.gram$' \
  '/wubi86_jidian'
do
  if grep -qE "$forbidden" <<<"$payload"; then
    fail "pkg payload carries legacy Rime or dict-pack material (matched: $forbidden)"
  fi
done
pass "pkg payload carries the Rust SQLite resources and no dict-pack redistribution material"

assert_installer_scripts() {
  local component_root="$1" label="$2" package_info_path="$1/PackageInfo"
  grep -q '<preinstall file=' "$package_info_path" ||
    fail "$label PackageInfo declares no preinstall script"
  grep -q '<postinstall file=' "$package_info_path" ||
    fail "$label PackageInfo declares no postinstall script"
  for installer_script in preinstall postinstall; do
    installer_script_path="$component_root/Scripts/$installer_script"
    [[ -f "$installer_script_path" && ! -L "$installer_script_path" && -x "$installer_script_path" ]] ||
      fail "$label Scripts/$installer_script must be an executable regular file, not a symlink"
  done
  unexpected_installer_script="$(find "$component_root/Scripts" -mindepth 1 \
    ! -path "$component_root/Scripts/preinstall" \
    ! -path "$component_root/Scripts/postinstall" -print -quit)"
  [[ -z "$unexpected_installer_script" ]] ||
    fail "$label Scripts contains files beyond preinstall/postinstall: ${unexpected_installer_script##*/}"
}

python3 "$ROOT/scripts/check-rust-delivery.py" "$pkg_app"
pass "pkg payload app delivers the Rust engine without the legacy Rime runtime"

python3 "$ROOT/scripts/fetch-rerank-models.py" --check \
  --out "$pkg_app/Contents/SharedSupport/msime/models"
pass "pkg payload app rerank models and notices match the lock"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$pkg_app"
pass "pkg payload app codesign verifies"

# 真正出厂的是 pkg 里这份 app，不是 build/ 里那份 —— 前置断言在两处都跑。
assert_apple_events_prereqs "$pkg_app" "pkg payload app"

# pkg 必须携带 preinstall（payload 落盘前写「bundle 已存在」标记）+ postinstall（读标记走更新/首装
# 分支）。缺 preinstall = Sparkle 更新会被误判成首装（Sparkle 先杀宿主 Owltype，pgrep 单独不可靠）。
# 光查 Scripts/ 里文件存在不够——pkgbuild --scripts 会原样拷整个目录，真正决定「会不会运行」的是
# PackageInfo 里的 <preinstall>/<postinstall> 声明（pkgbuild 按 文件名+可执行位 自动接线）。
assert_installer_scripts "$tmp/Owltype-component.pkg" "Owltype.pkg"
python3 "$ROOT/scripts/check-staged-pkg.py" "$tmp/Owltype-component.pkg"
pass "Owltype.pkg carries exactly preinstall + postinstall and wires both executable scripts"

# Both installation paths must finish within the current login session.
require_logout_count() { xmllint --xpath 'count(//pkg-ref[@onConclusion="RequireLogout"])' "$1"; }
[[ "$(require_logout_count "$tmp/Distribution")" == "0" ]] ||
  fail "Owltype.pkg Distribution still carries onConclusion=RequireLogout"
pass "Owltype.pkg Distribution has no RequireLogout"

pkgutil --expand-full "$UPDATE_PKG" "$tmp_update"
[[ "$(require_logout_count "$tmp_update/Distribution")" == "0" ]] ||
  fail "Owltype-update.pkg Distribution still carries onConclusion=RequireLogout (updates must not force logout)"
grep -q 'Owltype-component.pkg' "$tmp_update/Distribution" ||
  fail "Owltype-update.pkg Distribution does not reference Owltype-component.pkg"
assert_installer_scripts "$tmp_update/Owltype-component.pkg" "Owltype-update.pkg"
update_archive="$(python3 "$ROOT/scripts/check-staged-pkg.py" "$tmp_update/Owltype-component.pkg")"
installer_archive="$(python3 "$ROOT/scripts/check-staged-pkg.py" "$tmp/Owltype-component.pkg")"
cmp "$installer_archive" "$update_archive" || fail "installer/update pkg App archives differ"
pass "Owltype-update.pkg Distribution has no RequireLogout (no-logout Sparkle payload)"

[[ -s "$APPCAST" ]] || fail "signed appcast is missing"
xmllint --xpath 'boolean(//*[local-name()="enclosure"][@*[local-name()="installationType"]="package"])' "$APPCAST" |
  grep -qx true ||
  fail "appcast enclosure does not declare sparkle:installationType=package"
enclosure_url="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST")"
app_version="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="version"])' "$APPCAST")"
expected_url="$(python3 "$ROOT/scripts/owl_distribution.py" asset-url "$app_version" Owltype-update.pkg)"
[[ "$enclosure_url" != *github.com* ]] ||
  fail "appcast enclosure must not use a GitHub Release URL"
[[ "$enclosure_url" == "$expected_url" ]] ||
  fail "appcast enclosure does not use the immutable public source/release URL"
pass "appcast uses an explicit package installer and immutable public source/release URL"

if pkgutil --check-signature "$PKG"; then
  pass "pkg signature verifies"
else
  block "pkg is not signed"
fi

if /usr/sbin/spctl -a -vv -t install "$PKG"; then
  pass "Gatekeeper accepts pkg"
else
  block "Gatekeeper rejects pkg"
fi

if xcrun stapler validate "$PKG"; then
  pass "pkg stapled notarization ticket validates"
else
  block "pkg has no valid stapled notarization ticket"
fi

if pkgutil --check-signature "$UPDATE_PKG"; then
  pass "update pkg signature verifies"
else
  block "update pkg is not signed"
fi

if /usr/sbin/spctl -a -vv -t install "$UPDATE_PKG"; then
  pass "Gatekeeper accepts update pkg"
else
  block "Gatekeeper rejects update pkg"
fi

if xcrun stapler validate "$UPDATE_PKG"; then
  pass "update pkg stapled notarization ticket validates"
else
  block "update pkg has no valid stapled notarization ticket"
fi

if security find-identity -v -p basic | grep -q 'Developer ID Installer:'; then
  pass "Developer ID Installer certificate exists"
else
  block "Developer ID Installer certificate not found"
fi

if (( automated_only )); then
  needs_human "G4 manual host-app smoke is excluded from the automated-only result"
elif [[ -f "$MANUAL_SMOKE" ]] && grep -q '^Status: PASS$' "$MANUAL_SMOKE"; then
  pass "manual host-app smoke is marked PASS"
else
  block "manual host-app smoke is not marked PASS (set OWL_MANUAL_SMOKE to the evidence document)"
fi

if (( blocked )); then
  exit 2
fi
pass "release artifact gate complete"
