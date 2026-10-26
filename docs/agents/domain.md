# Task navigation

Use the row matching the task; each links implementation and verification together.
Search first within `sources`, `tests`, `scripts`, and `installer`; dependency trees
are only needed when following an engine or third-party call.

## Implementation and verification

| Task | Start here | Verification |
| --- | --- | --- |
| Keystrokes, composition, language state | [Input controller](../../sources/Controller/OwlInputController.swift), [session](../../sources/Controller/OwlInputController+Session.swift), [Rust engine](../../sources/Engine/OwlRustEngine.swift), [engine seam](../../sources/Engine/RimeSeam.swift) | [Rust engine tests](../../tests/OwlRustEngineTests.swift), [Rime seam tests](../../tests/RimeSeamTests.swift) |
| Input habits, pinned words and onboarding | [Input habits controller](../../sources/Controller/OwlInputController+InputHabits.swift), [pin store](../../sources/Settings/OwlPinnedWords.swift), [habit settings](../../sources/Settings/OwlInputHabitsSettings.swift) | [Input habits tests](../../tests/OwlInputHabitsTests.swift), [native integration](../../tests/OwlInputHabitsIntegrationTests.swift) |
| Floating input status bar | [Status panel](../../sources/UI/OwlInputStatusPanel.swift), [session lifecycle](../../sources/Controller/OwlInputController+Lifecycle.swift); shares candidate skin and appearance | `OwlInputStatusPanelGeometryTests`, `OwlInputStatusPanelRenderingTests`, [session integration](../../tests/OwlInputHabitsIntegrationTests.swift) |
| Candidate window or shared UI colour | [Candidate view](../../sources/UI/OwlCandidatePanelView.swift); `OwlCandidatePalette` lives in [panel state](../../sources/Candidates/OwlCandidatePanelState.swift) | [Appearance lifecycle](../../tests/OwlCandidatePanelAppearanceLifecycleTests.swift), [candidate settings](../../tests/OwlCandidatePanelSettingsTests.swift) |
| Snippet filter and settings UI | [Template page](../../sources/Settings/OwlTemplatePage.swift), [settings view](../../sources/Settings/OwlSettingsView.swift); shared palette in the row above | [Settings UI tests](../../tests/OwlSettingsUITests.swift) |
| Apply keyboard settings | [Settings application](../../sources/Settings/OwlKeyboardSettingsApplication.swift) → `OwlManagedKeyboardPatchPlan` in [config writer](../../sources/Settings/OwlConfigWriter.swift) → [patch builder](../../sources/Settings/OwlRimePatchBuilder.swift) | [Settings application tests](../../tests/OwlKeyboardSettingsApplicationTests.swift), [patch builder tests](../../tests/OwlKeyboardPatchBuilderTests.swift) |
| Chinese/English ranking or missing candidates | [Rust session ranking](../../sources/Engine/OwlRustEngine.swift); resource switching in [dict pack](../../sources/DictPack/OwlDictPack.swift); [seed generation](../../scripts/owl-seed.sh) | [Mixed ranking and typo tests](../../tests/OwlRustEngineTests.swift), [dict pack tests](../../tests/OwlDictPackTests.swift) |
| Pinyin parity against pinned MSIME | [Differential runner](../../scripts/pinyin-parity.py), [baseline and replay guide](../operations/pinyin-parity.md) | `python3 scripts/pinyin-parity.selftest.py`; opt-in `OwlRustEngineTests/testExportPinyinParityTrace` |
| Dictionary download and activation | [Fetcher](../../sources/DictPack/OwlDictPackFetcher.swift), [center](../../sources/DictPack/OwlDictPackCenter.swift), [manifest](../../sources/DictPack/OwlDictPackManifestData.swift) | [Dict pack tests](../../tests/OwlDictPackTests.swift) |
| Legacy Rime migration or Rust user-data reset | [migration plan](../../sources/UserMigration/OwlUserMigration.swift), [staging](../../sources/UserMigration/OwlUserMigrationStage.swift), [Rust import](../../sources/UserMigration/OwlUserMigrationImport.swift), [user-data reset](../../sources/Engine/OwlUserDictReset.swift) | [Migration tests](../../tests/OwlUserMigrationTests.swift), [reset tests](../../tests/OwlUserDictResetTests.swift), [candidate store tests](../../tests/CandidateStoreTests.swift) |
| AI provider, request or search | [Provider profiles](../../sources/Lane/OwlProviderProfile.swift), [streaming client](../../sources/Lane/OwlStreamingChatClient.swift), [Ask search](../../sources/Lane/OwlAskSearchResolver.swift) | [Provider tests](../../tests/ProviderProfileStoreTests.swift), [streaming tests](../../tests/OwlStreamingChatClientTests.swift), [search tests](../../tests/OwlAskSearchResolverTests.swift) |
| Installation, update or missing input method | [Installation constraints](../operations/installation.md), [app startup](../../sources/Main.swift), [session self-check](../../installer/Shared/OwlSessionRestart.swift), [recovery prompt and self-check record](../../sources/Controller/OwlUpdateLogoutPrompt.swift) | [Activation tests](../../tests/ActivationPolicyTests.swift), [installer policy tests](../../tests/InstallerActivationPolicyTests.swift), [session self-check tests](../../tests/OwlSessionRestartTests.swift), [installed-process check](../../scripts/check-installed-process.py) |

## Build and validation

For a new checkout or worktree, follow [development setup](../../CONTRIBUTING.md#set-up-and-verify-a-change).
The [Makefile](../../Makefile) owns dependency setup and the product test command;
[local gate operations](../operations/ci.md) explains merge checks and build cleanup.
The app project is [the checked-in Xcode project](../../Owltype.xcodeproj/project.pbxproj);
only [the installer](../../installer/project.yml) uses XcodeGen.

For the tests named in the table, run
`python3 scripts/verify.py swift --test ClassName` (repeat `--test` for related
classes, or use `ClassName/methodName`). Rust unit tests run from the
[Rust workspace](../../rust/Cargo.toml) with `cargo test -p <crate>`. Use
`navigation` for reference edits, `workflow` for verification-runner changes and
`distribution` for publishing orchestration. See
[focused checks and evidence](../operations/ci.md#focused-feedback-and-retained-evidence)
for setup, coverage limits and durable local receipts. Full merge validation remains
[the local gate](../../scripts/gate.sh).

The former Rime build, sync, keyboard-patch and consistency-diagnosis CLI commands are
retired. The app binary rejects them with exit status 64; do not add scripts or tests that
invoke them. The Rust resource seed is prepared by [the Make target](../../Makefile) and
verified through the Rust and dict-pack tests above.

For a settings-only preview, the app's `--ui-test-show-settings` mode avoids IMK/Rime
startup and uses isolated preferences. See [startup and CLI flags](../../sources/Main.swift).
A development build cannot serve as the installed input method; use the installation
workflow when actual typing must be tested.

## Research and current acceptance

- Chinese/English channels and ranking: [AIME research](../aime-input-method-research-2026-10-02.md)
  and [Pinyin comparison](../aime-pinyin-comparison-2026-10-02.md).
- Mixed-English placement rule borrowed from Metasequoia IME:
  [comparison and decision](../metasequoia-mixed-english-2026-10-20.md).
- Input habits, pinning, onboarding and installed-host evidence:
  [design and acceptance record](../input-habits-design.md).
- MiniMax endpoints, reasoning and subscription search:
  [integration research](../minimax-integration-research-2026-10-01.md).
- Publishing and installation validation: [publishing checklist](../PUBLISHING_CHECKLIST.md).

Research describes its recorded revision and date. Confirm current source, generated
schema and installed version before applying its conclusions; acceptance records state
which real-host behaviour was tested. Historical plans are not current command recipes.

Use the domain names in the linked implementation and records. There is currently no
standalone glossary or ADR directory; creating empty placeholders is not a prerequisite.
