#!/usr/bin/env bash
# 法墨 Owltype 卸载器 — 严格白名单。只清法墨自己的文件；绝不触碰 Squirrel、~/Library/Rime、
# 搜狗或你的任何其他输入法。删除目标固定在 TARGETS 数组里（全是 Owltype 自己的路径）；
# 脚本中出现 “Squirrel / Rime” 字样的地方都是「安全闸」和给用户的安抚提示，不是删除目标。
#
# 除正式安装外，也清掉其他位置的法墨副本、安装中断留下的 .Owltype.* 目录、LaunchServices 登记
# 和记着法墨的系统输入法列表缓存，让之后的重装从干净状态开始。
#
# 用法：
#   bash uninstall-owltype.sh              # 交互确认后卸载
#   bash uninstall-owltype.sh --dry-run    # 只打印将删除什么，不动手
#   bash uninstall-owltype.sh --yes        # 跳过确认（脚本化场景）
#   bash uninstall-owltype.sh --keep-data  # 保留词库、学习数据与设置（Application Support/Owltype 与偏好 plist）
set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
KEEP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

# shellcheck source=scripts/owltype-maintenance-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/owltype-maintenance-lib.sh"

APP="${OWL_SYSTEM_ROOT}/Library/Input Methods/Owltype.app"
OWL_BIN="${APP}/Contents/MacOS/Owltype"
RECEIPT_ID="im.owltype.inputmethod.Owltype"

# 白名单：仅法墨自己的路径。
TARGETS=(
  "${APP}"
  "${HOME}/Library/Caches/im.owltype.inputmethod.Owltype"
  "${HOME}/Library/HTTPStorages/im.owltype.inputmethod.Owltype"
  "${HOME}/Library/Logs/Owltype"
  "${OWL_SYSTEM_ROOT}/private/var/db/im.owltype.inputmethod.Owltype-installer"
)
if [ "$KEEP_DATA" != 1 ]; then
  TARGETS+=(
    "${HOME}/Library/Application Support/Owltype"
    "${HOME}/Library/Preferences/im.owltype.inputmethod.Owltype.plist"
  )
fi
while IFS= read -r stray; do
  [ -n "$stray" ] || continue
  TARGETS+=("$stray")
  # 正式位置没有可执行的法墨时，用仍在的旧副本停用输入源，免得删掉后当前输入源指向已删除的程序。
  case "${stray##*/}" in
    *.app)
      if [ ! -x "$OWL_BIN" ] && [ ! -L "$stray" ] && [ -x "$stray/Contents/MacOS/Owltype" ]; then
        OWL_BIN="$stray/Contents/MacOS/Owltype"
      fi
      ;;
  esac
done < <(owl_stray_copies)

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
receipt_present=0
if pkgutil --pkg-info "${RECEIPT_ID}" >/dev/null 2>&1; then
  receipt_present=1
  echo "  - PackageKit receipt ${RECEIPT_ID}"
fi
if [ "${#present[@]}" -eq 0 ] && [ "${receipt_present}" -eq 0 ]; then
  echo "  （未发现法墨残留文件，可能已卸载。）"
  if [ "$DRY_RUN" != 1 ]; then
    # 文件已不在，但系统登记与菜单缓存可能还记着旧副本；撤销登记、刷新列表，不需要密码。
    while IFS= read -r claim; do [ -n "$claim" ] && owl_unregister "$claim"; done < <(owl_launch_services_claims)
    owl_purge_input_source_caches
    owl_refresh_input_menus
  fi
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

if owl_install_in_progress; then
  echo "❌ 有安装或更新正在进行（法墨安装器、系统安装程序或自动更新）。请等它结束后再卸载。"
  exit 1
fi

echo "▸ 停用并退出法墨…"
if [ -x "$OWL_BIN" ]; then
  # 卸载前若当前输入源是法墨，先切到系统 ABC，避免停用/删除后把你留在无激活输入源的坏态。
  # 只调法墨自己的只读 CLI（此刻二进制仍在），零 swift/xcode 依赖；仅当前是法墨才切——
  # 绝不把正在用搜狗/Squirrel 的你粗暴拽到 ABC。
  cur="$("$OWL_BIN" --current-input-source 2>/dev/null || true)"
  case "$cur" in
    im.owltype.inputmethod.Owltype*)
      echo "  · 当前输入源是法墨，先切到 ABC 再停用"
      "$OWL_BIN" --select-input-source com.apple.keylayout.ABC 2>/dev/null || true
      ;;
  esac
  "$OWL_BIN" --disable-input-source 2>/dev/null || true
  "$OWL_BIN" --quit 2>/dev/null || true
fi
owl_stop_processes

echo "▸ 撤销系统登记…"
claims=0
while IFS= read -r claim; do
  [ -n "$claim" ] || continue
  owl_unregister "$claim"
  claims=$((claims + 1))
done < <(owl_launch_services_claims)
echo "  ✓ 撤销 ${claims} 条法墨登记"

removed=0
for t in "${present[@]+"${present[@]}"}"; do
  owl_remove_path "$t"   # /Library 下的目标需要一次管理员密码
  echo "  ✓ 已删除 $t"
  removed=$((removed + 1))
done

if [ "${receipt_present}" -eq 1 ]; then
  sudo pkgutil --forget im.owltype.inputmethod.Owltype >/dev/null
  echo "  ✓ 已删除 PackageKit receipt ${RECEIPT_ID}"
  removed=$((removed + 1))
fi

owl_purge_input_source_caches
owl_refresh_input_menus

echo "✅ 法墨卸载完成（清理 ${removed} 项）。Squirrel、~/Library/Rime 及你的其他输入法均未被触碰。"
echo "提示：供应商密钥仍在钥匙串；如需一并清空，请手动删除以下两个 service："
echo "  - im.owltype.inputmethod.Owltype.providers"
echo "  - im.owltype.inputmethod.Owltype.deepseek"
if [ "$KEEP_DATA" = 1 ]; then
  echo "词库与设置已保留（~/Library/Application Support/Owltype 与偏好设置），重装后继续使用。"
fi
echo "重装前建议注销再登录一次：系统在登录时重建输入法列表，之后再运行安装器。"
