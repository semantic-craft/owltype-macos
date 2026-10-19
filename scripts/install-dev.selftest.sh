#!/usr/bin/env bash
# Behavior test for install-dev.sh: an installed input method must carry a stable
# designated requirement, never an ad hoc cdhash. Runs the real script from a throwaway
# root with a fake bundle, a fake HOME and mocked make/codesign/security/killall/open, so
# nothing is built, signed, killed or installed on this machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/owl-install-dev-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

mocks="$work/mocks"
mkdir -p "$mocks"
for tool in make killall open sleep; do
  printf '#!/bin/sh\nexit 0\n' >"$mocks/$tool"
done
# security: lists the identities in MOCK_IDENTITIES (newline-separated).
cat >"$mocks/security" <<'EOF'
#!/bin/sh
printf '%s\n' "$MOCK_IDENTITIES" | sed '/^$/d' | while IFS= read -r name; do
  printf '  1) 0000000000000000000000000000000000000000 "%s"\n' "$name"
done
EOF
# codesign: keeps each bundle's mock requirement in Contents/.mock-requirement so it
# travels with rsync/cp like a real signature. MOCK_SIGN_NOOP=1 simulates a signing step
# that leaves the build product ad hoc.
cat >"$mocks/codesign" <<'EOF'
#!/bin/bash
identity="" display=0 verify=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --sign|-s) identity="${args[i + 1]}" ;;
    -d|--display) display=1 ;;
    --verify|-v) verify=1 ;;
  esac
done
bundle="${args[${#args[@]} - 1]}"
marker="$bundle/Contents/.mock-requirement"
if (( display )); then
  [[ -f "$marker" ]] || { echo "$bundle: code object is not signed at all" >&2; exit 1; }
  cat "$marker"
  exit 0
fi
if (( verify )); then
  [[ -f "$marker" ]] || exit 1
  exit 0
fi
[[ -n "$identity" ]] || exit 1
echo "$*" >>"$MOCK_LOG"
[[ "${MOCK_SIGN_NOOP:-}" == 1 ]] && exit 0
if [[ "$identity" == - ]]; then
  echo "# designated => cdhash H\"$(date +%s%N)\"" >"$marker"
else
  echo "designated => identifier \"im.owltype.inputmethod.Owltype\" and certificate leaf[subject.CN] = \"$identity\"" >"$marker"
fi
EOF
chmod +x "$mocks"/*

DEVID="Developer ID Application: Test Owner (TEAMID0000)"
APPLEDEV="Apple Development: Test Owner (CERTID0000)"

# Fresh fake project root + HOME per case. Installed app path is echoed via globals.
setup_case() {
  case_dir="$work/$1"
  fake_root="$case_dir/root"
  fake_home="$case_dir/home"
  mkdir -p "$fake_root/scripts" "$fake_root/resources" "$fake_home"
  cp "$ROOT/scripts/install-dev.sh" "$fake_root/scripts/"
  [[ -f "$ROOT/scripts/stable-sign-identity.sh" ]] && cp "$ROOT/scripts/stable-sign-identity.sh" "$fake_root/scripts/"
  cp "$ROOT/resources/Owltype.entitlements" "$fake_root/resources/"
  : >"$fake_root/Makefile"
  app="$fake_root/build/Build/Products/Debug/Owltype.app"
  mkdir -p "$app/Contents/MacOS"
  cat >"$app/Contents/MacOS/Owltype" <<EOF
#!/bin/sh
echo "\$*" >>"$case_dir/exe.log"
EOF
  chmod +x "$app/Contents/MacOS/Owltype"
  # Xcode/Makefile leave the build product ad hoc signed.
  echo '# designated => cdhash H"0123456789abcdef"' >"$app/Contents/.mock-requirement"
  installed="$fake_home/Library/Input Methods/Owltype.app"
  log="$case_dir/codesign.log"
  : >"$log"
}

run_install() {
  set +e
  out=$(env -i PATH="$mocks:/usr/bin:/bin" HOME="$fake_home" TMPDIR="$case_dir" \
    OWL_ALLOW_USER_DUPLICATE=1 MOCK_LOG="$log" "$@" \
    bash "$fake_root/scripts/install-dev.sh" 2>&1)
  rc=$?
  set -e
}

installed_requirement() { cat "$installed/Contents/.mock-requirement" 2>/dev/null || true; }

# 1. With a Developer ID identity, the installed copy carries a stable requirement.
setup_case stable
run_install MOCK_IDENTITIES="$APPLEDEV
$DEVID"
if [[ $rc == 0 && -d "$installed" ]] && [[ "$(installed_requirement)" == *"$DEVID"* ]] \
  && ! grep -q -- '--sign -' "$log"; then
  ok "installs with the Developer ID identity and never signs ad hoc"
else
  bad "stable install: rc=$rc requirement=$(installed_requirement)"; echo "$out" >&2
fi
if grep -q -- '--options runtime' "$log" && grep -q -- '--entitlements' "$log"; then
  ok "signs with hardened runtime and the App entitlements"
else
  bad "signing flags: $(cat "$log")"
fi

# 2. Apple Development is the fallback identity.
setup_case appledev
run_install MOCK_IDENTITIES="$APPLEDEV"
if [[ $rc == 0 && "$(installed_requirement)" == *"$APPLEDEV"* ]]; then
  ok "falls back to the Apple Development identity"
else
  bad "Apple Development fallback: rc=$rc requirement=$(installed_requirement)"; echo "$out" >&2
fi

# 3. No identity: refuse before touching the install location.
setup_case none
run_install MOCK_IDENTITIES=""
if [[ $rc != 0 && ! -e "$installed" && "$out" == *OWL_SIGN_IDENTITY* ]]; then
  ok "refuses to install without a stable identity and names OWL_SIGN_IDENTITY"
else
  bad "no identity: rc=$rc installed=$([[ -e "$installed" ]] && echo yes || echo no)"; echo "$out" >&2
fi

# 4. An explicit ad hoc override is refused.
setup_case override
run_install MOCK_IDENTITIES="$DEVID" OWL_SIGN_IDENTITY=-
if [[ $rc != 0 && ! -e "$installed" ]]; then
  ok "refuses OWL_SIGN_IDENTITY=-"
else
  bad "ad hoc override: rc=$rc requirement=$(installed_requirement)"; echo "$out" >&2
fi

# 5. Signing that leaves a cdhash requirement is caught by the designated-requirement check.
setup_case noop
run_install MOCK_IDENTITIES="$DEVID" MOCK_SIGN_NOOP=1
if [[ $rc != 0 && ! -e "$installed" && "$out" == *cdhash* && "$out" == *install-dev.sh* ]]; then
  ok "rejects a cdhash candidate before installing and prints the install command"
else
  bad "cdhash candidate: rc=$rc requirement=$(installed_requirement)"; echo "$out" >&2
fi

# 6. A different stable identity than the installed copy would drop Keychain grants.
setup_case mismatch
mkdir -p "$installed/Contents"
echo "designated => identifier \"im.owltype.inputmethod.Owltype\" and certificate leaf[subject.CN] = \"$APPLEDEV\"" \
  >"$installed/Contents/.mock-requirement"
run_install MOCK_IDENTITIES="$DEVID"
if [[ $rc != 0 && "$(installed_requirement)" == *"$APPLEDEV"* && "$out" == *OWL_SIGN_IDENTITY* ]]; then
  ok "refuses to replace an installed copy signed by another identity"
else
  bad "identity mismatch: rc=$rc requirement=$(installed_requirement)"; echo "$out" >&2
fi

# 7. An installed ad hoc copy is replaced by the stable build.
setup_case replace-adhoc
mkdir -p "$installed/Contents"
echo '# designated => cdhash H"feedface"' >"$installed/Contents/.mock-requirement"
run_install MOCK_IDENTITIES="$DEVID"
if [[ $rc == 0 && "$(installed_requirement)" == *"$DEVID"* ]]; then
  ok "replaces an earlier ad hoc install with the stable build"
else
  bad "replace ad hoc: rc=$rc requirement=$(installed_requirement)"; echo "$out" >&2
fi

# 8. The old Makefile install targets copied ad hoc/unsigned builds over the system copy.
for target in install install-debug install-release; do
  set +e
  out=$(make -s -C "$ROOT" "$target" 2>&1)
  rc=$?
  set -e
  if [[ $rc != 0 && "$out" == *install-dev.sh* ]]; then
    ok "make $target refuses and names install-dev.sh"
  else
    bad "make $target: rc=$rc"; echo "$out" >&2
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
