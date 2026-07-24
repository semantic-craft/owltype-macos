#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failed=0

while IFS= read -r -d '' tracked_path; do
  basename="${tracked_path##*/}"

  case "$basename" in
    .env.example|.env.sample|.env.template)
      ;;
    .env|.env.*|*.pem|*.p12|*.p8|*.key|*.keystore|*.jks|*.mobileprovision|\
    id_rsa|id_dsa|id_ecdsa|id_ed25519|credentials.json|secrets.json|secrets.yaml|secrets.yml|\
    *.session|*.transcript|*.chatlog|*.log)
      printf 'blocked sensitive filename: %s\n' "$tracked_path" >&2
      failed=1
      ;;
  esac

  case "$tracked_path" in
    .claude/settings.local.json|*/.claude/settings.local.json|\
    .codex/*|*/.codex/*|.cursor/*|*/.cursor/*|.windsurf/*|*/.windsurf/*|\
    .continue/*|*/.continue/*|.aider*|*/.aider*)
      printf 'blocked local AI-agent state: %s\n' "$tracked_path" >&2
      failed=1
      ;;
  esac
done < <(git ls-files -z)

privacy_matches="$(
  git grep -I -l -E \
    '(-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----|(^|[[:space:]="'\''(=])(/Users/[^/[:space:]]+/|/home/[^/[:space:]]+/|[A-Za-z]:\\Users\\[^\\[:space:]]+\\))' \
    -- . \
    ':(exclude)scripts/check-public-privacy.sh' \
    ':(exclude)scripts/check-public-privacy.selftest.sh' || true
)"
if [[ -n "$privacy_matches" ]]; then
  printf 'private key material or personal home-directory path found in:\n%s\n' \
    "$privacy_matches" >&2
  failed=1
fi

private_repo_matches="$(
  git grep -I -l -E \
    'semantic-craft/(famoime-mac|famotype-mac-private|famotype-macos-retired-private|famotype-macos-merge-metadata)' \
    -- . \
    ':(exclude)scripts/check-public-privacy.sh' \
    ':(exclude)scripts/check-public-privacy.selftest.sh' || true
)"
if [[ -n "$private_repo_matches" ]]; then
  printf 'private repository identity found in:\n%s\n' "$private_repo_matches" >&2
  failed=1
fi

while IFS=$'\t' read -r _ author_email committer_email; do
  for email in "$author_email" "$committer_email"; do
    case "$email" in
      noreply@github.com|*@users.noreply.github.com)
        ;;
      *)
        printf 'non-noreply Git identity found in reachable history\n' >&2
        failed=1
        break
        ;;
    esac
  done
done < <(git log --all --format='%H%x09%aE%x09%cE')

while IFS= read -r remote_name; do
  while IFS= read -r remote_url; do
    case "$remote_url" in
      *semantic-craft/famoime-mac*|\
      *semantic-craft/famotype-mac-private*|\
      *semantic-craft/famotype-macos-retired-private*|\
      *semantic-craft/famotype-macos-merge-metadata*)
        printf 'private repository configured on remote: %s\n' "$remote_name" >&2
        failed=1
        ;;
    esac
  done < <(
    {
      git remote get-url --all "$remote_name" 2>/dev/null || true
      git remote get-url --push --all "$remote_name" 2>/dev/null || true
    } | sort -u
  )
done < <(git remote)

if (( failed != 0 )); then
  exit 1
fi

printf 'public privacy check passed\n'
