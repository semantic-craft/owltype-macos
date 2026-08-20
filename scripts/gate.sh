#!/usr/bin/env bash
# The repository gate: the checks a change must pass before it is merged to
# main, run on this Mac.
#
# There is no hosted CI. Depot (portable policy lane on Linux) and Buildkite
# (hosted Apple Silicon macOS) were trials of paid services and were retired
# rather than paid for; the Origin merge ruleset requires only an up-to-date
# branch. This script is what makes a merge honest, and it runs exactly what
# those two lanes ran, minus one thing: the installed input-method smoke
# (install-dev.sh + check-installed.sh). That smoke was meaningful only on a
# disposable hosted runner and must not run on a persistent developer or
# release machine without a separate safety review (docs/operations/ci.md).
#
# Usage, from anywhere inside the worktree:
#
#   scripts/gate.sh           # policy lane + full macOS lane (tens of minutes)
#   scripts/gate.sh --quick   # policy lane + swiftlint + make test
set -euo pipefail

mode="full"
case "${1:-}" in
  "") ;;
  --quick) mode="quick" ;;
  *) echo "usage: scripts/gate.sh [--quick]" >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel)"
cd "$root"

stage() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)" >&2; exit 1; }; }
need python3 "python3"
need gitleaks "brew install gitleaks"
need trufflehog "brew install trufflehog"
need swiftlint "brew install swiftlint"
need xcodegen "brew install xcodegen"

# --- Policy lane (was Depot CI) ----------------------------------------------------

stage "public source and privacy boundaries"
bash scripts/check-public-source.sh
bash scripts/check-public-privacy.selftest.sh

stage "portable scripts"
bash -n action-install.sh scripts/*.sh package/apple_tool_adapter package/make_package
python3 -m py_compile \
  scripts/famo_distribution.py \
  scripts/famo_bundle.py \
  scripts/inventory-release-bundle.py \
  scripts/release-cohort-state.py \
  scripts/release_source.py \
  scripts/safe-extract-tar.py
python3 scripts/famo-distribution.selftest.py
python3 scripts/release-source-archive.selftest.py

stage "secret-finding policy"
python3 scripts/secret-finding-policy.selftest.py

stage "reachable history: gitleaks and trufflehog"
scan_dir="$(mktemp -d)"
trap 'rm -rf "$scan_dir"' EXIT
gitleaks git --redact=100 --no-banner --no-color --exit-code=0 \
  --log-level=error --report-format=json \
  --report-path="$scan_dir/gitleaks.json" --log-opts=--all .
python3 scripts/secret-finding-policy.py history gitleaks "$scan_dir/gitleaks.json"
trufflehog git "file://$root" --results=verified,unknown,unverified \
  --no-update --json >"$scan_dir/trufflehog.jsonl"
python3 scripts/secret-finding-policy.py history trufflehog "$scan_dir/trufflehog.jsonl"

stage "licensing and repository policy files"
test -s LICENSE.txt
test -s THIRD_PARTY_NOTICES.md
test -s PROVENANCE.md
test -s PRIVACY.md
test -s SECURITY.md
grep -q 'GPL-3.0' README.md

# --- macOS lane (was Buildkite) -------------------------------------------------------

stage "bootstrap and seed"
git submodule update --init --recursive
make bootstrap
make famo-seed

stage "swiftlint and release self-test"
swiftlint
bash scripts/check-release.selftest.sh

stage "make test"
make test DERIVED_DATA_PATH=build/gate-tests

# --- LaunchServices claims on this app's bundle id ---------------------------
#
# Every build of the app registers another bundle claiming the input method's
# identifier. macOS resolves an input method by identifier, so once a build
# claims it too, login can resolve to that build rather than the installed copy:
# the IMK service fails to come up and the system falls through to whatever
# input source comes next. That is the measured cause of "the default input
# method changes after a restart" on this machine, and it regenerates every time
# the gate runs (docs/default-input-method-plan.md §1.3 结论 A/C).
#
# This reports and stops there. Sweeping it is `scripts/clean-dev.sh --apply`,
# which removes build products a parallel session may still be using, so it
# stays a deliberate manual act (plan §8.2). Silent when exactly one signed
# bundle claims the id — the shape a clean machine has. The dump scan costs
# ~15s; the identifier comes from the identity manifest, never a second copy.
report_ls_claims() {
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [[ -x "$lsregister" ]] || return 0
  # shellcheck source=scripts/owl-identity.sh
  source scripts/owl-identity.sh

  # One record per registration: `path:` opens it, `teamID:` appears only when the
  # bundle is signed with a team, `identifier:` closes it. "-" marks unsigned.
  local rows
  rows="$("$lsregister" -dump 2>/dev/null | awk -v want="$OWL_BUNDLE_ID" '
    /^path:/       { p = $0; sub(/^path:[[:space:]]*/, "", p); sub(/ \(0x[0-9a-f]+\)$/, "", p); t = "" }
    /^teamID:/     { t = $0; sub(/^teamID:[[:space:]]*/, "", t) }
    /^identifier:/ { id = $0; sub(/^identifier:[[:space:]]*/, "", id)
                     if (id == want) printf "%s\t%s\n", (t == "" ? "-" : t), p }
  ')"

  local total=0 unsigned=0 team path
  while IFS=$'\t' read -r team path; do
    [[ -n "$path" ]] || continue
    total=$((total + 1))
    if [[ "$team" == "-" ]]; then unsigned=$((unsigned + 1)); fi
  done <<<"$rows"

  # Healthy: the installed copy alone, signed. Nothing to say.
  if ((total <= 1 && unsigned == 0)); then return 0; fi

  stage "LaunchServices claims on $OWL_BUNDLE_ID"
  if ((unsigned > 0)); then
    printf '  FAMO-LS-002  %d claim(s), %d of them unsigned (no teamID)\n' "$total" "$unsigned"
  else
    printf '  FAMO-LS-001  %d claim(s); only the installed copy should claim this id\n' "$total"
  fi
  while IFS=$'\t' read -r team path; do
    [[ -n "$path" ]] || continue
    printf '    teamID=%-14s %s\n' "$team" "$path"
  done <<<"$rows"
  printf '  A build claiming this id can be resolved instead of the installed copy\n'
  printf '  at login. To clear it:  scripts/clean-dev.sh --apply\n'
  printf '  Not done here: that removes build products a parallel session may still\n'
  printf '  be using. Warning only — the gate result below is unaffected.\n'
}

if [[ "$mode" == "quick" ]]; then
  report_ls_claims
  echo; echo "gate --quick: ok (debug/release builds, release gates, secret artifact scan and periphery skipped)"
  exit 0
fi

stage "debug and release builds"
make debug
make release \
  RELEASE_OUTPUT_ROOT=build/gate-release \
  BUILD_SETTINGS="COMPILER_INDEX_STORE_ENABLE=NO SWIFT_COMPILATION_MODE=singlefile SWIFT_ENABLE_BATCH_MODE=NO"
app="$root/build/gate-release/Build/Products/Release/Famo.app"

stage "release gates"
OWL_APP="$app" bash scripts/check-manifest.sh
OWL_APP="$app" bash scripts/check-identity-residual.sh
bash scripts/check-identity-residual.selftest.sh
bash scripts/release-artifact-chain.selftest.sh "$app"
bash scripts/release-cohort.selftest.sh
bash scripts/release-cohort-transition.selftest.sh
bash scripts/release-chain.selftest.sh
python3 scripts/secret-finding-policy.selftest.py
bash scripts/check-secrets.sh
bash scripts/check-secrets.sh --artifacts "$app"

stage "periphery"
if command -v periphery >/dev/null 2>&1; then
  periphery scan \
    --relative-results \
    --skip-build \
    --index-store-path build/Index.noindex/DataStore
else
  echo "periphery is not installed (brew install peripheryapp/periphery/periphery); unused-code scan skipped." >&2
  exit 1
fi

report_ls_claims
echo; echo "gate: ok (the installed input-method smoke is intentionally not part of the gate on a persistent machine)"
