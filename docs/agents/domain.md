# Task navigation

Use the row matching the task; each links implementation and verification together.
Search first within `sources`, `tests`, `scripts`, and `installer`; dependency trees
are only needed when following an engine or third-party call.

## Implementation and verification

| Task | Start here | Verification |
| --- | --- | --- |
| Keystrokes, composition, language state | [Input controller](../../sources/Controller/OwlInputController.swift), [session](../../sources/Controller/OwlInputController+Session.swift), [Rust engine](../../sources/Engine/OwlRustEngine.swift) | [Rust engine tests](../../tests/OwlRustEngineTests.swift), [engine runtime tests](../../tests/EngineRuntimeTests.swift) |
| Engine start, redeploy, user-data reset, config cache and style flags, idle live-session refresh | [Engine runtime](../../sources/Controller/EngineRuntime.swift) (`start`, `redeploy`, `whileStopped`, `loadSettings`, `requestLiveSessionRefreshWhenIdle`); the [delegate](../../sources/Controller/OwlApplicationDelegate.swift) only wires it to AppKit | [Engine runtime tests](../../tests/EngineRuntimeTests.swift), [settings action tests](../../tests/OwlSettingsActionTests.swift) |
| Input habits, pinned words and onboarding | [Input habits controller](../../sources/Controller/OwlInputController+InputHabits.swift), [Rust pin rules](../../rust/crates/owl-app-core/src/user_data.rs) and [native pin preferences](../../sources/Settings/OwlPinnedWords.swift), [habit settings](../../sources/Settings/OwlInputHabitsSettings.swift) | [Input habits tests](../../tests/OwlInputHabitsTests.swift), [native integration](../../tests/OwlInputHabitsIntegrationTests.swift) |
| Floating input status bar | [Status panel](../../sources/UI/OwlInputStatusPanel.swift), [session lifecycle](../../sources/Controller/OwlInputController+Lifecycle.swift); shares candidate skin and appearance | `OwlInputStatusPanelGeometryTests`, `OwlInputStatusPanelRenderingTests`, [session integration](../../tests/OwlInputHabitsIntegrationTests.swift) |
| Candidate window or shared UI colour | [Candidate view](../../sources/UI/OwlCandidatePanelView.swift); `OwlCandidatePalette` lives in [panel state](../../sources/Candidates/OwlCandidatePanelState.swift) | [Appearance lifecycle](../../tests/OwlCandidatePanelAppearanceLifecycleTests.swift), [candidate settings](../../tests/OwlCandidatePanelSettingsTests.swift) |
| Template syntax, parameters, temporal fields and rendering | [Rust template semantics](../../rust/crates/owl-app-core/src/template.rs), [native DTO/calendar service](../../sources/Settings/OwlTemplateEngine.swift) | `OwlTemplateEngineTests`, `OwlTemplateTemporalTests`, `OwlTemplateClipboardTests`, `OwlTemplateCursorTests` through the real App ABI |
| Host capability and privacy policy | [Rust capability rules](../../rust/crates/owl-app-core/src/client_capability.rs), [native facts and DTO cache](../../sources/Engine/OwlClientCapabilityPolicy.swift); Electron bundle discovery remains native | `OwlClientCapabilityPolicyTests` through the real App ABI |
| Automatic expansion and template invocation | [Rust session state](../../rust/crates/owl-app-core/src/template_session.rs), [native recognition adapter](../../sources/Controller/OwlAutomaticExpansion.swift), [invocation UI/effects](../../sources/UI/OwlTemplateInvocation.swift); [Rust host delivery](../../rust/crates/owl-app-core/src/host_delivery.rs) owns preservation/write/cursor state; [native delivery](../../sources/UI/OwlTemplateHostDelivery.swift) collects independent IMK/AX facts and executes effects | `OwlAutomaticExpansionTests`, `OwlDynamicAutomaticTests`, `OwlTemplateDeliveryTests`, clipboard/temporal/cursor suites through real owned App sessions |
| Template library and Raycast import | [Library rules](../../rust/crates/owl-app-core/src/template_library.rs), [atomic storage transaction](../../rust/crates/owl-app-core/src/template_transaction.rs), [Raycast](../../rust/crates/owl-app-core/src/template_import.rs); [native raw services](../../sources/Engine/OwlAppCore.swift) | `OwlTemplateStoreTests`, `OwlRaycastImportTests` through the real App ABI |
| Snippet filter and settings UI | [Template page](../../sources/Settings/OwlTemplatePage.swift), [settings view](../../sources/Settings/OwlSettingsView.swift); shared palette in the row above | [Settings UI tests](../../tests/OwlSettingsUITests.swift) |
| Add or change a keyboard on/off switch | [Rust keyboard policy](../../rust/crates/owl-app-core/src/keyboard.rs) and [catalog](../../rust/crates/owl-app-core/src/keyboard_catalog.json) own metadata; [native catalog](../../sources/Settings/OwlKeyboardSettingsCatalog.swift) binds key paths and raw preferences | [Catalog parity tests](../../tests/OwlKeyboardSettingsCatalogTests.swift) |
| Apply keyboard settings | [Rust application/idle policy](../../rust/crates/owl-app-core/src/keyboard.rs) → [native effects](../../sources/Settings/OwlKeyboardSettingsApplication.swift) and [runtime](../../sources/Controller/EngineRuntime.swift) | [Settings application tests](../../tests/OwlKeyboardSettingsApplicationTests.swift) |
| Chinese/English ranking or missing candidates | [Rust session ranking](../../sources/Engine/OwlRustEngine.swift); resource generations in [dict pack resources](../../sources/DictPack/OwlRustDictPackResource.swift); [seed generation](../../scripts/owl-seed.sh) | [Mixed ranking and typo tests](../../tests/OwlRustEngineTests.swift), [dict pack tests](../../tests/OwlDictPackTests.swift) |
| Pinyin parity against pinned MSIME | [Differential runner](../../scripts/pinyin-parity.py), [baseline and replay guide](../operations/pinyin-parity.md) | `python3 scripts/pinyin-parity.selftest.py`; opt-in `OwlRustEngineTests/testExportPinyinParityTrace` |
| Bundled dictionary resources | [Catalog and direct bundled SQLite validation](../../sources/DictPack/OwlRustDictPackResource.swift), [direct resource store](../../sources/DictPack/OwlRustResourceStore.swift), [Rust catalog](../../rust/crates/owl-app-core/src/resource_catalog.rs) and [catalog data](../../rust/crates/owl-app-core/src/resource_catalog.json) | [Dict pack tests](../../tests/OwlDictPackTests.swift), [Rust engine tests](../../tests/OwlRustEngineTests.swift) |
| Rust user-data reset | [Reset transaction](../../rust/crates/owl-app-core/src/user_data.rs); native adapter retains [reset file effects](../../sources/Engine/OwlUserDictReset.swift) | [Reset tests](../../tests/OwlUserDictResetTests.swift), [candidate store tests](../../tests/CandidateStoreTests.swift) |
| AI provider, request or search | [Rust provider transactions](../../rust/crates/owl-app-core/src/provider_store.rs), [wire and errors](../../rust/crates/owl-app-core/src/provider_wire.rs), [search protocol](../../rust/crates/owl-app-core/src/provider_search.rs); native [Provider profiles](../../sources/Lane/OwlProviderProfile.swift), [provider registry](../../sources/Lane/OwlProviderRegistry.swift) (profile, key and verification as one unit), [LLM gateway](../../sources/Lane/OwlLLMGateway.swift) (polish, drafting, connectivity probe, streaming, Ask), [streaming client](../../sources/Lane/OwlStreamingChatClient.swift), [Ask search](../../sources/Lane/OwlAskSearchResolver.swift) | [Gateway request table](../../tests/OwlLLMGatewayTests.swift), [streaming and Ask request table](../../tests/OwlLLMStreamingRecordingTests.swift), [provider tests](../../tests/ProviderProfileStoreTests.swift), [registry tests](../../tests/OwlProviderRegistryTests.swift), [streaming tests](../../tests/OwlStreamingChatClientTests.swift), [search tests](../../tests/OwlAskSearchResolverTests.swift) |
| AI context, search, drafting and conversation cancellation | [Rust AI rules and sessions](../../rust/crates/owl-app-core/src/ai_business.rs), [prompt catalog](../../rust/crates/owl-app-core/src/ai_prompts.json), [native conversation projection](../../sources/Lane/OwlAIConversationModel.swift); provider writes retire active generations through a native notification; owned AI text snapshots carry large explicit inputs/results while control events stay bounded | `OwlAIContextAssemblerTests`, `OwlAIConversationModelTests`, `OwlAskAnythingModuleTests`, `OwlStructuredDraftingModuleTests`, prompt/goal/polish suites through the real App ABI |
| Verification coordinates, source links and receipt tasks | [Rust verification](../../rust/crates/owl-app-core/src/ai_verification.rs), [coordinate rules](../../rust/crates/owl-app-core/src/verification_rules.json), [native receipt effects](../../sources/UI/OwlVerificationReceiptModel.swift) | `OwlVerificationAnchorsTests`, `OwlVerificationRoutingTests`, `OwlVerificationReceiptModelTests`, `OwlSourceVerificationServiceTests` |
| Selection toolbox, rewrite confirmation, typesetting and insertion strategy | [Rust selection rules](../../rust/crates/owl-app-core/src/ai_selection.rs) and [unified host delivery](../../rust/crates/owl-app-core/src/host_delivery.rs), [native rewrite effects](../../sources/UI/OwlSelectionRewrite.swift), [unified host delivery service](../../sources/UI/OwlTemplateHostDelivery.swift) and [selection facade](../../sources/Lane/OwlTextInserter.swift) | `OwlSelectionRewriteTests`, `OwlTextInserterTests`, `OwlOptionDoubleTapDetectorTests`, `OwlChineseTypesettingTests`, `OwlSelectionPublishFormatterTests` |
| Agent access (MCP helper, bridge socket, switch) | [bridge contract](../../rust/shared/contracts/agent-bridge/README.md), [Rust protocol types](../../rust/crates/owl-agent-mcp/src/bridge.rs) and [MCP server](../../rust/crates/owl-agent-mcp/src/server.rs), [Swift protocol types](../../sources/Agent/OwlAgentBridgeProtocol.swift), [socket](../../sources/Agent/OwlAgentBridge.swift), [peer check](../../sources/Agent/OwlAgentPeerVerifier.swift), [switch and service](../../sources/Agent/OwlAgentAccess.swift), [template exposure](../../sources/Agent/OwlAgentTemplates.swift), [deliver_text](../../sources/Agent/OwlAgentDelivery.swift) and its [preview panel](../../sources/Agent/OwlAgentDeliveryPanel.swift), [call log](../../sources/Agent/OwlAgentCallLog.swift), [settings page](../../sources/Settings/OwlAgentPage.swift) | `cargo test -p owl-agent-mcp`, [contract tests](../../tests/OwlAgentBridgeContractTests.swift), [bridge and helper interop tests](../../tests/OwlAgentBridgeTests.swift), [template](../../tests/OwlAgentTemplatesTests.swift) [delivery](../../tests/OwlAgentDeliveryTests.swift) and [settings](../../tests/OwlAgentSettingsTests.swift) tests |
| Installation, update or missing input method | [Installation constraints](../operations/installation.md), [app startup](../../sources/Main.swift), [session self-check](../../installer/Shared/OwlSessionRestart.swift), [recovery prompt and self-check record](../../sources/Controller/OwlUpdateLogoutPrompt.swift) | [Activation tests](../../tests/ActivationPolicyTests.swift), [installer policy tests](../../tests/InstallerActivationPolicyTests.swift), [session self-check tests](../../tests/OwlSessionRestartTests.swift), [installed-process check](../../scripts/check-installed-process.py) |

## Build and validation

For a new checkout or worktree, follow [development setup](../../CONTRIBUTING.md#set-up-and-verify-a-change).
The [Makefile](../../Makefile) owns dependency setup and the product test command;
[local gate operations](../operations/ci.md) explains merge checks and build cleanup.
The app project is [the checked-in Xcode project](../../Owltype.xcodeproj/project.pbxproj);
only [the installer](../../installer/project.yml) uses XcodeGen.

For the tests named in the table, run
`python3 scripts/verify.py swift --test ClassName` (repeat `--test` for related
classes, or use `ClassName/methodName`). The runner selects the separate
`OwltypeUITests` scheme and preview bundle ID for `OwlSettingsUITests`.
Rust unit tests run from the
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
startup and uses isolated data, logs and preferences. Personal Keychain access is disabled. See [startup and CLI flags](../../sources/Main.swift).
A development build cannot serve as the installed input method; use the installation
workflow when actual typing must be tested.

## Research and current acceptance

- Current input behavior, pinyin/Wubi tickets and shared board: [MSIME alignment](../input-alignment.md).
- Input habits, pinning and onboarding: [design](../input-habits-design.md).
- Publishing and installation validation: [publishing checklist](../PUBLISHING_CHECKLIST.md).
- Keyboard and shortcut setting defaults against pinned Metasequoia:
  [defaults comparison](../settings-defaults-msime.md).

Research describes its recorded revision and date. Confirm current source, generated
schema and installed version before applying its conclusions; acceptance records state
which real-host behaviour was tested. Historical plans are not current command recipes.

Use the domain names in the linked implementation and records; shared terms are defined in
[GLOSSARY.md](../../GLOSSARY.md). There is no ADR directory; creating an empty one is not a
prerequisite.
