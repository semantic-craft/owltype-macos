#!/usr/bin/env bash
# 卸载猫头鹰.command — 双击运行的猫头鹰卸载入口。
#
# 它只负责「找到并调用」白名单卸载脚本 scripts/uninstall-owltype.sh（严格白名单，只清猫头鹰自己的文件，
# 绝不触碰 Squirrel / ~/Library/Rime / 搜狗 / 你的其他输入法；删 /Library 系统目录时由该脚本用 sudo
# 提权，会在本窗口里要一次密码）。本文件不重复实现卸载逻辑。
#
# 既可从 DMG 里双击（make_dmg 把 uninstall-owltype.sh 与本文件一起打进 DMG，同目录可寻），也可从仓库
# 直接跑（package/卸载猫头鹰.command → ../scripts/uninstall-owltype.sh）。

# 解析自身所在目录（双击时 BASH_SOURCE 可能为空，退回 $0）。
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 按优先级查找白名单卸载脚本：DMG 同目录 → DMG 子目录 → 仓库 scripts/。
CANDIDATES=(
  "${DIR}/uninstall-owltype.sh"
  "${DIR}/scripts/uninstall-owltype.sh"
  "${DIR}/../scripts/uninstall-owltype.sh"
)
UNINSTALL=""
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ]; then UNINSTALL="$c"; break; fi
done

if [ -z "$UNINSTALL" ]; then
  echo "❌ 找不到 uninstall-owltype.sh（已查找：${CANDIDATES[*]}）。"
  echo "请从猫头鹰仓库的 scripts/uninstall-owltype.sh 运行卸载。"
  read -r -p "按回车键关闭此窗口…" _
  exit 1
fi

echo "▸ 运行猫头鹰卸载脚本：$UNINSTALL"
echo
/bin/bash "$UNINSTALL"
status=$?

echo
read -r -p "卸载流程结束，按回车键关闭此窗口…" _
exit "$status"
