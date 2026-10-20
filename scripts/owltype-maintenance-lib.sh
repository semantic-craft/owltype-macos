# shellcheck shell=bash
# owltype-maintenance-lib.sh — 卸载脚本与修复脚本共用的查找与刷新函数，由两者 source，不单独运行。
#
# 只认猫头鹰自己的 bundle id 与路径；不碰 Squirrel、~/Library/Rime、搜狗或其他输入法。
# 测试可用 OWL_SYSTEM_ROOT（系统目录前缀）、OWL_LSREGISTER、OWL_USER_CACHE_DIR 换成隔离目录与替身工具。

OWL_BUNDLE_ID="im.owltype.inputmethod.Owltype"
OWL_SYSTEM_ROOT="${OWL_SYSTEM_ROOT:-}"
OWL_SYSTEM_IM_DIR="${OWL_SYSTEM_ROOT}/Library/Input Methods"
OWL_USER_IM_DIR="${HOME}/Library/Input Methods"
OWL_CANONICAL_APP="${OWL_SYSTEM_IM_DIR}/Owltype.app"
OWL_LSREGISTER="${OWL_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

# 任何疑似他人输入法 / Rime 的路径都拒绝处理。
OWL_FORBIDDEN_PATTERN='[Ss]quirrel|/Library/Rime|im\.rime|[Ss]ogou|搜狗|Weasel'

owl_refuse_foreign() {
  if printf '%s\n' "$1" | grep -Eq "$OWL_FORBIDDEN_PATTERN"; then
    echo "❌ 安全闸触发：拒绝处理疑似他人输入法 / Rime 的路径：$1" >&2
    exit 1
  fi
}

owl_bundle_id_of() {
  local plist="$1/Contents/Info.plist"
  [ -f "$plist" ] || return 0
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true
}

owl_version_of() {
  /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

# 正式位置之外、两个 Input Methods 目录里认领猫头鹰 bundle id 的副本，以及安装器中断后留下的
# .Owltype.* 隐藏目录（retired/abandoned/failed/pkg-staging）。这些都会被系统当成另一份猫头鹰登记，
# 输入法菜单因此出现第二个「猫头鹰输入法」。每行一个路径。
owl_stray_copies() {
  local dir entry
  for dir in "$OWL_SYSTEM_IM_DIR" "$OWL_USER_IM_DIR"; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*.app "$dir"/.Owltype.*; do
      [ -e "$entry" ] || continue
      [ "$entry" = "$OWL_CANONICAL_APP" ] && continue
      case "$(basename "$entry")" in
        .Owltype.*) printf '%s\n' "$entry"; continue ;;
      esac
      [ "$(owl_bundle_id_of "$entry")" = "$OWL_BUNDLE_ID" ] && printf '%s\n' "$entry"
    done
  done
}

# LaunchServices 里认领猫头鹰 bundle id 的全部路径（含已删除的目录）。每行一个路径。
owl_launch_services_claims() {
  [ -x "$OWL_LSREGISTER" ] || return 0
  "$OWL_LSREGISTER" -dump 2>/dev/null | awk -v id="$OWL_BUNDLE_ID" '
    /^path:/ { path = $0; sub(/^path: */, "", path); sub(/ \(0x[0-9a-f]+\)$/, "", path) }
    /^identifier:/ { ident = $0; sub(/^identifier: */, "", ident); if (ident == id && path != "") print path }
  ' | sort -u
}

owl_unregister() {
  [ -x "$OWL_LSREGISTER" ] || return 0
  "$OWL_LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# 安装器或系统安装程序正在跑时不动 .Owltype.* 中间目录，避免打断一次正在提交的安装。
owl_install_in_progress() {
  pgrep -x OwltypeInstaller >/dev/null 2>&1 && return 0
  pgrep -f '/Owltype.app/Contents/MacOS/Owltype --commit-install' >/dev/null 2>&1 && return 0
  return 1
}

owl_remove_path() {
  local target="$1"
  owl_refuse_foreign "$target"
  case "$target" in
    "$OWL_SYSTEM_IM_DIR"/*|"${OWL_SYSTEM_ROOT}/private/var/db/"*) sudo rm -rf "$target" ;;
    *) rm -rf "$target" ;;
  esac
}

# 结束所有猫头鹰进程（无论从哪份副本启动）。系统在下次需要时从正式位置重新拉起。
owl_stop_processes() {
  pkill -x Owltype >/dev/null 2>&1 || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Owltype >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  pkill -9 -x Owltype >/dev/null 2>&1 || true
}

# 系统输入法列表的缓存：各进程在用户缓存目录下的 com.apple.IntlDataCache.le*，里面记着输入法的
# bundle 路径与图标。只删提到猫头鹰的那几份，下次读取时系统按当前注册表重建。
# 系统设置的「添加输入法」对话框在运行中持有自己那份，所以先退出系统设置。
owl_purge_input_source_caches() {
  local cache_dir="${OWL_USER_CACHE_DIR:-$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)}"
  [ -n "$cache_dir" ] && [ -d "$cache_dir" ] || return 0
  pkill -x "System Settings" >/dev/null 2>&1 || true
  pkill -f "KeyboardSettings.appex/Contents/MacOS/KeyboardSettings" >/dev/null 2>&1 || true
  local purged=0 file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -a -q -F "$OWL_BUNDLE_ID" "$file" 2>/dev/null; then
      rm -f "$file" && purged=$((purged + 1))
    fi
  done < <(find "$cache_dir" -maxdepth 2 -name 'com.apple.IntlDataCache.le*' -type f 2>/dev/null)
  echo "  ✓ 清除 ${purged} 份记有猫头鹰的输入法列表缓存"
}

# 输入法菜单、按住切换器和光标旁的切换器各自缓存列表与图标；结束后 launchd 按需重启它们。
owl_refresh_input_menus() {
  killall -9 TextInputMenuAgent TextInputSwitcher CursorUIViewService >/dev/null 2>&1 || true
  echo "  ✓ 已刷新输入法菜单"
}
