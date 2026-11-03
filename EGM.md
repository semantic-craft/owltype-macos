# Owltype architectural blueprint

## System Overview

Owltype is a macOS input method with a Swift InputMethodKit/AppKit/SwiftUI shell, a Rust input engine/runtime, and a separate Rust application business core. Native adapters own platform effects; the two C ABIs carry engine actions and application decisions across the language boundary. The bundled MCP helper is a separate process communicating with the application's local Agent bridge.

These contracts document the inspected implementation. The human-maintained [Chinese README](./README.md), [English README](./README.en.md) and [contributor guide](./CONTRIBUTING.md) retain their narrative. Use the [domain map](./docs/agents/domain.md) for task routing.

## Local Interface & Invariants

- [Makefile](./Makefile) supplies dependency preparation, seed, build/test, verification and release targets. `make test` includes preparation; it is not a documentation-only checker.
- [action-install.sh](./action-install.sh) pins the Sparkle archive and verifies its digest, prepares the submodule and invokes the patched source builder. Its execution changes dependency/output directories and may download inputs.

## Subdirectories & System Boundaries

- [sources](./sources/EGM.md): native application startup, IMK host sessions, settings, panels, providers, microphone and storage adapters.
- [rust](./rust/EGM.md): input algorithms, stateful runtime, application rules/storage protocols, native ABIs, MCP client and shared contracts.
- [installer](./installer/EGM.md): standalone installer UI, atomic bundle replacement primitives and installed-session verification policy.
- [package](./package/EGM.md): package/DMG/appcast composition and explicit signing/notarization adapters.
- [scripts](./scripts/EGM.md): pinned resources, build tools, release cohorts, distribution, verification and installation diagnostics.
- [progress](./progress/EGM.md): GitHub observation snapshots and generated projections; issue assignment and execution remain outside the static page.

## Global Invariants

- Input composition and user dictionaries belong to the engine; the input runtime coordinates host actions and candidates. Application templates, provider policy and resource lifecycle belong to app-core. Swift owns native observations/effects through explicit ports and callbacks.
- Asynchronous candidates, conversations and delivery callbacks carry identity/generation checks. A rendered result, persisted preference or posted event is not proof of a completed host text change.
- Resource preparation, publication/activation and live-session refresh are distinct transitions. Immutable resources, working dictionary generations and durable user learning state have different lifetimes.
- Explicit provider, voice and Agent features have their own admission/configuration boundaries. Optional cloud candidate features can send composition context when enabled; transport APIs alone do not establish user admission.
- Build, artifact publication, installation, TIS/session verification and real-host typing are separate evidence stages. The release scripts' checks do not imply that those stages were executed during documentation bootstrap.

## Global Side Effects

Runtime entry points can write user journals/preferences/templates, operate native windows and input sources, insert host text, access clipboard/microphone/Keychain, and contact configured services. Build and distribution tools can download inputs, create artifacts, sign/notarize, upload and update publication pointers. Child contracts identify the owning entry points; this documentation change invokes none of those product operations.

## System Verification

The discovered product test entry point is `make test`; Rust packages expose scoped Cargo tests. Documentation navigation uses `python3 scripts/verify.py navigation`. Build/live/product tests were not executed for this docs-only bootstrap.

## Bootstrap Scope

The full tree was pre-approved and processed bottom-up with `EGM.md` as the target filename to preserve handwritten READMEs. Hidden/ignored build and dependency trees, symlinks, the external Sparkle submodule, test-only directories and non-code-only directories were excluded. Intermediate directories connecting implementation children were retained. Workers performed source-grounded exploration and contract readback; the four-agent concurrency limit prevented separate per-directory scout agents, so scout work ran inline within each worker. This is not a claim of an independent adversarial review.
