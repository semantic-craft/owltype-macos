#!/usr/bin/env bash
# Complete local merge gate; --quick stops after the offline product tests.
# Installed acceptance is separate: see docs/operations/ci.md.
set -euo pipefail
mode=full
list_stages=0
for argument in "$@"; do
  case "$argument" in
    --quick) mode=quick ;;
    --list-stages) list_stages=1 ;;
    *) echo "usage: scripts/gate.sh [--quick] [--list-stages]" >&2; exit 2 ;;
  esac
done

# This is the single execution order, also exposed to the verification recorder.
gate_steps=(tools submodules source_boundary navigation portable_scripts secret_policy
            history_scan licensing bootstrap_seed lint_release_tests product_tests)
if [[ "$mode" == full ]]; then
  gate_steps+=(builds release_checks unused_code)
fi
gate_steps+=(report_ls_claims)
if ((list_stages)); then
  printf '%s\n' "${gate_steps[@]}"
  exit 0
fi
root="$(git rev-parse --show-toplevel)"
cd "$root"
if [[ "${OWL_VERIFICATION_ACTIVE:-}" != 1 ]]; then
  exec python3 scripts/verify.py "$mode"
fi
stage() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)" >&2; exit 1; }; }
tools() {
  need python3 "python3"
  need gitleaks "brew install gitleaks"
  need trufflehog "brew install trufflehog"
  need swiftlint "brew install swiftlint"
  need xcodegen "brew install xcodegen"
}

# A fresh worktree starts with empty submodule directories and any later stage may read them
# (portable_scripts archives Sparkle/ at its pinned revision), so the checkout is completed
# before the first check. The recorder treats a submodule at its gitlink as unchanged,
# initialized or not, so this stage is never a source change.
submodules() {
  stage "submodules at their pinned revisions"
  git submodule update --init --recursive
}

source_boundary() {
  stage "public source and privacy boundaries"
  bash scripts/check-public-source.sh
  bash scripts/check-public-privacy.selftest.sh
  bash scripts/check-public-source.selftest.sh
  bash scripts/check-ai-off-hot-path.sh
}

navigation() {
  stage "navigation references"
  python3 scripts/verify.selftest.py
  python3 scripts/check-navigation.selftest.py
  python3 scripts/check-navigation.py
}

portable_scripts() {
  python3 scripts/test_cleanup_app_registrations.py
  stage "portable scripts"
  bash -n action-install.sh scripts/*.sh package/apple_tool_adapter package/make_package \
    package/*.command
  python3 -m py_compile \
    scripts/owl_distribution.py \
    scripts/owl_bundle.py \
    scripts/check-rust-delivery.py \
    scripts/owl-agent-mcp-licenses.py \
    scripts/merge-pr.py \
    scripts/fetch-msime-others.py \
    scripts/fetch-rerank-models.py \
    scripts/install-reference-dictionary-update.py \
    scripts/msime_pin.py \
    scripts/msime-dictionary-diff.py \
    scripts/finalize-release-bundle.py \
    scripts/inventory-release-bundle.py \
    scripts/release-bundle.selftest.py \
    scripts/release-cohort-state.py \
    scripts/release_source.py \
    scripts/safe-extract-tar.py
  python3 scripts/check-rust-delivery.selftest.py
  python3 scripts/fetch-msime-resources.selftest.py
  python3 scripts/fetch-msime-others.selftest.py
  python3 scripts/msime_pin.selftest.py
  python3 scripts/merge-pr.selftest.py
  python3 scripts/msime_pin.py check
  python3 scripts/msime-dictionary-diff.selftest.py
  python3 scripts/fetch-rerank-models.selftest.py
  python3 scripts/test-defaults-isolation.selftest.py
  python3 scripts/pinyin-parity.selftest.py
  python3 scripts/progress-sync.selftest.py
  python3 scripts/release-bundle.selftest.py
  python3 scripts/owl-distribution.selftest.py
  python3 scripts/release-source-archive.selftest.py
  python3 scripts/build-sparkle.selftest.py
  bash scripts/check-live-ime-version.sh --self-test
  python3 scripts/smoke-live.selftest.py
  bash scripts/install-dev.selftest.sh
  bash scripts/pkg-leftovers.selftest.sh
  bash scripts/uninstall-repair.selftest.sh
  bash scripts/live-test.selftest.sh
  bash scripts/clean-dev.selftest.sh
  python3 scripts/check-ime-host-evidence.selftest.py
  xcrun swiftc -typecheck scripts/ime-acceptance-host.swift
}

secret_policy() {
  stage "secret-finding policy"
  python3 scripts/secret-finding-policy.selftest.py
}

history_scan() {
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
}

licensing() {
  stage "licensing and repository policy files"
  test -s LICENSE.txt
  test -s THIRD_PARTY_NOTICES.md
  test -s PROVENANCE.md
  test -s PRIVACY.md
  test -s SECURITY.md
  test -s rust/crates/chinese-ime-lm/LICENSE
  printf 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  rust/crates/chinese-ime-lm/LICENSE\n' |
    shasum -a 256 --check --status
  grep -q 'GPL-3.0' README.md
}

bootstrap_seed() {
  stage "bootstrap and seed"
  make bootstrap
  make owl-seed
}

lint_release_tests() {
  stage "swiftlint and release self-test"
  swiftlint
  bash scripts/check-release.selftest.sh
}

product_tests() {
  stage "cargo test (Owltype App business core and ABI)"
  cargo test --locked --manifest-path rust/Cargo.toml --package owl-app-core --package owl-msime-ffi
  python3 scripts/check-business-boundary.py
  stage "cargo test (owl-msime-ffi)"
  cargo test --locked --manifest-path rust/Cargo.toml --package owl-msime-ffi
  stage "cargo test (owl-agent-mcp) and helper crate licenses"
  python3 scripts/owl-agent-mcp-licenses.py --check
  cargo test --locked --manifest-path rust/Cargo.toml --package owl-agent-mcp
  stage "make test"
  make test DERIVED_DATA_PATH=build/gate-tests TEST_ONLY=
}

builds() {
  stage "debug and release builds"
  make debug
  make release \
    RELEASE_OUTPUT_ROOT=build/gate-release \
    BUILD_SETTINGS="COMPILER_INDEX_STORE_ENABLE=NO SWIFT_COMPILATION_MODE=singlefile SWIFT_ENABLE_BATCH_MODE=NO"
  app="$root/build/gate-release/Build/Products/Release/Owltype.app"
}

release_checks() {
  stage "release gates"
  OWL_APP="$app" bash scripts/check-manifest.sh
  # At this point this gate has built only the App. Explicitly hide any package/installer/DMG left
  # by an older local release so the verdict cannot depend on stale, non-cohort artifacts. The
  # mechanical artifact-chain test below builds and strictly scans all four fresh layers together.
  OWL_APP="$app" \
    OWL_INSTALLER_APP=/nonexistent \
    OWL_PKG=/nonexistent \
    OWL_DMG=/nonexistent \
    bash scripts/check-identity-residual.sh
  bash scripts/check-identity-residual.selftest.sh
  bash scripts/release-artifact-chain.selftest.sh "$app"
  bash scripts/release-cohort.selftest.sh
  bash scripts/release-cohort-transition.selftest.sh
  python3 scripts/sparkle-key-transition.selftest.py
  bash scripts/release-chain.selftest.sh
  python3 scripts/secret-finding-policy.selftest.py
  bash scripts/check-secrets.sh
  bash scripts/check-secrets.sh --artifacts "$app"
}

unused_code() {
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
}

# --- LaunchServices claims on this app's bundle id ---------------------------
#
# Every build of the app registers another bundle claiming the input method's
# identifier. macOS resolves an input method by identifier, so once a build
# claims it too, login can resolve to that build rather than the installed copy:
# the IMK service fails to come up and the system falls through to whatever
# input source comes next. That is the measured cause of "the default input
# method changes after a restart" on this machine, and it regenerates every time
# the gate runs.
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
    printf '  OWL-LS-002  %d claim(s), %d of them unsigned (no teamID)\n' "$total" "$unsigned"
  else
    printf '  OWL-LS-001  %d claim(s); only the installed copy should claim this id\n' "$total"
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


for gate_step in "${gate_steps[@]}"; do
  printf 'OWL_GATE_STAGE\t%s\n' "$gate_step"
  "$gate_step"
done
if [[ "$mode" == quick ]]; then
  echo "gate --quick: ok (debug/release builds, release gates, secret artifact scan and periphery skipped)"
else
  echo "gate: ok (the installed input-method smoke is intentionally not part of the gate on a persistent machine)"
fi
