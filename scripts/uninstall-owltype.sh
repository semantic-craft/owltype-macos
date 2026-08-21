#!/usr/bin/env bash
# 猫头鹰 Owltype 卸载器 — 严格白名单。只清猫头鹰自己的文件；绝不触碰 Squirrel、~/Library/Rime、
# 搜狗或你的任何其他输入法。删除目标固定在 TARGETS 数组里（全是 Owltype 自己的路径）；
# 脚本中出现 “Squirrel / Rime” 字样的地方都是「安全闸」和给用户的安抚提示，不是删除目标。
#
# 用法：
#   bash uninstall-owltype.sh            # 交互确认后卸载
#   bash uninstall-owltype.sh --dry-run  # 只打印将删除什么，不动手
#   bash uninstall-owltype.sh --yes      # 跳过确认（脚本化场景）
set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

APP="/Library/Input Methods/Owltype.app"
OWL_BIN="${APP}/Contents/MacOS/Owltype"
RECEIPT_ID="im.owltype.inputmethod.Owltype"

# 白名单：仅猫头鹰自己的路径。
TARGETS=(
  "${APP}"
  "${HOME}/Library/Application Support/Owltype"
  "${HOME}/Library/Caches/im.owltype.inputmethod.Owltype"
  "${HOME}/Library/Preferences/im.owltype.inputmethod.Owltype.plist"
  "${HOME}/Library/HTTPStorages/im.owltype.inputmethod.Owltype"
  "${HOME}/Library/Logs/Owltype"
  "/private/var/db/im.owltype.inputmethod.Owltype-installer"
)

# 安全闸：任何疑似他人输入法 / Rime 的路径，宁可中止也绝不删除。
forbidden='[Ss]quirrel|/Library/Rime|im\.rime|[Ss]ogou|搜狗|Weasel'
for t in "${TARGETS[@]}"; do
  if printf '%s\n' "$t" | grep -Eq "$forbidden"; then
    echo "❌ 安全闸触发：拒绝删除疑似他人输入法 / Rime 的路径：$t"
    exit 1
  fi
done

echo "▸ 将清理以下猫头鹰文件（不影响 Squirrel / ~/Library/Rime / 你的其他输入法）："
present=()
for t in "${TARGETS[@]}"; do
  if [ -e "$t" ]; then echo "  - $t"; present+=("$t"); fi
done
receipt_present=0
if /usr/sbin/pkgutil --pkg-info "${RECEIPT_ID}" >/dev/null 2>&1; then
  receipt_present=1
  echo "  - PackageKit receipt ${RECEIPT_ID}"
fi
if [ "${#present[@]}" -eq 0 ] && [ "${receipt_present}" -eq 0 ]; then
  echo "  （未发现猫头鹰残留文件，可能已卸载。）"
  exit 0
fi

# --dry-run 在此早退：上面只做了只读列举，绝不停用/删除任何东西。
if [ "$DRY_RUN" = 1 ]; then
  echo "(--dry-run：未停用、未删除任何文件)"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf "确认卸载猫头鹰？仅清以上路径。[y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消，未删除任何文件。"; exit 0 ;;
  esac
fi

echo "▸ 停用并退出猫头鹰…"
if [ -x "$OWL_BIN" ]; then
  # 卸载前若当前输入源是猫头鹰，先切到系统 ABC，避免停用/删除后把你留在无激活输入源的坏态。
  # 只调猫头鹰自己的只读 CLI（此刻二进制仍在），零 swift/xcode 依赖；仅当前是猫头鹰才切——
  # 绝不把正在用搜狗/Squirrel 的你粗暴拽到 ABC。
  cur="$("$OWL_BIN" --current-input-source 2>/dev/null || true)"
  case "$cur" in
    im.owltype.inputmethod.Owltype*)
      echo "  · 当前输入源是猫头鹰，先切到 ABC 再停用"
      "$OWL_BIN" --select-input-source com.apple.keylayout.ABC 2>/dev/null || true
      ;;
  esac
  "$OWL_BIN" --disable-input-source 2>/dev/null || true
  "$OWL_BIN" --quit 2>/dev/null || true
fi
/usr/bin/killall Owltype 2>/dev/null || true

removed=0
for t in "${present[@]}"; do
  if [[ "$t" == "/Library/Input Methods/"* || "$t" == "/private/var/db/im.owltype.inputmethod.Owltype-installer" ]]; then
    sudo rm -rf "$t"   # 系统目录需要一次密码
  else
    rm -rf "$t"
  fi
  echo "  ✓ 已删除 $t"
  removed=$((removed + 1))
done

if [ "${receipt_present}" -eq 1 ]; then
  sudo /usr/sbin/pkgutil --forget im.owltype.inputmethod.Owltype >/dev/null
  echo "  ✓ 已删除 PackageKit receipt ${RECEIPT_ID}"
  removed=$((removed + 1))
fi

echo "✅ 猫头鹰卸载完成（清理 ${removed} 项）。Squirrel、~/Library/Rime 及你的其他输入法均未被触碰。"
echo "提示：供应商密钥仍在钥匙串；如需一并清空，请手动删除以下两个 service："
echo "  - im.owltype.inputmethod.Owltype.providers"
echo "  - im.owltype.inputmethod.Owltype.deepseek"
echo "登出再登录可让输入菜单彻底刷新。"
