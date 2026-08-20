#!/usr/bin/env bash
# 输入源恢复链路体检：重启后跑它，看装机输入法有没有被正确恢复。
#
# 自动探测 /Library/Input Methods 与 ~/Library/Input Methods 里的输入法，
# 不硬编码 bundle id —— 改名（法墨 → 猫头鹰）后无需修改，2.0.0 装机验收可直接复用。
#
#   scripts/ime-check.sh              # 自动探测
#   scripts/ime-check.sh <bundle-id>  # 只看指定的一个
set -uo pipefail
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

declare -a IMES=()
if [[ $# -ge 1 ]]; then
  IMES=("$1")
else
  for app in "/Library/Input Methods"/*.app "$HOME/Library/Input Methods"/*.app; do
    [[ -d "$app" ]] || continue
    bid="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)" || continue
    IMES+=("$bid")
  done
fi
[[ ${#IMES[@]} -gt 0 ]] || { echo "没有找到已安装的输入法"; exit 1; }

printf '开机时间: %s\n' "$(uptime | sed 's/^ *//')"
printf '装机输入法: %s\n\n' "${IMES[*]}"

dump_key() {  # plist-path  key
  plutil -extract "$2" xml1 -o - "$1" 2>/dev/null \
    | grep -E "<string>" | sed 's/.*<string>/  /; s|</string>||'
}

echo "== 本次登录恢复的输入源 (AppleSelectedInputSources) =="
dump_key "$HOME/Library/Preferences/com.apple.HIToolbox.plist" AppleSelectedInputSources

echo
echo "== 第三方输入源顺序，第一个 = 菜单最前 =="
dump_key "$HOME/Library/Preferences/com.apple.inputsources.plist" AppleEnabledThirdPartyInputSources

echo
echo "== LaunchServices 认领（每个 id 应只有 1 条，且带 teamID）=="
for bid in "${IMES[@]}"; do
  printf '  --- %s ---\n' "$bid"
  "$LSR" -dump 2>/dev/null \
    | awk -v want="$bid" '
        /^path:/       { p=$0; sub(/^path:[[:space:]]*/,"",p); sub(/ \(0x[0-9a-f]+\)$/,"",p); t="" }
        /^teamID:/     { t=$0; sub(/^teamID:[[:space:]]*/,"",t) }
        /^identifier:/ { id=$0; sub(/^identifier:[[:space:]]*/,"",id)
                         if (id==want) printf "    teamID=%-12s %s\n", (t==""?"(无签名!)":t), p }
      '
done

echo
echo "== 输入法进程 =="
pgrep -fl "Input Methods" | sed 's/^/  /' || echo "  (无输入法进程)"
