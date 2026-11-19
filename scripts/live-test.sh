#!/bin/bash
# 实盘测试的唯一入口：bash scripts/live-test.sh OwlSkillsLiveTests/testX [OwlSkillsLiveTests/testY …]
#
# 开发凭据名由项目 .secrets 声明，经 with-secrets 按需注入。为避免非 login shell 继承到旧环境残留的
# Key（2026-10-21：有千问、豆包方舟 Key，却没有后加的 DeepSeek Key），先清空旧 Key，再一律经
# `with-secrets --project "$root" --optional --` 重新执行自己一次。
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

find_with_secrets() {
  if command -v with-secrets >/dev/null 2>&1; then
    command -v with-secrets
    return 0
  fi
  if [[ -n ${HOME:-} && -x "$HOME/.local/bin/with-secrets" ]]; then
    printf '%s\n' "$HOME/.local/bin/with-secrets"
    return 0
  fi
  return 1
}

forward=()
missing=()
if [[ ${1:-} == --reply-service ]]; then
  # No credentials belong to the input method. Only this fixed local-service suite is
  # eligible; other Live suites must still pass through with-secrets and OwlLiveKey.
  [[ $# == 2 && $2 == /* ]] || { echo "用法：live-test.sh --reply-service /absolute/test.sock" >&2; exit 2; }
  forward+=("TEST_RUNNER_OWL_REPLY_SERVICE_SOCKET=$2")
  for name in "${KEYS[@]}" OPENAI_API_KEY; do
    unset "$name" "TEST_RUNNER_$name"
  done
  set -- JEVReplyServiceLiveTests/testSharedServiceCandidatesAndOverrides
else
  if [[ -z ${OWL_LIVE_TEST_REEXEC:-} ]]; then
    if with_secrets=$(find_with_secrets); then
      for name in "${KEYS[@]}"; do
        unset "$name"
      done
      OWL_LIVE_TEST_REEXEC=1 exec "$with_secrets" --project "$root" --optional -- bash "$0" "$@"
    fi
  fi
  if ! have_any_key; then
    echo "live-test: 没有任何实盘 Key（${KEYS[*]}）。请确认已安装 with-secrets（~/.local/bin/with-secrets）、" >&2
    echo "           .secrets 列出了所需 Key 名且 secret source（~/.env）可读。" >&2
    exit 1
  fi

  for name in "${KEYS[@]}"; do
    if [[ -n ${!name:-} ]]; then
      forward+=("TEST_RUNNER_${name}=${!name}")
    else
      missing+=("$name")
    fi
  done
  [[ -n ${OWL_RUN_LIVE_PROMPT_EVAL:-} ]] && forward+=("TEST_RUNNER_OWL_RUN_LIVE_PROMPT_EVAL=$OWL_RUN_LIVE_PROMPT_EVAL")
fi

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
grep -E "^Test Case|error: -|skipped|Executed|^KOTONE_LIVE " "$log" | sort -u || true

if grep -qE "^Test Case .*skipped|Test skipped" "$log"; then
  echo "live-test: 有实盘测试被跳过，算失败。环境缺少：${missing[*]:-（无，见上方跳过原因）}" >&2
  exit 1
fi
if ((status != 0)); then
  echo "live-test: xcodebuild 退出码 $status" >&2
  exit "$status"
fi
