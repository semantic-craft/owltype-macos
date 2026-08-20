#!/usr/bin/env bash
# The companion to scripts/gate.sh: the gate and every worktree build produce
# derived artifacts, and this removes the ones that are no longer reachable.
#
# It exists because the leftovers are not merely wasted disk. Every build of
# Owltype.app registers another bundle claiming `im.owltype.inputmethod.Owltype` with
# LaunchServices, and those claims outlive the directory they point at. Once
# enough dead claims accumulate, macOS can resolve the input method to an
# ad-hoc development build instead of the installed, notarized one — which is
# how a working install starts failing for reasons that have nothing to do with
# the code. Left alone this grows without bound: one sweep found 98 dead claims
# against a single live one, next to 66 GB of orphaned Xcode DerivedData.
#
# Scope is deliberately narrow. This touches only artifacts belonging to *this*
# repository and only registrations for *this* app. It never removes another
# project's DerivedData, never deletes a Time Machine snapshot, and never
# rebuilds the LaunchServices database — a global rebuild would reset file
# associations far outside this project, and unregistering the exact stale
# paths achieves the same thing without that blast radius.
#
# Usage, from anywhere inside the worktree:
#
#   scripts/clean-dev.sh           # report what would be removed, change nothing
#   scripts/clean-dev.sh --apply   # actually remove it
set -euo pipefail

apply=0
case "${1:-}" in
  "") ;;
  --apply) apply=1 ;;
  *) echo "usage: scripts/clean-dev.sh [--apply]" >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel)"
main_root="$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"
repo_name="$(basename "$main_root")"
cd "$root"

stage() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
freed=0

du_human() {
  local kb="$1"
  if ((kb >= 1048576)); then awk -v k="$kb" 'BEGIN{printf "%.1fG", k/1048576}'
  elif ((kb >= 1024)); then printf '%dM' $((kb / 1024))
  else printf '%dK' "$kb"; fi
}

# Report a removal candidate, and delete it under --apply. Size is measured
# before the removal so the report and the action agree.
reclaim() {
  local target="$1" label="${2:-}" kb
  [[ -e "$target" ]] || return 0
  kb="$(du -sk "$target" 2>/dev/null | cut -f1)" || kb=0
  freed=$((freed + kb))
  if ((apply)); then
    rm -rf "$target"
    printf '  removed       %8s  %s%s\n' "$(du_human "$kb")" "$target" "${label:+  ($label)}"
  else
    printf '  would remove  %8s  %s%s\n' "$(du_human "$kb")" "$target" "${label:+  ($label)}"
  fi
}

# --- Build output inside the repository and its worktrees --------------------
#
# A release cohort directory holds the signed, notarized record of a shipped
# version (OWLTYPE-RELEASE-COHORT.json and its siblings). That record is kept:
# it is small, it is evidence of what was published, and re-creating it would
# mean another notarization round trip. Everything beside it under the same
# output root is ordinary build output.

stage "build output in this repository"

while IFS= read -r wt; do
  [[ -n "$wt" && -d "$wt" ]] || continue
  reclaim "$wt/installer/build" "xcodegen build product"
  [[ -d "$wt/build" ]] || continue
  for d in "$wt/build"/*; do
    [[ -d "$d" ]] || continue
    if [[ -f "$d/release/OWLTYPE-RELEASE-COHORT.json" ]]; then
      # Keep the cohort record; drop the build intermediates around it.
      for sub in "$d"/*; do
        if [[ -d "$sub" && "$(basename "$sub")" != "release" ]]; then
          reclaim "$sub" "cohort build output"
        fi
      done
      printf '  kept          %8s  %s\n' \
        "$(du_human "$(du -sk "$d/release" | cut -f1)")" "$d/release"
    else
      reclaim "$d" "build output"
    fi
  done
done < <(git worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

# --- Xcode DerivedData belonging to this repository --------------------------
#
# The product itself builds into the repository (DERIVED_DATA_PATH /
# RELEASE_OUTPUT_ROOT), but building the Sparkle submodule lands in the shared
# DerivedData directory. Only entries whose recorded workspace belonged to this
# repository *and* no longer exists are removed; another project's entries and
# any entry whose workspace is still on disk are left alone.

stage "orphaned Xcode DerivedData from this repository"

dd="$HOME/Library/Developer/Xcode/DerivedData"
if [[ -d "$dd" ]]; then
  for entry in "$dd"/*/; do
    name="$(basename "$entry")"
    [[ "$name" == *.noindex ]] && continue
    wp="$(plutil -extract WorkspacePath raw "$entry/info.plist" 2>/dev/null)" || continue
    [[ -n "$wp" ]] || continue
    # belongs to this repository, by main-worktree path or by repository name
    # (agent worktrees live outside the repository, e.g. ~/.codex/worktrees/…)
    case "$wp" in
      "$main_root"/*|*/"$repo_name"/*) ;;
      *) continue ;;
    esac
    [[ -e "$wp" ]] && continue   # workspace still exists; Xcode may reuse it
    reclaim "${entry%/}" "workspace gone: $wp"
  done
fi

# --- Stale LaunchServices registrations for this app -------------------------

stage "stale LaunchServices registrations for Owltype.app"

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$lsregister" ]]; then
  stale=0
  live=0
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    if [[ -e "$bundle" ]]; then
      live=$((live + 1))
      printf '  live          %s\n' "$bundle"
      continue
    fi
    stale=$((stale + 1))
    if ((apply)); then
      "$lsregister" -u "$bundle" >/dev/null 2>&1 || true
    fi
  done < <("$lsregister" -dump 2>/dev/null \
    | grep -E '^path:' \
    | sed -E 's/^path:[[:space:]]*//; s/ \(0x[0-9a-f]+\)$//' \
    | grep -E '/Owltype\.app$' \
    | sort -u)

  if ((apply)); then
    printf '  unregistered  %d stale bundle path(s); %d live registration(s) remain\n' "$stale" "$live"
  else
    printf '  would unregister  %d stale bundle path(s); %d live registration(s) remain\n' "$stale" "$live"
  fi
  if ((live > 1)); then
    printf '  NOTE: more than one live Owltype.app is registered. Only the installed\n'
    printf '        /Library/Input Methods/Owltype.app should normally be present;\n'
    printf '        a stray build product can shadow it.\n'
  fi
else
  echo "  lsregister not found; skipped" >&2
fi

# --- Summary -----------------------------------------------------------------

echo
if ((apply)); then
  echo "clean-dev: removed $(du_human "$freed")"
  echo "Note: recently deleted files can stay pinned by Time Machine local snapshots,"
  echo "so free space may not move until macOS thins them. Snapshots are backups and"
  echo "are never touched here."
else
  echo "clean-dev: would remove $(du_human "$freed") — re-run with --apply to do it"
fi
