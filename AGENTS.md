# Agent instructions

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.
For project housekeeping or closeout, follow its [issue reconciliation steps](docs/agents/issue-tracker.md#project-housekeeping-and-closeout).

### Triage labels

Use the five canonical triage roles and their default label names. See `docs/agents/triage-labels.md`.

### Domain docs

For input, settings, dictionaries, AI, installation, or verification work, start with the task-to-code map in [domain.md](docs/agents/domain.md).

## Verification lessons

Before changing acceptance scripts or interpreting live evidence, read [LESSONS.md](LESSONS.md).
Record observed acceptance failures there with their regression and scope.

## Settings and panel regressions

| Rule | Enforcement |
| --- | --- |
| Use `.owlPlain` for plain controls in Settings, UI, Voice, and Agent. Size a row inside its button label. | [SwiftLint](.swiftlint.yml) rejects raw plain styles. [Settings UI tests](tests/OwlSettingsUITests.swift) click the blank part of rows. |
| Page data can arrive while an editor is active. Keep the load off the main thread and publish the library separately from the draft. | [Settings action tests](tests/OwlSettingsActionTests.swift) hold a library read open while editing the draft. |
| Candidate, status, voice, and delivery panels must leave the host key window alone. | [OwlFloatingPanel](sources/UI/OwlFloatingPanel.swift) owns the nonactivating policy. [AppKit lifecycle tests](tests/OwlCandidatePanelAppearanceLifecycleTests.swift) check each concrete panel. |
| Validate Rust symbols in the launched executable. | [Rust delivery check](scripts/check-rust-delivery.py) requires the main binary at its launch path. |
