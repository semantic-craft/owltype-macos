#!/usr/bin/env bash
# 法墨 Famo 卸载器 — 严格白名单。只清法墨自己的文件；绝不触碰 Squirrel、~/Library/Rime、
# 搜狗或你的任何其他输入法。删除目标固定在 TARGETS 数组里（全是 Famo 自己的路径）；
# 脚本中出现 “Squirrel / Rime” 字样的地方都是「安全闸」和给用户的安抚提示，不是删除目标。
#
# 用法：
#   bash uninstall-famo.sh            # 交互确认后卸载
#   bash uninstall-famo.sh --dry-run  # 只打印将删除什么，不动手
#   bash uninstall-famo.sh --yes      # 跳过确认（脚本化场景）
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

APP="/Library/Input Methods/Famo.app"
FAMO_BIN="${APP}/Contents/MacOS/Famo"

# 白名单：仅法墨自己的路径。
TARGETS=(
  "${APP}"
  "${HOME}/Library/Application Support/Famo"
  "${HOME}/Library/Caches/im.famo.inputmethod.Famo"
  "${HOME}/Library/Preferences/im.famo.inputmethod.Famo.plist"
  "${HOME}/Library/HTTPStorages/im.famo.inputmethod.Famo"
  "${HOME}/Library/Logs/Famo"
)

# 安全闸：任何疑似他人输入法 / Rime 的路径，宁可中止也绝不删除。
forbidden='[Ss]quirrel|/Library/Rime|im\.rime|[Ss]ogou|搜狗|Weasel'
for t in "${TARGETS[@]}"; do
  if printf '%s\n' "$t" | grep -Eq "$forbidden"; then
    echo "❌ 安全闸触发：拒绝删除疑似他人输入法 / Rime 的路径：$t"
    exit 1
  fi
done

echo "▸ 将清理以下法墨文件（不影响 Squirrel / ~/Library/Rime / 你的其他输入法）："
present=()
for t in "${TARGETS[@]}"; do
  if [ -e "$t" ]; then echo "  - $t"; present+=("$t"); fi
done
if [ "${#present[@]}" -eq 0 ]; then
  echo "  （未发现法墨残留文件，可能已卸载。）"
  exit 0
fi

# --dry-run 在此早退：上面只做了只读列举，绝不停用/删除任何东西。
if [ "$DRY_RUN" = 1 ]; then
  echo "(--dry-run：未停用、未删除任何文件)"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf "确认卸载法墨？仅清以上路径。[y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消，未删除任何文件。"; exit 0 ;;
  esac
fi

echo "▸ 停用并退出法墨…"
if [ -x "$FAMO_BIN" ]; then
  # 卸载前若当前输入源是法墨，先切到系统 ABC，避免停用/删除后把你留在无激活输入源的坏态。
  # 只调法墨自己的只读 CLI（此刻二进制仍在），零 swift/xcode 依赖；仅当前是法墨才切——
  # 绝不把正在用搜狗/Squirrel 的你粗暴拽到 ABC。
  cur="$("$FAMO_BIN" --current-input-source 2>/dev/null || true)"
  case "$cur" in
    im.famo.inputmethod.Famo*)
      echo "  · 当前输入源是法墨，先切到 ABC 再停用"
      "$FAMO_BIN" --select-input-source com.apple.keylayout.ABC 2>/dev/null || true
      ;;
  esac
  "$FAMO_BIN" --disable-input-source 2>/dev/null || true
  "$FAMO_BIN" --quit 2>/dev/null || true
fi
/usr/bin/killall Famo 2>/dev/null || true

removed=0
for t in "${present[@]}"; do
  if [[ "$t" == "/Library/Input Methods/"* ]]; then
    sudo rm -rf "$t"   # 系统目录需要一次密码
  else
    rm -rf "$t"
  fi
  echo "  ✓ 已删除 $t"
  removed=$((removed + 1))
done

echo "✅ 法墨卸载完成（清理 ${removed} 项）。Squirrel、~/Library/Rime 及你的其他输入法均未被触碰。"
echo "提示：DeepSeek API key 仍在钥匙串（im.famo.inputmethod.Famo.deepseek）；如需删除请在「钥匙串访问」手动移除。"
echo "登出再登录可让输入菜单彻底刷新。"
