#!/usr/bin/env bash
# Behavior test for the LaunchServices stage of scripts/clean-dev.sh: every dead
# registration of Owltype.app, of an app nested inside an Owltype build, of
# OwltypeInstaller.app, of the UI-test runner and of the patched Sparkle build is
# unregistered by its exact path, once; live paths and other products' apps are not.
# Runs the real script in a throwaway repository with a fake HOME and a fake lsregister
# whose dump is canned. Nothing in this repository, its worktrees, DerivedData or the
# real LaunchServices database is read or changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/owl-clean-dev-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

live="$work/live"   # registered paths that still exist
dead="$work/dead"   # registered paths whose bundle has since been deleted
installed="$live/Input Methods/Owltype.app"
updater="Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
mkdir -p "$installed/$updater" "$live/release/OwltypeInstaller.app"

# Dead registrations clean-dev must remove.
expected="$work/expected"
cat >"$expected" <<EOF
$dead/wt/build/gate-tests/Build/Products/Debug/Owltype.app
$dead/wt/build/gate-tests/Build/Products/Debug/Owltype.app/$updater
$dead/wt/build/gate-tests/Build/Products/Debug/OwltypeUITests-Runner.app
$dead/wt/installer/build/Release/OwltypeInstaller.app
$dead/wt/installer/build/Release/OwltypeInstaller.app/Contents/Library/Owltype.app
$dead/wt/installer/build/Release/OwltypeInstaller.app/Contents/Library/Owltype.app/$updater
$dead/clone/build/sparkle-patched/derived/Build/Products/Release/Updater.app
$dead/clone/build/sparkle-patched/derived/Build/Products/Release/Sparkle.framework/Versions/B/Updater.app
EOF
stale_count="$(wc -l <"$expected" | tr -d ' ')"

# Registrations clean-dev must leave alone: live paths, and other products' dead apps.
untouched="$work/untouched"
cat >"$untouched" <<EOF
$installed
$installed/$updater
$live/release/OwltypeInstaller.app
$dead/other/Updater.app
$dead/other/Sparkle.framework/Versions/B/Updater.app
$dead/other/NotOwltype.app
$dead/other/OwltypeHelper.app
EOF

export FAKE_DUMP="$work/dump" MOCK_LOG="$work/lsregister.log"
write_dump() {  # one record per path in the given files; the first expected path twice
  local n=0 p
  {
    echo 'Checking data integrity......done.'
    while IFS= read -r p; do
      n=$((n + 1))
      echo '--------------------------------------------------------------------------------'
      printf 'bundle id:                  %d\n' "$n"
      printf 'path:                       %s (0x%x)\n' "$p" $((0x12e00 + n))
      printf 'name:                       %s\n' "$(basename "$p" .app)"
    done < <(cat "$@"; head -n 1 "$expected")
  } >"$FAKE_DUMP"
}
fake="$work/lsregister"
cat >"$fake" <<'EOF'
#!/bin/bash
case "$1" in
  -dump) cat "$FAKE_DUMP" ;;
  -u) printf '%s\n' "$2" >>"$MOCK_LOG" ;;
  *) printf 'UNEXPECTED %s\n' "$*" >>"$MOCK_LOG"; exit 64 ;;
esac
EOF
chmod +x "$fake"

repo="$work/repo"
git init -q "$repo"
run() {
  (cd "$repo" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    HOME="$work/home" OWL_LSREGISTER="$fake" bash "$ROOT/scripts/clean-dev.sh" "$@")
}

# 1. Report mode counts the dead registrations of this app's builds and changes nothing.
write_dump "$expected" "$untouched"
report="$(run)"
check "report mode unregisters nothing" '[[ ! -e "$MOCK_LOG" ]]'
check "report mode counts every dead registration of Owltype builds and their apps" \
  '[[ "$report" == *"would unregister  $stale_count stale bundle path(s); 1 live Owltype.app registration(s) remain"* ]]'
check "only the live Owltype.app is listed as live, not the apps beside or inside it" \
  '[[ "$(grep -c "^  live " <<<"$report")" == 1 && "$report" == *"  live          $installed"* ]]'
check "a single live Owltype.app raises no shadowing note" '[[ "$report" != *NOTE* ]]'

# 2. --apply unregisters exactly those paths, each once.
applied="$(run --apply)"
check "--apply unregisters each dead registration of this app's builds once, and nothing else" \
  'diff <(sort "$expected") <(sort "$MOCK_LOG") >/dev/null'
check "--apply leaves live paths and other products' dead apps registered" \
  '! grep -Fxq -f "$untouched" "$MOCK_LOG"'
check "--apply reports the count it unregistered" \
  '[[ "$applied" == *"unregistered  $stale_count stale bundle path(s); 1 live Owltype.app registration(s) remain"* ]]'

# 3. A live Owltype.app carried inside a live installer claims the same id and is counted.
carried="$live/release/OwltypeInstaller.app/Contents/Library/Owltype.app"
mkdir -p "$carried"
printf '%s\n' "$carried" >"$work/carried"
write_dump "$untouched" "$work/carried"
rm -f "$MOCK_LOG"
report="$(run)"
check "a live Owltype.app inside an installer counts as a second live claim" \
  '[[ "$report" == *"2 live Owltype.app registration(s) remain"* && "$report" == *NOTE* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
