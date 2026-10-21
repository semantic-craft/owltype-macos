#!/bin/bash
# scripts/live-test.sh 的行为自检：用假的 direnv / xcodebuild / make 顶替，不打网络、不碰真实 Key。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d -t owl-live-test-selftest)
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"

# direnv exec：模拟项目 .envrc 的 use secrets，只给 DEEPSEEK_API_KEY。
cat >"$bin/direnv" <<'SH'
#!/bin/bash
[[ $1 == exec ]] || exit 9
shift 2
[[ -n ${FAKE_DIRENV_BLOCKED:-} ]] && { echo "direnv: error .envrc is blocked" >&2; exit 1; }
exec env -u DASHSCOPE_API_KEY -u ARK_API_KEY DEEPSEEK_API_KEY=sk-fake-from-envrc "$@"
SH
# xcodebuild：把收到的 TEST_RUNNER_ 名字记进 FAKE_LOG（不记值），按 FAKE_SKIP 决定跳过还是通过。
cat >"$bin/xcodebuild" <<'SH'
#!/bin/bash
for arg in "$@"; do [[ $arg == build-for-testing ]] && exit 0; done
env | grep -o '^TEST_RUNNER_[A-Z_]*' | sort | sed 's/^/forwarded /' >"$FAKE_LOG"
[[ ${TEST_RUNNER_DEEPSEEK_API_KEY:-} == sk-fake-from-envrc ]] && echo "value ok" >>"$FAKE_LOG"
if [[ -n ${FAKE_SKIP:-} ]]; then
  echo "Test Case '-[OwltypeTests.OwlSkillsLiveTests testX]' skipped (0.001 seconds)."
else
  echo "Test Case '-[OwltypeTests.OwlSkillsLiveTests testX]' passed (0.001 seconds)."
fi
SH
printf '#!/bin/bash\nexit 0\n' >"$bin/make"
chmod +x "$bin"/*

log="$work/forwarded"
run() {
  : >"$log"
  env PATH="$bin:/usr/bin:/bin" FAKE_LOG="$log" "$@" \
    bash "$root/scripts/live-test.sh" OwlSkillsLiveTests/testX 2>&1
}

fail() { echo "live-test.selftest: $*" >&2; exit 1; }

# 1. 继承来的旧环境有别的 Key，也要经 direnv 按当前 .envrc 重取（2026-10-21 的复发条件）。
out=$(run DASHSCOPE_API_KEY=stale) || fail "通过的运行不该失败：$out"
grep -q "forwarded TEST_RUNNER_DEEPSEEK_API_KEY" "$log" || fail "没把 .envrc 的 Key 转给测试"
grep -q "forwarded TEST_RUNNER_DASHSCOPE_API_KEY" "$log" && fail "沿用了继承来的旧 Key"
grep -q "value ok" "$log" || fail "转给测试的值不对"
grep -q "sk-fake" <<<"$out" && fail "输出里出现了 Key 的值"

# 2. 点名的实盘测试被跳过 = 失败。
if out=$(run FAKE_SKIP=1); then fail "跳过被当成了通过：$out"; fi
grep -q "有实盘测试被跳过" <<<"$out" || fail "跳过时没说明原因：$out"

# 3. .envrc 被拦截：直接失败，不退回继承来的环境。
if out=$(run FAKE_DIRENV_BLOCKED=1 DEEPSEEK_API_KEY=stale); then fail "direnv 拦截时不该继续：$out"; fi

# 4. 不带测试名是用法错误。
if env PATH="$bin:/usr/bin:/bin" bash "$root/scripts/live-test.sh" >/dev/null 2>&1; then
  fail "不带测试名应当报错"
fi

echo "live-test.selftest: ok"
