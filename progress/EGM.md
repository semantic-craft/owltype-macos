# Progress snapshots and projections

## Overview

This directory stores a versioned GitHub observation and generates its static HTML presentation. It does not own issue assignment or agent dispatch.

## Interface

- `[progress.py:main]` exposes `init`, `refresh`, `render`, `check`, and `publish`, with `--live`, `--publication`, `--adapter`, and `--receipt` controls. `schema`, `paths`, `generate`, `check`, and `publication` validate configuration, generated output, and supplied publication proof.
- `[progress.py:live]`, `progress_pull`, and `progress_ancestry` collect GitHub facts and recognize changes confined to `progress/` while checking snapshot ancestry.
- `[progress.py:HTML]`, `resources`, `contained`, and `relative_target` inspect reachable HTML/CSS/JavaScript/SVG resources and local link safety.
- `[sync.py:main]` refreshes the fixed `GROUPS` plus configured tracked issues/PRs, open pull requests, and releases, writes `progress.json`, and invokes render/check. It preserves editorial sections outside the generated groups and their evidence tracking.
- `[sync.py:fetch_snapshot]`, `paginate_pull_request`, and `checked_pr_node` fetch complete bounded observations, fencing PR head/base identities during pagination.

## Invariants

- `[progress.py:schema]` requires schema version 1, typed fact/evidence records, unique IDs, known statuses, tracked evidence references, and a page included in outputs. `[progress.py:safe_path]` confines paths to the repository, including symlink resolution.
- `[progress.py:generate]` requires the generated file set to equal declared outputs; `[progress.py:regenerate]` requires byte equality with checked-in outputs. `[progress.py:contained]` rejects external/runtime resource access and requires inline CSS/JavaScript in HTML outputs.
- `[progress.py:progress_ancestry]` accepts a changed live head only after proving the intervening commits change `progress/` exclusively; incomplete capped GitHub listings fail validation.
- `[sync.py:paginate_pull_request]` rejects repeated/empty cursors, duplicate/incomplete files or commits, and moving PR head/base identities. `[sync.py:complete]` rejects any remaining unconsumed pagination.
- `[sync.py:main]` classifies closed issues as `unverified`; issue closure alone does not become product acceptance. Assignees and open dependencies describe GitHub state, not an active agent session.
- The `publish` branch of `[progress.py:main]` requires supplied artifact proof and an external receipt destination, live validation, and a clean checkout at the proof commit. `[progress.py:check]` also requires private repository visibility when live checking is enabled; this is a code requirement, not a statement about current visibility.

## Side Effects

- `[progress.py:github]` and `[sync.py:run]` invoke authenticated `gh` read APIs. `refresh`/`sync.py:main` write local snapshots; render writes declared outputs; check regenerates into a temporary directory and can invoke a configured renderer.
- The `publish` branch of `[progress.py:main]` verifies an existing publication/readback proof and writes a receipt; it does not upload the page itself.

## Verification

From the repository root: `python3 progress/progress.py check` validates local schema, generation, resource containment, and links. `--live` additionally calls GitHub and applies the live/private checks. `python3 scripts/progress-sync.selftest.py` covers complete pagination, moving heads/bases, rejection before writes, preservation of editorial evidence, and rejection of retired projection flags. No dispatch or issue mutation is implemented here.
