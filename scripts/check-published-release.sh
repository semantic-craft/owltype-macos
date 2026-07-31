#!/usr/bin/env bash
# 发布后校验闸：断言「用户此刻真的能更新到本版」。
#
# 为什么在发布**之后**跑：release-gate 的所有闸都只看本地产物，而更新链路的两种静默死法
# 都发生在发布环节之外——
#   1. Release 被标成 pre-release / draft：GitHub 的 `releases/latest` 语义是「最新的
#      非草稿、非预发布」，误标后 latest 悄悄回退到上一版，全网收不到更新，无任何报错；
#   2. 忘给 Release 附 appcast.xml：feed 永久链接 404，Sparkle 静默失败，用户看不到
#      更新提示，维护者也无从察觉。
# 这两种死法只有打用户实际走的那条 URL 才验得出来。
#
# 用法：bash scripts/check-published-release.sh <version>
#   例：bash scripts/check-published-release.sh 1.5.17
# 在 GitHub Release 发布（含 8 个产物上传）之后立即执行；见 docs/PUBLISHING_CHECKLIST.md。
set -euo pipefail

VERSION="${1:?用法: check-published-release.sh <version>，例 1.5.17}"

# 用户实际走的 URL：app 里烙的 SUFeedURL。它 302 到 GitHub latest 里的 appcast.xml，
# 打这一条同时覆盖「站点重定向还活着」与「latest 指向本版」两件事。
FEED_URL="https://responsay.com/famo/appcast.xml"

echo "==> 1/3 feed 指向本版"
feed="$(curl -fsSL --max-time 30 "$FEED_URL")" || {
  echo >&2 "ERROR: 拉取 $FEED_URL 失败。可能：站点重定向被删、Release 忘附 appcast.xml（404）。"
  exit 1
}
feed_version="$(printf '%s' "$feed" \
  | grep -oE '<sparkle:shortVersionString>[^<]*' \
  | head -1 | sed 's/.*>//')"
[[ "$feed_version" == "$VERSION" ]] || {
  # ${VERSION} 必须带花括号：macOS bash 3.2 会把紧跟的中文标点误吞进变量名（set -u 直接炸）。
  echo >&2 "ERROR: feed 首条版本是 ${feed_version:-<空>}，不是 ${VERSION}。"
  echo >&2 "       多半是本版 Release 被标成 pre-release/draft（latest 悄悄回退），"
  echo >&2 "       或 Release 上传的 appcast.xml 不是本版出包生成的那份。"
  exit 1
}
echo "PASS: feed 首条 = $VERSION"

echo "==> 2/3 enclosure 可下载且字节数与 feed 一致"
enclosure_url="$(printf '%s' "$feed" | grep -oE 'url="[^"]+Famo-update\.pkg"' | head -1 | sed 's/^url="//;s/"$//')"
enclosure_length="$(printf '%s' "$feed" | grep -oE 'length="[0-9]+"' | head -1 | sed 's/[^0-9]//g')"
[[ -n "$enclosure_url" && -n "$enclosure_length" ]] || {
  echo >&2 "ERROR: feed 里解析不出 enclosure url/length——appcast 结构变了？"
  exit 1
}
remote_length="$(curl -fsSIL --max-time 30 "$enclosure_url" | grep -i '^content-length:' | tail -1 | tr -dc '0-9')"
[[ "$remote_length" == "$enclosure_length" ]] || {
  echo >&2 "ERROR: pkg 实际字节 ${remote_length:-<拉取失败>} ≠ feed 声称的 ${enclosure_length}。"
  echo >&2 "       Sparkle 会因长度不符拒绝安装——多半是 appcast 与 pkg 不是同一次出包的产物。"
  exit 1
}
echo "PASS: Famo-update.pkg 可下载，$remote_length 字节与 feed 一致"

echo "==> 3/3 DMG 手动下载入口存在"
dmg_url="https://github.com/semantic-craft/famotype-macos/releases/download/${VERSION}/Famo-${VERSION}.dmg"
curl -fsSIL --max-time 30 "$dmg_url" >/dev/null || {
  echo >&2 "ERROR: $dmg_url 不可下载——DMG 没传上去或命名不对。"
  exit 1
}
echo "PASS: Famo-${VERSION}.dmg 在 Release 上可下载"

echo "PASS: published-release check complete — 用户此刻能看到并装到 $VERSION"
