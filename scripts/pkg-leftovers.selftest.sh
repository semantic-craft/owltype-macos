#!/usr/bin/env bash
# Behavior test for the package scripts: no bundle-shaped install intermediate may stay in
# /Library/Input Methods, where LaunchServices registers it as a second 猫头鹰输入法.
# Runs the real preinstall/postinstall, rewritten onto a throwaway system root, with mocked
# install/stat/launchctl/codesign/PlistBuddy/lsregister and a fake App whose --commit-install
# only copies files. Nothing on this machine is installed, registered or removed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/owl-pkg-leftovers-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

lsregister_path='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
mocks="$work/mocks"
mkdir -p "$mocks"
export MOCK_LOG="$work/lsregister.log" FINISH_LOG="$work/finish.log"
cat >"$mocks/lsregister" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mocks/install" <<'EOF'
#!/bin/bash
args=()
while (($#)); do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
cat >"$mocks/stat" <<'EOF'
#!/bin/bash
[[ "${*: -1}" == /dev/console ]] || exec /usr/bin/stat "$@"
[[ "$1" == -f%u ]] && echo 501 || echo owltester
EOF
# launchctl asuser <uid> /usr/bin/sudo -u <user> <command...>
cat >"$mocks/launchctl" <<'EOF'
#!/bin/bash
[[ "$1" == asuser && "$3" == /usr/bin/sudo && "$4" == -u ]] || exit 9
shift 5
exec "$@"
EOF
printf '#!/bin/sh\nexit 0\n' >"$mocks/codesign"
# pgrep: an older installer's --commit-install is running only when MOCK_OLD_COMMIT=1.
printf '#!/bin/sh\n[ "$MOCK_OLD_COMMIT" = 1 ]\n' >"$mocks/pgrep"
printf '#!/bin/sh\necho 9999\n' >"$mocks/PlistBuddy"
chmod +x "$mocks"/*

# The fake App's commit copies itself to the live path like a successful RENAME_SWAP commit,
# or fails when MOCK_COMMIT_FAIL=1. --finish-install only records that it ran.
fake="$work/fake/Owltype.app"
mkdir -p "$fake/Contents/MacOS"
printf '<plist><dict/></plist>\n' >"$fake/Contents/Info.plist"
cat >"$fake/Contents/MacOS/Owltype" <<'EOF'
#!/bin/bash
case "$1" in
  --current-input-source) echo im.owltype.inputmethod.Owltype.Hans ;;
  --commit-install)
    [[ "${MOCK_COMMIT_FAIL:-}" != 1 ]] || exit 1
    rm -rf "$SYS/Library/Input Methods/Owltype.app"
    cp -R "$2" "$SYS/Library/Input Methods/Owltype.app" ;;
  --finish-install) echo "$*" >>"$FINISH_LOG" ;;
esac
EOF
chmod +x "$fake/Contents/MacOS/Owltype"

export SYS="$work/sys"
im="$SYS/Library/Input Methods"
state="$SYS/private/var/db/im.owltype.inputmethod.Owltype-installer"
staging="$im/.Owltype.pkg-staging"
for script in preinstall postinstall; do
  sed -e 's/\$EUID == 0/0 == 0/' \
      -e "s|/Library/Input Methods|$SYS/Library/Input Methods|g" \
      -e "s|/private/var/db/|$SYS/private/var/db/|g" \
      -e "s|$lsregister_path|$mocks/lsregister|g" \
      -e "s|/usr/bin/install|$mocks/install|g" \
      -e "s|/usr/bin/stat|$mocks/stat|g" \
      -e "s|/bin/launchctl|$mocks/launchctl|g" \
      -e "s|/usr/bin/codesign|$mocks/codesign|g" \
      -e "s|/usr/bin/pgrep|$mocks/pgrep|g" \
      -e "s|/usr/libexec/PlistBuddy|$mocks/PlistBuddy|g" \
      "$ROOT/scripts/$script" >"$work/$script"
  chmod +x "$work/$script"
  if grep -qE "(^|[ '\"=(])/(Library/Input|private/var/db|usr/bin/(install|stat|codesign|pgrep)|bin/launchctl|usr/libexec/PlistBuddy|System/Library)" "$work/$script"; then
    bad "$script rewrite left a real system path"
  else
    ok "$script rewrite reaches only the fake root and mocks"
  fi
done

reset_root() {
  rm -rf "$SYS" "$MOCK_LOG" "$FINISH_LOG"
  mkdir -p "$im" "$SYS/private/var/db"
  cp -R "$fake" "$im/Owltype.app"
  mkdir -p "$im/Squirrel.app/Contents" "$im/.Other"
}
pkg_payload() {
  mkdir -p "$staging"
  /usr/bin/ditto -c -k --keepParent "$fake" "$staging/Owltype.app.zip"
}
run() { "$work/$1" pkg / / / >"$work/$1.out" 2>&1; }
listing() { (cd "$1" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | tr '\n' ' '); }

# 1. Update over leftovers an older installer left in Input Methods, plus a consumed payload.
reset_root
mkdir -p "$im/.Owltype.abandoned-A/Owltype.app/Contents" "$im/.Owltype.abandoned-B" \
         "$im/.Owltype.retired-C/MacOS" "$im/.Owltype.failed-D/Contents" \
         "$im/.Owltype.unpack.E/Owltype.app/Contents" "$im/.Owltype.prepared-F/Owltype.app/Contents"
touch "$im/.Owltype.abandoned-B/Owltype.app.zip" "$im/.Owltype.retired-C/Info.plist"
pkg_payload
if run preinstall; then ok "preinstall succeeds over legacy leftovers"; else bad "preinstall over legacy leftovers: $(cat "$work/preinstall.out")"; fi
check "Input Methods keeps only the live App, foreign entries and a fresh empty staging" \
  '[[ "$(listing "$im")" == ".Other .Owltype.pkg-staging Owltype.app Squirrel.app " && -z "$(listing "$staging")" ]]'
check "legacy leftovers are kept in the private state directory, not deleted" \
  '[[ "$(listing "$state/retained")" == ".Owltype.abandoned-A .Owltype.abandoned-B .Owltype.failed-D .Owltype.prepared-F .Owltype.retired-C .Owltype.unpack.E " ]]'
check "a staging tree holding only the consumed archive is discarded, not retained" \
  '[[ ! -e "$state/retained/.Owltype.pkg-staging" ]]'
check "registered leftover bundles are unregistered for root and the console user" \
  '[[ $(grep -cxF -- "-u $im/.Owltype.abandoned-A/Owltype.app" "$MOCK_LOG") == 2 && $(grep -cxF -- "-u $im/.Owltype.failed-D" "$MOCK_LOG") == 2 ]]'
check "update context is still captured" '[[ "$(cat "$state/markers/install-kind")" == update ]]'

# 2. Postinstall commits and leaves nothing behind in Input Methods or the state directory.
pkg_payload
if run postinstall; then ok "postinstall succeeds"; else bad "postinstall: $(cat "$work/postinstall.out")"; fi
check "postinstall removes the consumed archive and the staging directory" \
  '[[ "$(listing "$im")" == ".Other Owltype.app Squirrel.app " ]]'
check "postinstall removes its private unpack directory" '! compgen -G "$state/unpack.*" >/dev/null'
check "session phase ran after the file commit" '[[ "$(cat "$FINISH_LOG")" == "--finish-install update im.owltype.inputmethod.Owltype.Hans 9999" ]]'

# 3. A failed commit keeps the unpacked App for diagnosis, outside Input Methods.
reset_root
run preinstall
pkg_payload
if MOCK_COMMIT_FAIL=1 run postinstall; then bad "postinstall must fail when the commit fails"; else ok "postinstall fails closed on a failed commit"; fi
check "failed unpack is retained in the state directory" \
  '[[ $(compgen -G "$state/unpack.*/Owltype.app" | wc -l) -eq 1 ]]'
check "a failed commit adds no bundle to Input Methods" \
  '[[ "$(listing "$im")" == ".Other .Owltype.pkg-staging Owltype.app Squirrel.app " && "$(listing "$staging")" == "Owltype.app.zip " ]]'
check "a failed commit does not start the session phase" '[[ ! -e "$FINISH_LOG" ]]'

# 4. A staging tree with anything but the archive (an old-format App payload) is kept.
reset_root
mkdir -p "$staging/Owltype.app/Contents"
run preinstall
check "unknown staging content is retained and unregistered" \
  '[[ -d "$state/retained/.Owltype.pkg-staging/Owltype.app" ]] && grep -qxF -- "-u $staging/Owltype.app" "$MOCK_LOG"'

# 5. An older installer still committing keeps its directories; a stale lock does not block.
reset_root
mkdir -p "$im/.Owltype.install-lock" "$im/.Owltype.retired-G"
MOCK_OLD_COMMIT=1 run preinstall
check "legacy directories stay while an older --commit-install runs" \
  '[[ -d "$im/.Owltype.install-lock" && -d "$im/.Owltype.retired-G" && ! -e "$state/retained/.Owltype.retired-G" ]]'
run preinstall
check "a stale legacy lock is retained with the leftovers instead of blocking cleanup" \
  '[[ -d "$state/retained/.Owltype.install-lock" && -d "$state/retained/.Owltype.retired-G" && ! -e "$im/.Owltype.install-lock" ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
