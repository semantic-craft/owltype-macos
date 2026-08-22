# Issue tracker and code review: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for issue
operations. Code branches, pull requests, review, and merge state also live on
GitHub. There is no secondary code mirror or review forge.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`.
- **Read an issue**: `gh issue view <number> --comments`, including labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments` with appropriate filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`.
- **Close**: `gh issue close <number> --comment "..."`.

The canonical code remote is `origin`, pointing to
`git@github.com:semantic-craft/owltype-macos.git`. Releases are published to
`downloads.responsay.com`, not to GitHub Releases. Pass
`-R semantic-craft/owltype-macos` to `gh` when the working directory is not
available or repository inference would be ambiguous.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and pull requests, so resolve an ambiguous bare number before acting.

Create branches from fresh `origin/main`, push them to `origin`, and use `gh pr`
for creation, review, checks, and merge. There is no hosted CI; the merger must
record the exact local `scripts/gate.sh` result on the pull request before merge.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. Create it with `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue. Where sub-issues are unavailable, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Use a `wayfinder:<type>` label: `research`, `prototype`, `grilling`, or `task`.
- **Blocking**: use GitHub's native issue dependencies. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric database ID, not its issue number or node ID. Where dependencies are unavailable, use a `Blocked by: #<n>, #<n>` line at the top of the child body.
- **Frontier query**: list the map's open children, drop tickets with an open blocker or assignee, and take the first remaining ticket in map order.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write.
- **Resolve**: comment with the answer, close the child ticket, then append a context pointer to the map's Decisions-so-far.
