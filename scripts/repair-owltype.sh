#!/usr/bin/env bash
# 猫头鹰 Owltype 修复器 — 输入法菜单里出现两个「猫头鹰输入法」、图标是旧的、或选了没反应时运行。
# 不删词库与设置，只做三件事：
#   1. 移除正式位置 /Library/Input Methods/Owltype.app 之外的猫头鹰副本和安装中断留下的 .Owltype.* 目录；
#   2. 让 LaunchServices 只认正式位置这一份，并重新登记输入源；
#   3. 清掉记着旧副本的系统输入法列表缓存，刷新输入法菜单。
# 修复后仍有两个条目时，注销再登录一次：系统在登录时按注册表重建输入法列表。
#
# 用法：
#   bash repair-owltype.sh            # 列出发现的问题，确认后修复
#   bash repair-owltype.sh --dry-run  # 只列出，不改动
#   bash repair-owltype.sh --yes      # 跳过确认
set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

# shellcheck source=scripts/owltype-maintenance-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/owltype-maintenance-lib.sh"

canonical_ok=0
if [ -d "$OWL_CANONICAL_APP" ] && [ "$(owl_bundle_id_of "$OWL_CANONICAL_APP")" = "$OWL_BUNDLE_ID" ]; then
  canonical_ok=1
  echo "▸ 正式安装：$OWL_CANONICAL_APP（版本 $(owl_version_of "$OWL_CANONICAL_APP")）"
else
  echo "▸ 正式位置没有可用的猫头鹰：$OWL_CANONICAL_APP"
fi

strays=()
while IFS= read -r p; do [ -n "$p" ] && strays+=("$p"); done < <(owl_stray_copies)

echo "▸ 正在读取系统登记（约需十几秒）…"
claims=()
while IFS= read -r p; do
  [ -n "$p" ] && [ "$p" != "$OWL_CANONICAL_APP" ] || continue
  for s in "${strays[@]+"${strays[@]}"}"; do
    case "$p" in "$s"|"$s"/*) continue 2 ;; esac
  done
  claims+=("$p")
done < <(owl_launch_services_claims)

if [ "${#strays[@]}" -gt 0 ]; then
  echo "▸ 多余的猫头鹰副本（会在输入法菜单里多出一个条目）："
  for p in "${strays[@]}"; do echo "  - $p"; done
else
  echo "▸ 没有多余的猫头鹰副本。"
fi
if [ "${#claims[@]}" -gt 0 ]; then
  echo "▸ 指向其他位置的系统登记（只撤销登记，不删除那里的文件）："
  for p in "${claims[@]}"; do echo "  - $p"; done
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "(--dry-run：未改动任何东西)"
  exit 0
fi

if owl_install_in_progress; then
  echo "❌ 有安装或更新正在进行（猫头鹰安装器、系统安装程序或自动更新）。请等它结束后再修复。"
  exit 1
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf "开始修复？不会删除词库与设置。[y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消，未改动任何东西。"; exit 0 ;;
  esac
fi

echo "▸ 结束正在运行的猫头鹰…"
owl_stop_processes

for p in "${strays[@]+"${strays[@]}"}"; do
  owl_unregister "$p"
  owl_remove_path "$p"
  echo "  ✓ 已移除 $p"
done
for p in "${claims[@]+"${claims[@]}"}"; do
  owl_unregister "$p"
done
[ "${#claims[@]}" -gt 0 ] && echo "  ✓ 撤销 ${#claims[@]} 条其他位置的登记"

if [ "$canonical_ok" = 1 ]; then
  [ -x "$OWL_LSREGISTER" ] && "$OWL_LSREGISTER" -f "$OWL_CANONICAL_APP" >/dev/null 2>&1 || true
  "$OWL_CANONICAL_APP/Contents/MacOS/Owltype" --activate-once >/dev/null 2>&1 || true
  echo "  ✓ 已重新登记 $OWL_CANONICAL_APP"
fi

owl_purge_input_source_caches
owl_refresh_input_menus

echo
if [ "$canonical_ok" = 1 ]; then
  echo "✅ 修复完成。打开输入法菜单确认只剩一个「猫头鹰输入法」。"
  echo "如果仍有两个，或选了没反应：从苹果菜单「退出登录」再登录一次。"
else
  echo "⚠️ 已清理残留，但正式位置没有猫头鹰。请重新运行 DMG 里的 OwltypeInstaller 安装。"
fi
