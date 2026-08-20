#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bump_version() {
    local version="$1"
    cd "${PROJECT_ROOT}" || return
    xcrun agvtool new-version "${version}"
}

# CFBundleVersion — 单调构建号（如 1.1.2）。**只**给 Sparkle `sparkle:version` 做版本比较用：
# Sparkle 按 CFBundleVersion 判断新旧，换成营销版会让它误判版本倒退而不推送更新。
get_app_version() {
    cd "${PROJECT_ROOT}" || return
    xcrun agvtool what-version | sed -n 'n;s/^[[:space:]]*\([0-9.]*\)$/\1/;p'
}

# 营销版本 CFBundleShortVersionString = MARKETING_VERSION（如 1.1）—— 用户可见版本：
# Distribution 标题 / 下载页 / appcast 显示版本 (sparkle:shortVersionString)。
# 从 pbxproj 直接读（Info.plist 里是未展开的 $(MARKETING_VERSION)，agvtool 也不展开它）。
get_marketing_version() {
    grep -oE 'MARKETING_VERSION = [0-9][0-9.]*;' "${PROJECT_ROOT}/Owltype.xcodeproj/project.pbxproj" \
        | sed -E 's/MARKETING_VERSION = ([0-9.]+);/\1/' | sort -u | head -1
}

match_line() {
    grep --quiet --fixed-strings "$@"
}
