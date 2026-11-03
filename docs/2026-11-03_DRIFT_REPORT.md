<!--
EGM drift review, 2026-11-03. Static source/document comparison after full-tree bootstrap.
Scope: the 74 generated EGM contracts, existing root READMEs/contributor guide,
all Markdown under docs, the two retained subsystem READMEs, and related source contract/copy findings.
Original inspection HEAD: 908fc6d45ec84ab5a04c7e94a8e2f56444bffb02.
Final base reconciliation: origin/main at f0c1ef5facc959f2d5e7c7d7a37aeee64291b308.
The four feature-branch-only file changes were excluded; the UI contract and Kotone
operations document were checked against the default-branch implementation.
No drift detected means no difference found within the inspected static contract;
it is not execution, installed-host, provider, release, legal-provenance or acceptance evidence.
Test-only/ignored/third-party trees and bulk data were excluded; large config reads follow
bootstrap limits. Existing narrative/source copy is preserved; findings are not fixes.
The generated-contract sections below also form the exact bootstrap artifact inventory.
-->

## README.md

- The current-source version block still says 2.0.12 (line 136), while [Owltype.xcodeproj/project.pbxproj](../Owltype.xcodeproj/project.pbxproj) declares marketing/build version 2.4.0. Update the current-version block separately from the explicitly historical 2.0.12 screenshots and release notes.
- The resource description (line 71 and the public-source/seed paragraph) says the app ships a restricted seed and obtains full dictionaries on first run. [Makefile:copy-owl-seed](../Makefile) bundles the pinned SQLite resources, [scripts/owl-seed.sh](../scripts/owl-seed.sh) assembles the official resource set, and [OwlDictPackCenterRustBackend.production](../sources/DictPack/OwlDictPackCenter.swift) calls prepareBundled. [resource_catalog.rs:build](../rust/crates/owl-app-core/src/resource_catalog.rs) copies those bundled resources. The no-redistribution/8105-character description does not describe this build path; reconcile it with the actual resource inventory and provenance before reusing that statement.
- The settings paragraph (line 102) advertises a sync-directory control. That old Rime control has been retired: [Main.swift:retiredCLIArguments](../sources/Main.swift) rejects --sync, and [EngineRuntime.migrateLegacyUserData](../sources/Controller/EngineRuntime.swift) uses the old sync path only for snapshot import. [input-habits-design.md](input-habits-design.md) already documents retirement; remove the current-feature claim.
- The introduction and installation/recovery steps prescribe logout after every installation. [OwlSessionRestart.run](../installer/Shared/OwlSessionRestart.swift) instead finishes installation in the current user session, and [OwlUpdateLogoutPrompt.runIfNeeded](../sources/Controller/OwlUpdateLogoutPrompt.swift) arms recovery guidance only after a failed self-check and recheck. Distinguish normal installation from failed-session recovery rather than requiring unconditional logout.
- The local-typing/explicit-cloud-invocation description omits the optional automatic candidate path. [OwlAICandidatePreferences](../sources/Lane/OwlAICandidatePreferences.swift) defaults all three candidate features off, but once enabled [armAICandidateAfterInput/aiCandidateDebounceFired](../sources/Controller/OwlInputController+Session.swift) schedules requests after 0.12 seconds and can supply input/context/local candidates to [OwlAICandidateService](../sources/Lane/OwlAICandidateService.swift). Document this opt-in exception to the per-action invocation description.

## README.en.md

- The current-source version block still says 2.0.12 (line 136), while [Owltype.xcodeproj/project.pbxproj](../Owltype.xcodeproj/project.pbxproj) declares marketing/build version 2.4.0. Update the current-version block separately from the explicitly historical 2.0.12 screenshots and release notes.
- The resource description (line 71 and the public-source/seed paragraph) says the app ships a restricted seed and obtains full dictionaries on first run. [Makefile:copy-owl-seed](../Makefile) bundles the pinned SQLite resources, [scripts/owl-seed.sh](../scripts/owl-seed.sh) assembles the official resource set, and [OwlDictPackCenterRustBackend.production](../sources/DictPack/OwlDictPackCenter.swift) calls prepareBundled. [resource_catalog.rs:build](../rust/crates/owl-app-core/src/resource_catalog.rs) copies those bundled resources. The no-redistribution/8105-character description does not describe this build path; reconcile it with the actual resource inventory and provenance before reusing that statement.
- The settings paragraph (line 102) advertises a sync-directory control. That old Rime control has been retired: [Main.swift:retiredCLIArguments](../sources/Main.swift) rejects --sync, and [EngineRuntime.migrateLegacyUserData](../sources/Controller/EngineRuntime.swift) uses the old sync path only for snapshot import. [input-habits-design.md](input-habits-design.md) already documents retirement; remove the current-feature claim.
- The introduction and installation/recovery steps prescribe logout after every installation. [OwlSessionRestart.run](../installer/Shared/OwlSessionRestart.swift) instead finishes installation in the current user session, and [OwlUpdateLogoutPrompt.runIfNeeded](../sources/Controller/OwlUpdateLogoutPrompt.swift) arms recovery guidance only after a failed self-check and recheck. Distinguish normal installation from failed-session recovery rather than requiring unconditional logout.
- The local-typing/explicit-cloud-invocation description omits the optional automatic candidate path. [OwlAICandidatePreferences](../sources/Lane/OwlAICandidatePreferences.swift) defaults all three candidate features off, but once enabled [armAICandidateAfterInput/aiCandidateDebounceFired](../sources/Controller/OwlInputController+Session.swift) schedules requests after 0.12 seconds and can supply input/context/local candidates to [OwlAICandidateService](../sources/Lane/OwlAICandidateService.swift). Document this opt-in exception to the per-action invocation description.

## CONTRIBUTING.md

- Lines 35–36 distinguish prebuilt make bootstrap dependencies from source-built make deps. [action-install.sh](../action-install.sh) invokes [scripts/build-sparkle.py:main](../scripts/build-sparkle.py), as does Makefile sparkle; that builder prepares patched pinned source or reuses its matching framework receipt. Describe this shared source-build/reuse path instead of promising a prebuilt-only bootstrap.

## docs/PUBLISHING_CHECKLIST.md

- The interrupted-publication section says latest.json is made public before the feed and describes failure between those separate pointer writes. [scripts/owl_distribution.py:publish](../scripts/owl_distribution.py) stages both site files through GitHubDownloadsStore.put and calls store.commit once; binary release uploads precede that site push. This also contradicts the earlier one-push paragraph in this same document. Describe asset upload, site commit/deployment, and public readback failure separately; a shared push does not imply simultaneous cache visibility.
- The recovery link targets operations/installation.md#installed-acceptance-and-recovery-record, but the actual heading is Acceptance and recovery ([current target](operations/installation.md#acceptance-and-recovery)). Correct the fragment.

## docs/agents/business-core.md

- The ABI section still describes the dispatcher as doing no I/O. The current [owl_app_call dispatch](../rust/crates/owl-app-ffi/src/lib.rs) admits Request::ResourceContract, and [resource_contract.rs:configuration/verify_file/verify_generation](../rust/crates/owl-app-core/src/resource_contract.rs) create directories or read files/SQLite directly. Mark the initial I/O-free description as historical or scope it to the actual pure operations; no native callback does not mean no I/O.

## docs/agents/domain.md

No drift detected.

## docs/agents/issue-tracker.md

No drift detected.

## docs/agents/triage-labels.md

No drift detected.

## docs/input-alignment.md

No drift detected.

## docs/input-habits-design.md

No drift detected.

## docs/operations/ci.md

No drift detected.

## docs/operations/installation.md

No drift detected.

## docs/operations/jev-replies.md

No drift detected.

## docs/operations/msime-repin.md

No drift detected.

## docs/operations/pinyin-parity.md

No drift detected.

## docs/owltype-responses-prompt-evaluation.md

- The opening product-model policy forbids any built-in/default/recommended Flash model and sets qwen3.7-plus as the baseline. [provider_catalog.json](../rust/crates/owl-app-core/src/provider_catalog.json) now supplies qwen3.8-flash, deepseek-flash, MiniMax-M3.1-Flash and gemini-3.8-flash presets. Reconcile the current evaluation matrix with this catalog; dated historical evaluation records should remain historical. No live provider call was made in this review.

## docs/settings-defaults-msime.md

- The full-dictionary row (line 26) says dictionaries are not bundled and are downloaded after consent. The production backend calls [OwlRustResourceStore.prepareBundled](../sources/DictPack/OwlRustResourceStore.swift) via [OwlDictPackCenterRustBackend.production](../sources/DictPack/OwlDictPackCenter.swift); align the distribution row with bundled preparation while retaining the distinct activation/idle-refresh step.
- Intentional difference 2 says templates/snippets/prompts appear only through K plus a trigger. [OwlTemplateEntry.InvocationMode](../sources/Settings/OwlTemplateStore.swift) also supports search-only and automatic modes; [OwlTemplateEditorModel.setAutomaticEnabled](../sources/Settings/OwlTemplatePage.swift) and [automatic-expansion controller paths](../sources/Controller/OwlInputController+AutomaticExpansion.swift) expose/execute automatic triggers. Limit the K statement to candidate-confirmation mode.

## patches/sparkle/README.md

No drift detected.

## rust/shared/contracts/agent-bridge/README.md

No drift detected.

## rust/crates/owl-app-ffi/include/owl_app_ffi.h

- The owl_app_keyboard_can_apply comment says 0 none / 1 defer / 2 apply. [lib.rs:owl_app_keyboard_can_apply](../rust/crates/owl-app-ffi/src/lib.rs) returns u8::from(bool), hence only 0/1. The three-way mapping belongs to owl_app_keyboard_refresh; correct the declaration comment without changing the ABI.
- The blanket payload bound and session-event comment do not match [lib.rs](../rust/crates/owl-app-ffi/src/lib.rs): owl_app_call caps at 32 MiB, storage/session creation use the pointer-size bound, Runtime events use that bound, Invocation events cap at 4 MiB, and other session events cap at 32 MiB. Document limits per entry point/session kind.
- The owl_app_call I/O-free comment conflicts with its reachable ResourceContract dispatch into [resource_contract.rs](../rust/crates/owl-app-core/src/resource_contract.rs), including directory creation and file/SQLite checks. The generated implementation contract records these effects; the header remains unchanged in this docs-only wave.

## sources/Settings/OwlKeyboardPage.swift

- The visible full-dictionary card describes an approximately 90 MB download and says full dictionaries are not distributed with the installer. Its prepare action reaches [OwlDictPackCenterRustBackend.production](../sources/DictPack/OwlDictPackCenter.swift), which prepares bundled resources. Reconcile the UI copy with that path in a separately reviewed product change.

## sources/Settings/OwlOnboardingView.swift

- The dictionary explanation and consent copy describe an upstream network download before subsequent onboarding steps. Production preparation is [prepareBundled](../sources/DictPack/OwlDictPackCenter.swift), not that described transport. The same mismatch appears in the settings card; update them together when product copy is authorized.

## sources/Settings/OwlSkillsPage.swift

- The cloud card says primary candidates always come from local Rime and never go to the cloud. The current engine is Rust and [aiCandidateDebounceFired](../sources/Controller/OwlInputController+Session.swift) reaches opt-in cloud candidate generation/reranking. Explain the default-off feature gates and the composition/context sent after enabling them.

## EGM.md

No drift detected.

## installer/EGM.md

No drift detected.

## installer/Shared/EGM.md

No drift detected.

## installer/Sources/EGM.md

No drift detected.

## package/EGM.md

No drift detected.

## progress/EGM.md

No drift detected.

## rust/EGM.md

No drift detected.

## rust/crates/EGM.md

No drift detected.

## rust/crates/chinese-ime-lm/EGM.md

No drift detected.

## rust/crates/chinese-ime-lm/src/EGM.md

No drift detected.

## rust/crates/client-core/EGM.md

No drift detected.

## rust/crates/client-core/src/EGM.md

No drift detected.

## rust/crates/client-core/src/cloud/EGM.md

No drift detected.

## rust/crates/client-core/src/cloud/candidates/EGM.md

No drift detected.

## rust/crates/engine/EGM.md

No drift detected.

## rust/crates/engine/examples/EGM.md

No drift detected.

## rust/crates/engine/src/EGM.md

No drift detected.

## rust/crates/engine/src/backend/EGM.md

No drift detected.

## rust/crates/engine/src/cantonese/EGM.md

No drift detected.

## rust/crates/engine/src/dictionary/EGM.md

No drift detected.

## rust/crates/engine/src/dictionary/english/EGM.md

No drift detected.

## rust/crates/engine/src/handwriting/EGM.md

No drift detected.

## rust/crates/engine/src/host/EGM.md

No drift detected.

## rust/crates/engine/src/ime/EGM.md

No drift detected.

## rust/crates/engine/src/japanese/EGM.md

No drift detected.

## rust/crates/engine/src/korean/EGM.md

No drift detected.

## rust/crates/engine/src/lattice/EGM.md

No drift detected.

## rust/crates/engine/src/local/EGM.md

No drift detected.

## rust/crates/engine/src/multilingual/EGM.md

No drift detected.

## rust/crates/engine/src/pinyin/EGM.md

No drift detected.

## rust/crates/engine/src/quanpin/EGM.md

No drift detected.

## rust/crates/engine/src/quanpin/dictionary/EGM.md

No drift detected.

## rust/crates/engine/src/session/EGM.md

No drift detected.

## rust/crates/engine/src/shuangpin/EGM.md

No drift detected.

## rust/crates/engine/src/stroke/EGM.md

No drift detected.

## rust/crates/engine/src/tibetan/EGM.md

No drift detected.

## rust/crates/engine/src/user_dictionary/EGM.md

No drift detected.

## rust/crates/engine/src/vietnamese/EGM.md

No drift detected.

## rust/crates/engine/src/wubi/EGM.md

No drift detected.

## rust/crates/engine/src/zhuyin/EGM.md

No drift detected.

## rust/crates/input-runtime/EGM.md

No drift detected.

## rust/crates/input-runtime/src/EGM.md

No drift detected.

## rust/crates/owl-agent-mcp/EGM.md

No drift detected.

## rust/crates/owl-agent-mcp/src/EGM.md

No drift detected.

## rust/crates/owl-app-core/EGM.md

No drift detected.

## rust/crates/owl-app-core/src/EGM.md

No drift detected.

## rust/crates/owl-app-core/src/pure_rules/EGM.md

No drift detected.

## rust/crates/owl-app-ffi/EGM.md

No drift detected.

## rust/crates/owl-app-ffi/include/EGM.md

No drift detected.

## rust/crates/owl-app-ffi/src/EGM.md

No drift detected.

## rust/crates/owl-msime-ffi/EGM.md

No drift detected.

## rust/crates/owl-msime-ffi/include/EGM.md

No drift detected.

## rust/crates/owl-msime-ffi/src/EGM.md

No drift detected.

## rust/crates/path-trust/EGM.md

No drift detected.

## rust/crates/path-trust/src/EGM.md

No drift detected.

## rust/scripts/EGM.md

No drift detected.

## rust/shared/EGM.md

No drift detected.

## rust/shared/contracts/EGM.md

No drift detected.

## rust/shared/contracts/punctuation/EGM.md

No drift detected.

## scripts/EGM.md

No drift detected.

## sources/Activation/EGM.md

No drift detected.

## sources/Agent/EGM.md

No drift detected.

## sources/Candidates/EGM.md

No drift detected.

## sources/Controller/EGM.md

No drift detected.

## sources/Data/EGM.md

No drift detected.

## sources/DictPack/EGM.md

No drift detected.

## sources/EGM.md

No drift detected.

## sources/Engine/EGM.md

No drift detected.

## sources/Lane/EGM.md

No drift detected.

## sources/Settings/EGM.md

No drift detected.

## sources/Theme/EGM.md

No drift detected.

## sources/UI/EGM.md

No drift detected.

## sources/UserMigration/EGM.md

No drift detected.

## sources/Voice/EGM.md

No drift detected.
