#!/usr/bin/env bash
# 修复猫头鹰.command — 双击运行的猫头鹰修复入口。
#
# 输入法菜单里出现两个「猫头鹰输入法」、图标是旧的、或选了没反应时使用。它只负责找到并调用
# repair-owltype.sh：移除多余副本与安装残留、只保留正式安装的系统登记、刷新输入法列表；不删词库与设置。
# 移除 /Library 下的残留时会在本窗口里要一次管理员密码。
#
# 既可从 DMG 里双击（make_dmg 把 repair-owltype.sh 与本文件放在同一目录），也可从仓库直接跑。

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

CANDIDATES=(
  "${DIR}/repair-owltype.sh"
  "${DIR}/../scripts/repair-owltype.sh"
)
REPAIR=""
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ]; then REPAIR="$c"; break; fi
done

if [ -z "$REPAIR" ]; then
  echo "❌ 找不到 repair-owltype.sh（已查找：${CANDIDATES[*]}）。"
  read -r -p "按回车键关闭此窗口…" _
  exit 1
fi

echo "▸ 运行猫头鹰修复脚本：$REPAIR"
echo
/bin/bash "$REPAIR"
status=$?

echo
read -r -p "修复流程结束，按回车键关闭此窗口…" _
exit "$status"
