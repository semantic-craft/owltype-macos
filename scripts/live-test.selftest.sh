#!/bin/bash
# scripts/live-test.sh 的行为自检：用假的 with-secrets / xcodebuild / make 顶替，不打网络、不碰真实 Key。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d -t owl-live-test-selftest)
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"

cat >"$bin/with-secrets" <<'SH'
#!/bin/bash
[[ $1 == --project && $2 == "$FAKE_EXPECTED_ROOT" && $3 == --optional && $4 == -- ]] || {
  echo "with-secrets: unexpected args: $*" >&2
  exit 9
}
shift 4
[[ -n ${FAKE_WITH_SECRETS_FAIL:-} ]] && { echo "with-secrets: secret source unreadable" >&2; exit 1; }
exec env DEEPSEEK_API_KEY=sk-fake-from-secrets "$@"
SH

cat >"$bin/xcodebuild" <<'SH'
#!/bin/bash
for arg in "$@"; do [[ $arg == build-for-testing ]] && exit 0; done
env | grep -o '^TEST_RUNNER_[A-Z_]*' | sort | sed 's/^/forwarded /' >"$FAKE_LOG"
[[ ${TEST_RUNNER_DEEPSEEK_API_KEY:-} == sk-fake-from-secrets ]] && echo "value ok" >>"$FAKE_LOG"
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
  env PATH="$bin:/usr/bin:/bin" FAKE_LOG="$log" FAKE_EXPECTED_ROOT="$root" "$@" \
    bash "$root/scripts/live-test.sh" OwlSkillsLiveTests/testX 2>&1
}

fail() { echo "live-test.selftest: $*" >&2; exit 1; }

[[ -f "$root/.secrets" ]] || fail "缺少项目 .secrets 清单"
grep -q "=" "$root/.secrets" && fail ".secrets 不得包含赋值（=）"
for key in $(grep -oE '"[A-Z][A-Z0-9_]*_API_KEY"' "$root/tests/OwlLiveKeys.swift" | tr -d '"'); do
  grep -qx "$key" "$root/.secrets" || fail ".secrets 缺少 OwlLiveKeys.swift 声明的 $key"
done

out=$(run DASHSCOPE_API_KEY=stale) || fail "通过的运行不该失败：$out"
grep -q "forwarded TEST_RUNNER_DEEPSEEK_API_KEY" "$log" || fail "没把 with-secrets 的 Key 转给测试"
grep -q "forwarded TEST_RUNNER_DASHSCOPE_API_KEY" "$log" && fail "沿用了继承来的旧 Key"
grep -q "value ok" "$log" || fail "转给测试的值不对"
grep -q "sk-fake" <<<"$out" && fail "输出里出现了 Key 的值"

if out=$(run FAKE_SKIP=1); then fail "跳过被当成了通过：$out"; fi
grep -q "有实盘测试被跳过" <<<"$out" || fail "跳过时没说明原因：$out"

if out=$(run FAKE_WITH_SECRETS_FAIL=1 DEEPSEEK_API_KEY=stale); then fail "with-secrets 失败时不该继续：$out"; fi

if env PATH="$bin:/usr/bin:/bin" bash "$root/scripts/live-test.sh" >/dev/null 2>&1; then
  fail "不带测试名应当报错"
fi

out=$(env PATH="$bin:/usr/bin:/bin" FAKE_LOG="$log" FAKE_EXPECTED_ROOT="$root" FAKE_WITH_SECRETS_FAIL=1 \
  bash "$root/scripts/live-test.sh" --reply-service /tmp/synthetic-replies.sock 2>&1) \
  || fail "本地服务不应加载 with-secrets 或要求宿主 Key：$out"
grep -q "forwarded TEST_RUNNER_OWL_REPLY_SERVICE_SOCKET" "$log" || fail "没转发明确测试 socket"
grep -q "API_KEY" "$log" && fail "本地服务 profile 转发了宿主 Key"
if env PATH="$bin:/usr/bin:/bin" FAKE_LOG="$log" FAKE_EXPECTED_ROOT="$root" bash "$root/scripts/live-test.sh" \
  --reply-service /tmp/synthetic-replies.sock OwlSkillsLiveTests/testX >/dev/null 2>&1; then
  fail "本地服务 profile 不得绕过其他实盘测试的凭据入口"
fi
if env PATH="$bin:/usr/bin:/bin" FAKE_LOG="$log" FAKE_EXPECTED_ROOT="$root" FAKE_SKIP=1 bash "$root/scripts/live-test.sh" \
  --reply-service /tmp/synthetic-replies.sock >/dev/null 2>&1; then
  fail "本地服务 profile 跳过应失败"
fi

echo "live-test.selftest: ok"
