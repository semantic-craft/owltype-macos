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

NOTARY_PROFILE="${NOTARY_PROFILE:-xw-notary}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  pass "NOTARY_PROFILE keychain profile is available"
else
  fail "NOTARY_PROFILE 指向的 notarytool keychain profile 不可用"
fi

# 07-07-schema-consistency-guard: derive the packaged pinyin schema from the App source of truth.
# Keep every expansion braced when adjacent to CJK punctuation: under some locale/Bash combinations,
# an unbraced name can be parsed past the intended variable boundary and trip `set -u`.
expected_pinyin=$(grep -oE 'case \.pinyin: return "[a-z][a-z0-9_]*"' "$ROOT/sources/Settings/OwlKeyboardPreferences.swift" | sed -E 's/.*"([a-z0-9_]+)".*/\1/' | head -1)
[[ -n "$expected_pinyin" ]] || fail "cannot derive expected pinyin schema from OwlKeyboardPreferences.swift"
pass "代码默认拼音 schema 已解析（.pinyin = ${expected_pinyin}）"

if (( preflight_only )); then
  pass "release environment preflight complete"
  exit 0
fi

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
pass "Release app carries license and third-party notices"

codesign_details=$(/usr/bin/codesign -dv --verbose=2 "$APP" 2>&1)
if grep -q '^Authority=Developer ID Application:' <<<"$codesign_details"; then
  pass "Release app is Developer ID Application signed"
else
  block "Release app is not Developer ID Application signed"
fi

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

# 方案B（2026-07-24）：公开 pkg 只携带清洁室种子（owl-seed.sh：owltype_base 词库 +
# Unihan 单字表兜底），完整词库（雾凇 cn_dicts/en_dicts、KyleBing 五笔、octagram gram）由 App
# 首启在用户侧按 dict-pack manifest 拉取，绝不进公开 payload。旧的「payload 必含 wubi/pinyin_simp」
# 断言属全量种子时代，已按新口径改写为反向断言。
# 2026-07-25：essay.txt 随 rime-essay 一并移出种子（繁体字形 + LGPL 数据项，见 PR #22），
# 这里改为断言取代它的 owltype_base；本组断言要真 pkg 才跑得到，CI 只到 make package，
# 所以 1.5.1 出包时才逮住这处陈旧断言。
tmp=$(mktemp -u /tmp/owl-pkg.XXXXXX)
tmp_update=$(mktemp -u /tmp/owl-update-pkg.XXXXXX)
trap 'rm -rf "$tmp" "$tmp_update"' EXIT

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
	  './Owltype.app/Contents/SharedSupport/OWLTYPE-SEED-MANIFEST.txt' \
	  './Owltype.app/Contents/SharedSupport/owltype.yaml' \
	  './Owltype.app/Contents/SharedSupport/rime_ice.schema.yaml' \
	  './Owltype.app/Contents/SharedSupport/rime_ice.dict.yaml' \
  './Owltype.app/Contents/SharedSupport/cn_dicts/owltype_unicode.dict.yaml' \
  './Owltype.app/Contents/SharedSupport/cn_dicts/owltype_base.dict.yaml'
do
  grep -qxF "$path" <<<"$payload" || fail "pkg payload missing $path"
done
grep -qxF './Owltype.app/Contents/SharedSupport/_user_seed/owltype.custom.yaml' <<<"$payload" ||
  fail "pkg payload missing Owltype _user_seed/owltype.custom.yaml"
if grep -qxF './Owltype.app/Contents/SharedSupport/squirrel.yaml' <<<"$payload" ||
   grep -qxF './Owltype.app/Contents/SharedSupport/_user_seed/squirrel.custom.yaml' <<<"$payload"; then
  fail "pkg payload still carries Squirrel frontend config names"
fi
# 反倒退：dict-pack 载荷（未过再分发审计的第三方词库）绝不允许出现在公开 payload 里。
for forbidden in \
  '/cn_dicts/base\.dict\.yaml$' \
  '/cn_dicts/8105\.dict\.yaml$' \
  '/cn_dicts/tencent\.dict\.yaml$' \
  '/en_dicts/' \
  '\.gram$' \
  '/wubi86_jidian'
do
  if grep -qE "$forbidden" <<<"$payload"; then
    fail "pkg payload carries dict-pack material (matched: $forbidden) — 完整词库只能用户侧拉取，不得随包再分发"
  fi
done
pass "pkg payload = 清洁室种子（rime_ice + owltype_base + owltype_unicode），无 dict-pack 再分发载荷"

# 07-07-schema-consistency-guard: cross-check the payload's 拼音 schema against the code's default
# (OwlKeyboardPreferences .pinyin), so a future schema rename / stale seed can't silently ship a
# payload whose pinyin base no longer matches what the app selects at runtime. Derives the expected
# id from source (single truth) instead of hardcoding it.
grep -qxF "./Owltype.app/Contents/SharedSupport/${expected_pinyin}.schema.yaml" <<<"$payload" ||
  fail "pkg payload 拼音 schema 不符：代码默认 .pinyin = ${expected_pinyin}，但 payload 无 ${expected_pinyin}.schema.yaml（seed 陈旧？重跑 make owl-seed 再发版）"
pass "pkg payload 拼音 schema 与代码默认一致（.pinyin = ${expected_pinyin}）"

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

# 方案B：静态 _user_seed 只启用 rime_ice（清洁室基线）。五笔/双拼/简体拼音的 schema_list
# 由 App 首启的 OwlManagedKeyboardPatchPlan 按当前偏好写入（setupRime，seed 之后、首次
# deploy 之前），其源文件由 dict-pack 用户侧拉取后补建 —— 静态种子里再断言全套属全量种子
# 时代的陈旧期望（2026-07-24 1.5.0 出包时逮住）。
seed="$pkg_app/Contents/SharedSupport/_user_seed/default.custom.yaml"
grep -q "schema: rime_ice" "$seed" || fail "pkg seed does not enable rime_ice"
pass "pkg seed 启用清洁室基线（rime_ice；全套 schema_list 由首启 managed patch + dict-pack 接管）"
# emoji 出厂关 = 共享 rime_ice.schema.yaml 的 reset（不在 _user_seed）。纯雾凇无带声调 preedit。
ice_schema="$pkg_app/Contents/SharedSupport/rime_ice.schema.yaml"
grep -A3 'name: emoji' "$ice_schema" | grep -q 'reset: 0' ||
  fail "pkg rime_ice.schema.yaml does not default emoji off (reset: 0)"
pass "pkg rime_ice default: emoji off"
# emoji off 态标签 = 👍（rime-ice 默认 💀 骷髅；reset 每次部署都弹一次 toast，2026-07-26 用户要求换）。
grep -A3 'name: emoji' "$ice_schema" | grep -q 'states: \[ 👍, 😄 \]' ||
  fail "pkg rime_ice.schema.yaml emoji states not [ 👍, 😄 ] (skull regression?)"
pass "pkg rime_ice emoji off label: 👍"
# ascii_mode 英文态标签 = 英（rime-ice 默认「Ａ」；task 06-27 用户要求，2026-07-26 搬入公开种子）。
grep -A3 'name: ascii_mode' "$ice_schema" | grep -q 'states: \[ 中, 英 \]' ||
  fail "pkg rime_ice.schema.yaml ascii_mode states not [ 中, 英 ]"
pass "pkg rime_ice ascii_mode label: 中/英"

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
