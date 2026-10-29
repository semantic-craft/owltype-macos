# Task navigation

Use the row matching the task; each links implementation and verification together.
Search first within `sources`, `tests`, `scripts`, and `installer`; dependency trees
are only needed when following an engine or third-party call.

## Implementation and verification

| Task | Start here | Verification |
| --- | --- | --- |
| Keystrokes, composition, language state | [Input controller](../../sources/Controller/OwlInputController.swift), [session](../../sources/Controller/OwlInputController+Session.swift), [Rust engine](../../sources/Engine/OwlRustEngine.swift), [engine seam](../../sources/Engine/EngineSeam.swift) | [Rust engine tests](../../tests/OwlRustEngineTests.swift), [engine seam tests](../../tests/EngineSeamTests.swift) |
| Engine start, redeploy, user-data reset, config cache and style flags, idle live-session refresh | [Engine runtime](../../sources/Controller/EngineRuntime.swift) (`start`, `redeploy`, `whileStopped`, `loadSettings`, `requestLiveSessionRefreshWhenIdle`); the [delegate](../../sources/Controller/OwlApplicationDelegate.swift) only wires it to AppKit | [Engine runtime tests](../../tests/EngineRuntimeTests.swift), [settings action tests](../../tests/OwlSettingsActionTests.swift) |
| Input habits, pinned words and onboarding | [Input habits controller](../../sources/Controller/OwlInputController+InputHabits.swift), [pin store](../../sources/Settings/OwlPinnedWords.swift), [habit settings](../../sources/Settings/OwlInputHabitsSettings.swift) | [Input habits tests](../../tests/OwlInputHabitsTests.swift), [native integration](../../tests/OwlInputHabitsIntegrationTests.swift) |
| Floating input status bar | [Status panel](../../sources/UI/OwlInputStatusPanel.swift), [session lifecycle](../../sources/Controller/OwlInputController+Lifecycle.swift); shares candidate skin and appearance | `OwlInputStatusPanelGeometryTests`, `OwlInputStatusPanelRenderingTests`, [session integration](../../tests/OwlInputHabitsIntegrationTests.swift) |
| Candidate window or shared UI colour | [Candidate view](../../sources/UI/OwlCandidatePanelView.swift); `OwlCandidatePalette` lives in [panel state](../../sources/Candidates/OwlCandidatePanelState.swift) | [Appearance lifecycle](../../tests/OwlCandidatePanelAppearanceLifecycleTests.swift), [candidate settings](../../tests/OwlCandidatePanelSettingsTests.swift) |
| Snippet filter and settings UI | [Template page](../../sources/Settings/OwlTemplatePage.swift), [settings view](../../sources/Settings/OwlSettingsView.swift); shared palette in the row above | [Settings UI tests](../../tests/OwlSettingsUITests.swift) |
| Add or change a keyboard on/off switch | One row in the [keyboard settings catalog](../../sources/Settings/OwlKeyboardSettingsCatalog.swift) (key, default, state mirror, application); the switch's mirror in [settings state](../../sources/Settings/OwlSettingsState.swift) | [Catalog parity tests](../../tests/OwlKeyboardSettingsCatalogTests.swift) |
| Apply keyboard settings | [Settings application](../../sources/Settings/OwlKeyboardSettingsApplication.swift) → `OwlManagedKeyboardPatchPlan` in [config writer](../../sources/Settings/OwlConfigWriter.swift) → [patch builder](../../sources/Settings/OwlConfigPatchBuilder.swift) | [Settings application tests](../../tests/OwlKeyboardSettingsApplicationTests.swift), [patch builder tests](../../tests/OwlKeyboardPatchBuilderTests.swift) |
| Chinese/English ranking or missing candidates | [Rust session ranking](../../sources/Engine/OwlRustEngine.swift); resource generations in [dict pack resources](../../sources/DictPack/OwlRustDictPackResource.swift); [seed generation](../../scripts/owl-seed.sh) | [Mixed ranking and typo tests](../../tests/OwlRustEngineTests.swift), [dict pack tests](../../tests/OwlDictPackTests.swift) |
| Pinyin parity against pinned MSIME | [Differential runner](../../scripts/pinyin-parity.py), [baseline and replay guide](../operations/pinyin-parity.md) | `python3 scripts/pinyin-parity.selftest.py`; opt-in `OwlRustEngineTests/testExportPinyinParityTrace` |
| Dictionary lifecycle (prepare, activate, roll back, first-run prompt) | [Center](../../sources/DictPack/OwlDictPackCenter.swift) (`status`, `prepare()`, `activate()`, `rollback()`, `needsPrompt`), [bundled package and environment](../../sources/DictPack/OwlRustDictPackResource.swift), [resource store](../../sources/DictPack/OwlRustResourceStore.swift). Only Rust state counts; legacy YAML records and files are never read. The [manifest](../../sources/DictPack/OwlDictPackManifestData.swift) only names the schemas behind the consent alert | [Dict pack tests](../../tests/OwlDictPackTests.swift), [transaction tests](../../tests/OwlRustResourceTransactionTests.swift) |
| Legacy Rime migration or Rust user-data reset | [migration plan](../../sources/UserMigration/OwlUserMigration.swift), [staging](../../sources/UserMigration/OwlUserMigrationStage.swift), [Rust import](../../sources/UserMigration/OwlUserMigrationImport.swift), [user-data reset](../../sources/Engine/OwlUserDictReset.swift) | [Migration tests](../../tests/OwlUserMigrationTests.swift), [reset tests](../../tests/OwlUserDictResetTests.swift), [candidate store tests](../../tests/CandidateStoreTests.swift) |
| AI provider, request or search | [Provider profiles](../../sources/Lane/OwlProviderProfile.swift), [provider registry](../../sources/Lane/OwlProviderRegistry.swift) (profile, key and verification as one unit), [LLM gateway](../../sources/Lane/OwlLLMGateway.swift) (polish, drafting, connectivity probe, streaming, Ask), [streaming client](../../sources/Lane/OwlStreamingChatClient.swift), [Ask search](../../sources/Lane/OwlAskSearchResolver.swift) | [Gateway request table](../../tests/OwlLLMGatewayTests.swift), [streaming and Ask request table](../../tests/OwlLLMStreamingRecordingTests.swift), [provider tests](../../tests/ProviderProfileStoreTests.swift), [registry tests](../../tests/OwlProviderRegistryTests.swift), [streaming tests](../../tests/OwlStreamingChatClientTests.swift), [search tests](../../tests/OwlAskSearchResolverTests.swift) |
| Agent access (MCP helper, bridge socket, switch) | [bridge contract](../../rust/shared/contracts/agent-bridge/README.md), [Rust protocol types](../../rust/crates/owl-agent-mcp/src/bridge.rs) and [MCP server](../../rust/crates/owl-agent-mcp/src/server.rs), [Swift protocol types](../../sources/Agent/OwlAgentBridgeProtocol.swift), [socket](../../sources/Agent/OwlAgentBridge.swift), [peer check](../../sources/Agent/OwlAgentPeerVerifier.swift), [switch and service](../../sources/Agent/OwlAgentAccess.swift) | `cargo test -p owl-agent-mcp`, [contract tests](../../tests/OwlAgentBridgeContractTests.swift), [bridge and helper interop tests](../../tests/OwlAgentBridgeTests.swift) |
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

For a settings-only preview, the app's `--ui-test-show-settings` mode avoids IMK/engine
startup and uses isolated preferences. See [startup and CLI flags](../../sources/Main.swift).
A development build cannot serve as the installed input method; use the installation
workflow when actual typing must be tested.

## Research and current acceptance

- Current input behavior, pinyin/Wubi tickets and shared board: [MSIME alignment](../input-alignment.md).
- Input habits, pinning, onboarding and installed-host evidence:
  [design and acceptance record](../input-habits-design.md).
- MiniMax endpoints, reasoning and subscription search:
  [integration research](../minimax-integration-research-2026-10-01.md).
- Publishing and installation validation: [publishing checklist](../PUBLISHING_CHECKLIST.md).
- Keyboard and shortcut setting defaults against pinned Metasequoia:
  [defaults comparison](../settings-defaults-msime.md).

Research describes its recorded revision and date. Confirm current source, generated
schema and installed version before applying its conclusions; acceptance records state
which real-host behaviour was tested. Historical plans are not current command recipes.

Use the domain names in the linked implementation and records; shared terms are defined in
[GLOSSARY.md](../../GLOSSARY.md). There is no ADR directory; creating an empty one is not a
prerequisite.
