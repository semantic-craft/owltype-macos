#!/bin/bash
# 实盘测试的唯一入口：bash scripts/live-test.sh OwlSkillsLiveTests/testX [OwlSkillsLiveTests/testY …]
#
# 开发凭据来自项目 .envrc 的 `use secrets`（1Password → ~/.env）。agent 的 shell 不是 login
# shell、不加载 direnv，继承来的环境还可能是旧 .envrc 导出的残留（2026-10-21：有千问、豆包
# 方舟 Key，却没有后加的 DeepSeek Key）。所以不看当前环境有没有 Key，一律经 `direnv exec`
# 按当前 .envrc 重新执行自己一次。
# xcodebuild 不把普通环境变量转给测试进程，要加 TEST_RUNNER_ 前缀；这里统一转。
# 点名要跑的实盘测试若被跳过（缺 Key），整次运行算失败，不让「跳过」冒充「通过」。
# Key 只在环境里传递，不打印、不落盘。
set -euo pipefail

if (($# == 0)); then
  echo "用法：bash scripts/live-test.sh OwlSkillsLiveTests/testName [...]" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Key 名单只有一份：tests/OwlLiveKeys.swift 的 case。
KEYS=($(grep -oE '"[A-Z][A-Z0-9_]*_API_KEY"' tests/OwlLiveKeys.swift | tr -d '"'))
if ((${#KEYS[@]} == 0)); then
  echo "live-test: 没从 tests/OwlLiveKeys.swift 读到 Key 名单" >&2
  exit 1
fi

have_any_key() {
  local name
  for name in "${KEYS[@]}"; do
    [[ -n ${!name:-} ]] && return 0
  done
  return 1
}

if [[ -z ${OWL_LIVE_TEST_REEXEC:-} ]] && command -v direnv >/dev/null; then
  OWL_LIVE_TEST_REEXEC=1 exec direnv exec "$root" bash "$0" "$@"
fi
if ! have_any_key; then
  echo "live-test: 没有任何实盘 Key（${KEYS[*]}）。.envrc 被拦截时先在仓库主目录运行 direnv allow；" >&2
  echo "           名字不在 .envrc 的 use secrets 里时补上；~/.env 里没有时先在 1Password 加上。" >&2
  exit 1
fi

forward=()
missing=()
for name in "${KEYS[@]}"; do
  if [[ -n ${!name:-} ]]; then
    forward+=("TEST_RUNNER_${name}=${!name}")
  else
    missing+=("$name")
  fi
done
# 全量提示词评测的开关同样要经前缀才进得了测试进程。
[[ -n ${OWL_RUN_LIVE_PROMPT_EVAL:-} ]] && forward+=("TEST_RUNNER_OWL_RUN_LIVE_PROMPT_EVAL=$OWL_RUN_LIVE_PROMPT_EVAL")

only=()
for test in "$@"; do
  [[ $test == OwltypeTests/* ]] || test="OwltypeTests/$test"
  only+=("-only-testing:$test")
done

xcode=(xcodebuild -project Owltype.xcodeproj -scheme Owltype -configuration Debug
  -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)

"${xcode[@]}" build-for-testing -quiet
make -s copy-owl-seed DERIVED_DATA_PATH=build OWL_CONFIG=Debug >/dev/null

log=$(mktemp -t owl-live-test)
trap 'rm -f "$log"' EXIT
status=0
env "${forward[@]}" "${xcode[@]}" test-without-building "${only[@]}" >"$log" 2>&1 || status=$?
grep -E "^Test Case|error: -|skipped|Executed" "$log" | sort -u || true

if grep -qE "^Test Case .*skipped|Test skipped" "$log"; then
  echo "live-test: 有实盘测试被跳过，算失败。环境缺少：${missing[*]:-（无，见上方跳过原因）}" >&2
  exit 1
fi
if ((status != 0)); then
  echo "live-test: xcodebuild 退出码 $status" >&2
  exit "$status"
fi
