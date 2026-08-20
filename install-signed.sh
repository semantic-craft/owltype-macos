#!/usr/bin/env bash
# 本地测试安装：Developer-ID 正确签名(+entitlements,硬化运行时) → 装到 /Library/Input Methods → 重注册。
#
# 为什么需要它：`make install-release` 末尾的 copy-famo-seed 会用「ad-hoc 无 entitlements」重签，
# 装出来的输入法能显示但**不能打字**（缺 disable-library-validation，librime dylib 加载受限）。
# 本脚本在那之后补一次 Developer-ID 签名，恢复成可用的输入法。
#
# 用法：
#   bash install-signed.sh             # 重新构建 Release → 签名 → 安装（调间距/改代码后用这个）
#   bash install-signed.sh --no-build  # 跳过构建，只对现有产物签名 → 安装（产物已构建好时用这个）
#
# 注意：不要用 `sudo bash install-signed.sh` —— codesign 要用你（当前用户）钥匙串里的私钥；
#       脚本只对「安装到系统目录」这一步内部自行 sudo（会提示一次密码）。
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Build/Products/Release/Famo.app"
DSTROOT="/Library/Input Methods"
ENT="resources/Owltype.entitlements"

DEV_ID="$(security find-identity -v -p codesigning | sed -nE 's/.*"Developer ID Application: (.*)".*/\1/p' | head -1)"
[ -n "$DEV_ID" ] || { echo "❌ 找不到 Developer ID Application 签名身份（security find-identity）"; exit 1; }
echo "▸ 签名身份: $DEV_ID"

if [ "${1:-}" != "--no-build" ]; then
  echo "▸ 构建 Release（增量）…"
  make release
fi
[ -d "$APP" ] || { echo "❌ 找不到构建产物 ${APP}（先去掉 --no-build 让它构建）"; exit 1; }

echo "▸ Developer-ID 签名（+entitlements + 硬化运行时）…"
codesign --deep --force --options runtime \
  --sign "Developer ID Application: $DEV_ID" \
  --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"
echo "  校验:"; codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer|flags" | sed 's/^/    /'

echo "▸ 安装到 ${DSTROOT}（需要你的 Mac 密码）…"
sudo rm -rf "$DSTROOT/Famo.app"
sudo cp -R "$APP" "$DSTROOT/Famo.app"

echo "▸ 重新注册 + 重启输入法…"
F="$DSTROOT/Famo.app/Contents/MacOS/Famo"
"$F" --register-input-source
"$F" --enable-input-source
"$F" --quit || true
"$F" --select-input-source
echo "✅ 完成。切到法墨（Ctrl+Space）打字试试。"
