#!/usr/bin/env bash
# Build the signed/notarized App-owned portion of an exact release cohort.
#
# Composition ownership intentionally stays outside this script. It does not create a source
# archive, mutate a GitHub release, or write/deploy a website appcast; the release operator
# consumes the App assets/appcast produced here.
set -euo pipefail

DEV_ID="${DEV_ID:?set DEV_ID to the Developer ID common name}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to the notarytool keychain profile name}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

echo "==> 1/5 validate signing and notarization readiness"
security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: ${DEV_ID}" || {
  echo >&2 "ERROR: Developer ID Application identity is unavailable"
  exit 1
}
security find-identity -v 2>/dev/null | grep -q "Developer ID Installer: ${DEV_ID}" || {
  echo >&2 "ERROR: Developer ID Installer identity is unavailable"
  exit 1
}
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  echo >&2 "ERROR: NOTARY_PROFILE points to an unavailable notarytool keychain profile"
  exit 1
}

echo "==> 2/5 assemble the pinned public seed"
make famo-seed

echo "==> 3/5 build, sign, notarize, and package the App cohort"
make dmg DEV_ID="$DEV_ID" NOTARY_PROFILE="$NOTARY_PROFILE"

echo "==> 4/5 generate the signed immutable appcast"
# Call the packaging helper directly. The Makefile `archive` target depends on the phony `package`
# target and would rebuild/re-notarize the cohort a second time.
make package/sign_update
[[ -x package/sign_update ]] || {
  echo >&2 "ERROR: Sparkle sign_update helper is unavailable"
  exit 1
}
bash package/make_archive

echo "==> 5/5 run App-owned automated artifact gates"
FAMO_IDENTITY_STRICT=1 bash scripts/check-identity-residual.sh
bash scripts/check-manifest.sh
bash scripts/check-release.sh --automated-only
# 出厂 app bundle 的密钥扫描。CI 侧同一道闸挂在 privacy-gate（那儿才装扫描器）；本地发版不走
# privacy-gate，所以这里显式再调一次。源码包那份由 create-source-archive.sh 自己扫。
bash scripts/check-secrets.sh --artifacts "build/Build/Products/Release/Famo.app" \
  "build/release/FAMOTYPE-FILE-MANIFEST.sha256" "build/release/FAMOTYPE-SBOM.spdx.json"

for artifact in package/Famo.dmg package/Famo.pkg package/Famo-update.pkg package/appcast.xml; do
  [[ -s "$artifact" ]] || {
    echo >&2 "ERROR: missing App cohort output: $artifact"
    exit 1
  }
  printf 'OUTPUT: %s\n' "$HERE/$artifact"
done

# 出厂盘点是给下载者验签用的（cd Famo.app && shasum -a 256 -c FAMOTYPE-FILE-MANIFEST.sha256），
# 只有跟着上架才有意义 —— 所以和 dmg/pkg 一样列进 OUTPUT，由发布环节一并上传。
for artifact in build/release/FAMOTYPE-FILE-MANIFEST.sha256 build/release/FAMOTYPE-SBOM.spdx.json; do
  [[ -s "$artifact" ]] || {
    echo >&2 "ERROR: missing App cohort output: $artifact"
    exit 1
  }
  printf 'OUTPUT: %s\n' "$HERE/$artifact"
done

# 三个上架产物必须**真的带着公证票**，而不只是「文件存在且非空」。
#
# 上面那圈 `-s` 检查对「一个签了名但没公证的 DMG」是完全放行的 —— 而那正是 1.5.13 出包时的实际
# 状态（公证凭据中途消失）。那次是靠 `make dmg` 自己挂掉才拦住的；一旦哪天失败发生在别的分支上、
# 或者有人手工补跑了某一步，这里就是最后一道闸。stapler 读的是产物里嵌着的票，离线可验，
# 不依赖任何网络或凭据 —— 也就是说这道闸在凭据已经消失的机器上照样有效。
for artifact in package/Famo.dmg package/Famo.pkg package/Famo-update.pkg; do
  xcrun stapler validate "$artifact" >/dev/null 2>&1 || {
    echo >&2 "ERROR: $artifact 没有公证票（stapler validate 不过）。"
    echo >&2 "       这种包发出去，新用户会被 Gatekeeper 拦住。"
    echo >&2 "       先确认公证凭据还在：xcrun notarytool history --keychain-profile \"\$NOTARY_PROFILE\""
    exit 1
  }
  printf 'STAPLED: %s\n' "$artifact"
done

printf 'PASS: App release cohort build complete; composition/publishing steps remain external\n'
