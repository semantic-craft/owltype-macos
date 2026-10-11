#!/bin/bash
# Authorized native experiment only. No process/service/source or dictionary changes.
# Run as root after building the helper as the logged-in user; evidence directory must exist.
# Exchanges a same-version copy, then restores the original Contents inode before returning.
set -euo pipefail
if [[ $# != 2 || $EUID != 0 ]]; then
  echo 'usage: sudo /bin/bash scripts/spike-bundle-swap-macl.sh HELPER EXISTING_EVIDENCE_DIR' >&2
  exit 64
fi
helper=$1
evidence=$2
app='/Library/Input Methods/Owltype.app'
stage="$app/.Contents.update"
retained="$evidence/retained-Contents"
parked="$evidence/original-Contents"
[[ -x "$helper" && -d "$evidence" && ! -L "$evidence" ]]
[[ ! -e "$stage" && ! -L "$stage" && ! -e "$retained" && ! -L "$retained" ]]
[[ ! -e "$parked" && ! -L "$parked" ]]
[[ ! -L "$app" && ! -L "$app/Contents" ]]
[[ $(/usr/bin/stat -f %d "$app") == "$(/usr/bin/stat -f %d "$evidence")" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == 2.0.12 ]]
exec > >(/usr/bin/tee "$evidence/macl-spike.log") 2>&1
identity() { /usr/bin/stat -f '%d:%i' "$1"; }
macl_hash() { /usr/bin/xattr -px com.apple.macl "$app" | /usr/bin/shasum -a 256; }
snapshot() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
  echo "phase=$1 app=$(identity "$app") contents=$(identity "$app/Contents")"
  /bin/ls -ldeO@ "$app" "$app/Contents"
  echo "macl_sha256=$(macl_hash)"
}
/usr/bin/codesign --verify --deep --strict "$app"
wrapper_identity=$(identity "$app")
original_identity=$(identity "$app/Contents")
# A missing macl must fail, not become an irrelevant passing experiment.
original_macl=$(macl_hash)
copied_identity=''
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  local current
  current=$(identity "$app/Contents")
  if [[ "$current" != "$original_identity" ]]; then
    if [[ ! -e "$stage" && -d "$parked" && "$(identity "$parked")" == "$original_identity" ]]; then
      if ! /bin/mv "$parked" "$stage"; then
        echo 'STOP: cannot return parked original Contents to exchange path.'
        exit 1
      fi
    fi
    if [[ -n "$copied_identity" && "$current" == "$copied_identity" && "$(identity "$stage")" == "$original_identity" ]]; then
      if ! "$helper" exchange "$app"; then
        echo 'STOP: automatic exchange-back failed; retain both directories and request recovery.'
        exit 1
      fi
    else
      echo 'STOP: unexpected Contents identities; do not guess which directory to restore.'
      exit 1
    fi
  fi
  if [[ -d "$stage" ]]; then
    if ! /bin/mv "$stage" "$retained"; then
      echo 'STOP: original Contents restored, but staging remains in App.'
      exit 1
    fi
  fi
  snapshot restored
  [[ "$(identity "$app")" == "$wrapper_identity" && "$(identity "$app/Contents")" == "$original_identity" ]] || result=1
  [[ "$(macl_hash)" == "$original_macl" ]] || result=1
  /usr/bin/codesign --verify --deep --strict "$app" || result=1
  echo "RESULT=$result (0 means macl exchange and original-inode restoration passed)"
  exit "$result"
}
trap cleanup EXIT
snapshot before
/usr/bin/ditto "$app/Contents" "$stage"
copied_identity=$(identity "$stage")
[[ "$copied_identity" != "$original_identity" ]]
"$helper" exchange "$app"
snapshot exchanged
[[ "$(identity "$app/Contents")" == "$copied_identity" && "$(identity "$stage")" == "$original_identity" ]]
[[ "$(identity "$app")" == "$wrapper_identity" && "$(macl_hash)" == "$original_macl" ]]
# A .Contents.update sibling makes strict bundle verification fail as unsealed contents.
# Park retired contents outside the App before verifying or allowing a fresh launch.
/bin/mv "$stage" "$parked"
/usr/bin/codesign --verify --deep --strict "$app"
/bin/mv "$parked" "$stage"
"$helper" exchange "$app"
[[ "$(identity "$app/Contents")" == "$original_identity" ]]
# EXIT handler parks the test copy outside the App and verifies the restored signature.
