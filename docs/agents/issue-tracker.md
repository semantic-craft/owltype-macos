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
record the exact local [local gate](../../scripts/gate.sh) result on the pull request before merge.

## Project housekeeping and closeout

Housekeeping includes reconciling open issues with the current implementation.
A clean checkout and an empty PR list establish Git state only. An open issue
establishes tracker state; implementation and acceptance need their own evidence.

1. Enumerate every open issue in the requested scope, including parent specs and
   child tickets. For project-wide housekeeping, cover the whole open backlog.
   Read each issue's acceptance criteria and comments. Page through results;
   a truncated listing or body leaves that part of the audit incomplete.
2. At a recorded, freshly fetched main commit, trace each acceptance criterion to
   current code, merged PRs and relevant tests or release/host-acceptance records.
   A filename or symbol match is a starting point, not proof of working behaviour.
   Record implementation and verification separately: implemented, partial or
   absent; automated checks, installed-host acceptance and release evidence.
   Missing evidence is **unverified**, not evidence that a feature is absent.
3. Resolve conflicts between old plans and later delivery records. Record which
   criteria were superseded and why; preserve useful decisions and acceptance
   evidence. Historical version numbers are not instructions to repeat a release,
   installation, data migration or retired-machine task.
4. Within the user's authorized scope, update the original issues with the checked
   commit, evidence links and exact remaining criteria. Close completed issues only
   when all applicable criteria have evidence; close superseded issues with the
   replacement or cancellation rationale. Keep partial work and unresolved evidence
   gaps open. Parent specs require their own end-to-end acceptance, even when all
   child tickets are closed. Reuse issues rather than creating a second status ledger.
5. Report each retained issue by number, with the reason and remaining work. Separate
   implementation gaps from verification gaps and from items not yet audited.
   Finish the in-scope audit before declaring project housekeeping complete; if
   access or another blocker prevents it, identify the exact unchecked items and
   report partial completion. Backlog reconciliation does not itself expand the
   task into implementing every retained feature.

Use existing receipts when they match the criterion and relevant code revision;
run focused checks for unresolved behaviour within scope. A broad passing gate
cannot substitute for an issue's required host or release acceptance. Repository
cleanup follows [local gate operations](../operations/ci.md#cleaning-up-after-the-gate)
after identifying the evidence and resources that must remain.

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

## Input alignment work

Pinyin #280 and Wubi #294 share the [coordination entry](../input-alignment.md) and
[generated progress](../../progress/index.html). Check native blockers and current ownership
before claiming; use the existing TeslaHub atomic claim workflow, not independent agent ledgers.
