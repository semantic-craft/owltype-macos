#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # expect() evals its single-quoted conditions later.
# Behavior test for the DMG maintenance scripts (uninstall-owltype.sh, repair-owltype.sh).
# Runs the real scripts against a throwaway system root and HOME with mocked sudo, lsregister,
# pkgutil, killall, pkill and pgrep, so nothing on this machine is removed, unregistered or killed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/owl-maintenance-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

ID="im.owltype.inputmethod.Owltype"
mocks="$work/mocks"
mkdir -p "$mocks"
export MOCK_LOG="$work/calls.log"

cat >"$mocks/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"$MOCK_LOG"
exec "$@"
EOF
cat >"$mocks/lsregister" <<'EOF'
#!/bin/sh
if [ "$1" = -dump ]; then cat "$MOCK_LS_DUMP"; exit 0; fi
echo "lsregister $*" >>"$MOCK_LOG"
EOF
cat >"$mocks/pkgutil" <<'EOF'
#!/bin/sh
echo "pkgutil $*" >>"$MOCK_LOG"
[ "$1" = --pkg-info ] && [ "${MOCK_RECEIPT:-0}" != 1 ] && exit 1
exit 0
EOF
# pgrep: reports a match only for the pattern named in MOCK_PGREP_MATCH, so each install
# phase can be simulated by the exact predicate the scripts use for it.
cat >"$mocks/pgrep" <<'EOF'
#!/bin/sh
for a in "$@"; do [ -n "${MOCK_PGREP_MATCH:-}" ] && [ "$a" = "$MOCK_PGREP_MATCH" ] && exit 0; done
exit 1
EOF
for tool in killall pkill; do
  printf '#!/bin/sh\necho "%s $*" >>"$MOCK_LOG"\n' "$tool" >"$mocks/$tool"
done
chmod +x "$mocks"/*

make_bundle() {  # path bundle-id version
  mkdir -p "$1/Contents/MacOS"
  cat >"$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>$3</string>
</dict></plist>
EOF
  printf '#!/bin/sh\necho "owltype $*" >>"$MOCK_LOG"\n' >"$1/Contents/MacOS/Owltype"
  chmod +x "$1/Contents/MacOS/Owltype"
}

# A machine with the report's state: the current install, an older copy in the user's
# Input Methods, installer leftovers, another vendor's input method and a stale registration.
setup() {
  rm -rf "${work:?}/sys" "${work:?}/home" "$MOCK_LOG"
  sys="$work/sys" ; home="$work/home"
  sim="$sys/Library/Input Methods" ; uim="$home/Library/Input Methods"
  make_bundle "$sim/Owltype.app" "$ID" 2.0.15
  make_bundle "$uim/Owltype.app" "$ID" 2.0.14
  make_bundle "$sim/Squirrel.app" im.rime.inputmethod.Squirrel 1.0
  make_bundle "$uim/Other.app" com.example.other 1.0
  mkdir -p "$sim/.Owltype.retired-ABC" "$sim/.Owltype.pkg-staging"
  touch "$sim/.Owltype.retired-ABC/Info.plist" "$sim/.Owltype.pkg-staging/Owltype.app.zip"
  mkdir -p "$home/Library/Application Support/Owltype" "$home/Library/Rime" "$sys/private/var/db"
  mkdir -p "$home/Library/Preferences"
  touch "$home/Library/Application Support/Owltype/user.yaml" "$home/Library/Rime/keep.yaml" \
    "$home/Library/Preferences/$ID.plist"
  mkdir -p "$work/cache/com.apple.TextInputMenuAgent"
  printf 'x%sy' "$ID" >"$work/cache/com.apple.IntlDataCache.le.kbdx"
  printf 'x%sy' "$ID" >"$work/cache/com.apple.TextInputMenuAgent/com.apple.IntlDataCache.le"
  printf 'only apple' >"$work/cache/com.apple.IntlDataCache.le"
  cat >"$work/ls.dump" <<EOF
path:                       $sim/Owltype.app (0x1)
identifier:                 $ID
path:                       $uim/Owltype.app (0x2)
identifier:                 $ID
path:                       /Volumes/gone/Owltype.app (0x3)
identifier:                 $ID
path:                       $sim/Squirrel.app (0x4)
identifier:                 im.rime.inputmethod.Squirrel
EOF
}

run() {  # script args...
  local script="$1" ; shift
  env -i PATH="$mocks:/usr/bin:/bin" HOME="$home" MOCK_LOG="$MOCK_LOG" \
    MOCK_LS_DUMP="$work/ls.dump" MOCK_RECEIPT="${MOCK_RECEIPT:-0}" \
    MOCK_PGREP_MATCH="${MOCK_PGREP_MATCH:-}" \
    OWL_SYSTEM_ROOT="$sys" OWL_LSREGISTER="$mocks/lsregister" OWL_USER_CACHE_DIR="$work/cache" \
    /bin/bash "$ROOT/scripts/$script" "$@" >"$work/out.txt" 2>&1
}
logged() { grep -qF -- "$1" "$MOCK_LOG" 2>/dev/null; }

# --- repair ---
setup
run repair-owltype.sh --dry-run
expect "repair --dry-run lists the older user copy" 'grep -qF "$uim/Owltype.app" "$work/out.txt"'
expect "repair --dry-run changes nothing" '[ -d "$uim/Owltype.app" ] && [ -d "$sim/.Owltype.retired-ABC" ] && [ ! -e "$MOCK_LOG" ]'

for phase in OwltypeInstaller Installer Autoupdate \
    'im\.owltype\.inputmethod\.Owltype[^ ]*/(pre|post)install' \
    'MacOS/Owltype --(commit-install|finish-install|install-session-)'; do
  for script in repair-owltype.sh uninstall-owltype.sh; do
    setup
    MOCK_PGREP_MATCH="$phase" run "$script" --yes && status=0 || status=$?
    expect "$script refuses during install phase: $phase" '[ "$status" -ne 0 ] && [ -d "$sim/Owltype.app" ] && [ -d "$uim/Owltype.app" ] && [ -d "$sim/.Owltype.pkg-staging" ] && ! logged "pkill"'
  done
done

setup
mkdir "$sim/.Owltype.install-lock"
run repair-owltype.sh --yes && status=0 || status=$?
expect "repair refuses while the commit lock is held" '[ "$status" -ne 0 ] && [ -d "$uim/Owltype.app" ]'

setup
mkdir -p "$sys/private/var/db/im.owltype.inputmethod.Owltype-installer/work/install-lock"
run repair-owltype.sh --yes && status=0 || status=$?
expect "repair refuses while the current commit lock is held" '[ "$status" -ne 0 ] && [ -d "$uim/Owltype.app" ]'

setup
run repair-owltype.sh --yes
expect "repair removes the older copy and installer leftovers" '[ ! -e "$uim/Owltype.app" ] && [ ! -e "$sim/.Owltype.retired-ABC" ] && [ ! -e "$sim/.Owltype.pkg-staging" ]'
expect "repair keeps the install, other input methods and user data" '[ -d "$sim/Owltype.app" ] && [ -d "$sim/Squirrel.app" ] && [ -d "$uim/Other.app" ] && [ -f "$home/Library/Application Support/Owltype/user.yaml" ] && [ -f "$home/Library/Rime/keep.yaml" ]'
expect "repair unregisters other claims but not the install or Squirrel" 'logged "lsregister -u $uim/Owltype.app" && logged "lsregister -u /Volumes/gone/Owltype.app" && ! logged "lsregister -u $sim/Owltype.app" && ! logged "Squirrel"'
expect "repair re-registers the install" 'logged "lsregister -f $sim/Owltype.app" && logged "owltype --activate-once"'
expect "repair purges only caches that mention Owltype" '[ ! -e "$work/cache/com.apple.IntlDataCache.le.kbdx" ] && [ ! -e "$work/cache/com.apple.TextInputMenuAgent/com.apple.IntlDataCache.le" ] && [ -f "$work/cache/com.apple.IntlDataCache.le" ]'
expect "repair refreshes the input menus" 'logged "killall -9 TextInputMenuAgent"'
expect "repair uses sudo only under the system Input Methods" '! grep "^sudo" "$MOCK_LOG" | grep -vqF "$sim/"'

# --- uninstall ---
setup
MOCK_RECEIPT=1 run uninstall-owltype.sh --yes
expect "uninstall removes every Owltype copy and the data" '[ ! -e "$sim/Owltype.app" ] && [ ! -e "$uim/Owltype.app" ] && [ ! -e "$sim/.Owltype.retired-ABC" ] && [ ! -e "$home/Library/Application Support/Owltype" ]'
expect "uninstall leaves Squirrel, Rime and other bundles" '[ -d "$sim/Squirrel.app" ] && [ -d "$uim/Other.app" ] && [ -f "$home/Library/Rime/keep.yaml" ]'
expect "uninstall disables the input source before deleting" 'logged "owltype --disable-input-source"'
expect "uninstall unregisters all Owltype claims" 'logged "lsregister -u $sim/Owltype.app" && logged "lsregister -u /Volumes/gone/Owltype.app" && ! logged "Squirrel"'
expect "uninstall forgets the package receipt" 'logged "pkgutil --forget $ID"'
expect "uninstall purges Owltype list caches" '[ ! -e "$work/cache/com.apple.IntlDataCache.le.kbdx" ] && [ -f "$work/cache/com.apple.IntlDataCache.le" ]'

setup
run uninstall-owltype.sh --yes --keep-data
expect "uninstall --keep-data keeps the user data and settings" '[ -f "$home/Library/Application Support/Owltype/user.yaml" ] && [ -f "$home/Library/Preferences/$ID.plist" ] && [ ! -e "$sim/Owltype.app" ]'

setup
MOCK_RECEIPT=1 run uninstall-owltype.sh --yes
expect "uninstall without --keep-data removes the settings" '[ ! -e "$home/Library/Preferences/$ID.plist" ]'

setup
rm -rf "$sim/Owltype.app"
printf '#!/bin/sh\necho "user-copy $*" >>"$MOCK_LOG"\n' >"$uim/Owltype.app/Contents/MacOS/Owltype"
run uninstall-owltype.sh --yes
expect "uninstall parks the source through a surviving user copy" 'logged "user-copy --disable-input-source" && [ ! -e "$uim/Owltype.app" ]'

setup
rm -rf "$sim/Owltype.app" "$uim/Owltype.app" "$sim"/.Owltype.* "$home/Library/Application Support/Owltype"
run uninstall-owltype.sh --yes
expect "uninstall with no files still clears stale registrations" 'logged "lsregister -u /Volumes/gone/Owltype.app" && [ ! -e "$work/cache/com.apple.IntlDataCache.le.kbdx" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
