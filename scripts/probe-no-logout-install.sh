#!/usr/bin/env bash
# probe-no-logout-install.sh — 「首装去掉 RequireLogout 是否可行」的真机验证探针。
#
# 问题：首装 Famo.pkg 目前带 onConclusion=RequireLogout（装完强制注销）。若想把唯一一次
# 注销挪到新手引导末尾（词库下载完再注销收尾），必须先证明：postinstall 的用户会话激活
# 序列（register→enable→select→open，见 scripts/postinstall）在**不注销**的情况下，
# 单独就能让法墨 (a) 出现在系统设置输入法列表 (b) 出现在输入菜单 (c) 在新开 App 里打字。
#
# 探针原理：`sudo installer -pkg … -target /` 命令行安装器**不执行** onConclusion，
# 所以拿现成的发布 Famo.pkg 就是一次天然的「无注销首装」——不需要构建改包。
#
# ⚠️ 只准在测试机 / 全新 VM / 可牺牲的账号里跑，绝不在日常主力机上跑：
#   1. 运行中重装 Famo 会触发 Karabiner-Elements 析构 bug → VirtualHID 卡死全键盘失灵
#      （2026-07 真机实录；preflight 会检测并拒跑）。
#   2. 探针语义是「首装」：机器上已有 Famo 时测出的是重装路径（postinstall 会跳过
#      enable/select），结论对首装问题无效。
#
# 用法：
#   ./scripts/probe-no-logout-install.sh preflight          # 装前环境检查
#   sudo installer -pkg <Famo.pkg> -target /                # 无注销安装（人工执行）
#   ./scripts/probe-no-logout-install.sh verify             # 装后取证 + 人工清单
#
# 判读（写回 docs/no-logout-first-install-probe.md 的结果表）：
#   (a)(b)(c) 全过 → 方案乙可行（RequireLogout 可挪进引导末尾）
#   任一不过（尤其输入菜单缺失）→ 保留 pkg 强制注销（方案甲），引导只做词库露出
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/famo-identity.sh
. "$ROOT/scripts/famo-identity.sh"

APP="/Library/Input Methods/Famo.app"
EXE="$APP/Contents/MacOS/Famo"

note() { printf '\n== %s ==\n' "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

preflight() {
  note "preflight：无注销首装探针环境检查"

  # Karabiner 析构 bug（运行中重装 Famo → VirtualHID 卡死全键盘失灵）：有它在就拒跑。
  if pgrep -qf "[Kk]arabiner"; then
    fail "检测到 Karabiner 进程 —— 这台机器不能跑本探针（重装会触发 VirtualHID 卡死）。换测试机/VM。"
  fi
  pass "无 Karabiner 进程"

  # 首装语义要求干净：已有安装测出的是更新路径（postinstall 跳过 enable/select），结论无效。
  if [[ -d "$APP" ]]; then
    fail "已存在 $APP —— 探针要求首装语义。先彻底卸载（package/卸载法墨.command）并注销一次后再来。"
  fi
  if [[ -d "$HOME/Library/Input Methods/Famo.app" ]]; then
    fail "已存在 ~/Library/Input Methods/Famo.app（dev 安装）—— 同上，先卸载。"
  fi
  pass "无既有法墨安装（首装语义成立）"

  if pgrep -x Famo >/dev/null 2>&1; then
    fail "Famo 进程仍在运行 —— 卸载不彻底？"
  fi
  pass "无 Famo 残留进程"

  cat <<'EOF'

下一步（人工执行，命令行安装器不会触发 RequireLogout）：

  sudo installer -pkg <path-to>/Famo.pkg -target /

装完【不要注销】，直接跑：./scripts/probe-no-logout-install.sh verify
EOF
}

verify() {
  note "verify：装后 TIS 取证（全部只读，不改任何输入源状态）"
  [[ -x "$EXE" ]] || fail "未找到 $EXE —— 先完成安装步骤"

  local out_dir
  out_dir="$(mktemp -d /tmp/famo-no-logout-probe.XXXXXX)"

  # HIToolbox plist 不可信（有会话缓存），一律走 App 自带的 TIS API 探测口。
  note "① --diagnose-tis（六层 TIS 诊断 JSON → ${out_dir}/diagnose-tis.json）"
  "$EXE" --diagnose-tis | tee "${out_dir}/diagnose-tis.json"

  note "② --detect-activation（「已选中但未真正启用」死半态检测）"
  "$EXE" --detect-activation | tee "${out_dir}/detect-activation.txt"

  note "③ --current-input-source（当前输入源 id）"
  "$EXE" --current-input-source | tee "${out_dir}/current-input-source.txt"

  note "④ 机器判读（初筛；终判以人工清单为准）"
  if grep -q "$FAMO_BUNDLE_ID" "${out_dir}/diagnose-tis.json"; then
    pass "diagnose-tis 输出里出现 ${FAMO_BUNDLE_ID}（已被 TIS 枚举到）"
  else
    printf 'WARN: diagnose-tis 输出里没有 %s —— 注册/枚举层已挂，(a)(b) 大概率不过\n' "$FAMO_BUNDLE_ID"
  fi

  cat <<EOF

取证文件在 ${out_dir}/。剩余三项必须人工验收（不注销的前提下）：

  (a) 系统设置 → 键盘 → 输入法：编辑列表里能搜到并添加「法墨」？
  (b) 菜单栏输入菜单：能看到并切换到「法墨」？
  (c) 新开一个 App（如 TextEdit），切到法墨，能正常打字出中文？
  (d) 附加观察：安装前就开着的 App 里表现如何（squirrel#68 边界，预期需重开 App）？

然后【注销重登】，重复 (a)(b)(c) 确认注销后无回归（排除「不注销暂时好、注销反而坏」的反例）。
结果记入 docs/no-logout-first-install-probe.md 的结果表；至少在两个 macOS 版本上各测一轮。
EOF
}

case "${1:-}" in
  preflight) preflight ;;
  verify) verify ;;
  *) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 64 ;;
esac
