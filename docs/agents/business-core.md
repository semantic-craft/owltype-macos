# App business boundary

The fixed Metasequoia crates own ordinary input semantics. `owl-app-core` owns
Owltype business rules; `owl-app-ffi` exposes them to the native application.
Swift owns UI, macOS fact capture and system-effect execution. A class called
ViewModel or Adapter is not exempt from this boundary.

[Ownership inventory](business-ownership.json) assigns every production Swift file
a final owner or a migration issue. It is an architecture map, not a progress ledger:
GitHub goal #356 and its native dependencies own current implementation/acceptance
state. `scripts/check-business-boundary.py` checks coverage, not semantic purity.
Split entries retain only their native parts as the corresponding ticket is delivered.

## ABI contract

- Version 1 requests are bounded UTF-8 JSON; input is borrowed for the synchronous
  call only. A returned NUL-terminated JSON buffer is Rust-owned and must be freed
  once with `owl_app_string_free`. A null free is permitted. Never free Swift bytes
  through Rust, pass an interior pointer or retain a borrowed request.
- Responses are `{ok:true,value:...}` or `{ok:false,error:...}`. Errors contain stable
  codes and no request content. Unsupported ABI versions fail before reading input.
  Panics are contained at the ABI; invalid pointers still violate the C contract.
- The initial dispatcher is stateless and concurrent-call safe; it does no I/O and
  invokes no host callbacks. Per-application initial ASCII policy is the first
  production consumer, through `OwlAppCore`. Ordinary per-key input is unchanged.
- Future stateful modules must expose opaque owned handles with explicit destruction
  and serialized per-handle access. No global mutable business singleton in Swift.
  Rust owns request IDs, template revisions and generations; host facts carry their
  capture generation. A native effect is rechecked against the current bound target
  immediately before execution, then returns a typed outcome to Rust.
- Future asynchronous effects use command/event exchange; no synchronous callback
  into AppKit from a Rust worker and no UI wait for disk, network or AX. Cancellation
  invalidates the request generation; late events cannot mutate a new invocation.
- Host ranges are UTF-16 code-unit offsets. Rust text indices are UTF-8 bytes.
  `utf16_range` rejects overflow, out-of-bounds indices and split surrogates. Neither
  coordinate system implies grapheme boundaries; callers must state which they need.
- Keychain, URLSession transport, IMK/AX and native locale/calendar formatting remain
  host services. Provider protocol, retry/route choice, template syntax, data
  transactions and cancellation decisions belong to Rust.

## Keyboard configuration

[`keyboard.rs`](../../rust/crates/owl-app-core/src/keyboard.rs) owns the settings catalog,
legacy raw-value normalization, schema mapping, custom shuangpin tables, fuzzy bit order,
selection/application plans and idle eligibility. Native controls keep their existing
keys and value formats. The Swift adapter decodes the immutable catalog once and caches
normalized multi-value and fuzzy projections until their raw inputs change. The existing
per-session last-applied option slots remain native transport caches.

`owl_app_keyboard_refresh` and `owl_app_keyboard_can_apply` are allocation-free ABI 1
scalar calls for input boundaries: 0/1 Boolean inputs; refresh returns 0 (none), 1 (defer)
or 2 (apply), and can-apply returns 0/1. They perform no I/O or callbacks. Ordinary input
never JSON-decodes the complete catalog per key. Options that rebuild an engine wait
until its composition is idle; settings-triggered native session replacement also waits
for all live compositions, preserving selected phrase progress that raw-input replay loses.
Safe live options retain their current application behavior.

[`keyboard_export.rs`](../../rust/crates/owl-app-core/src/keyboard_export.rs) owns the
retained YAML preview/export strings, complete file plan and managed-block rendering.
This does not reintroduce YAML into normal settings activation. Shared write/backup/rollback
transactions remain assigned to storage migration, and input commit transforms remain
assigned to lifecycle/input closeout; their inventory rows identify the remaining owner.

## Behavior and data baselines

Use existing synthetic fixtures and the real Swift/FFI seam; do not copy personal data.

| Domain | Existing regression entry | Preserved contract |
| --- | --- | --- |
| Input/configuration | `tests/OwlRustEngineTests.swift`, `tests/OwlKeyboardSettingsCatalogTests.swift`, parity fixture baseline | Effective settings, candidate identity/order, composition preserved across live preference changes |
| Templates | `tests/OwlTemplateEngineTests.swift`, `tests/OwlTemplateClipboardTests.swift`, `tests/OwlTemplateCursorTests.swift` | Standard/legacy grammar, frozen context, UTF-16 diagnostics, no recursive expansion |
| Template storage | `sources/Settings/OwlTemplateStore.swift`, `sources/Settings/OwlTemplateBackup.swift`, `sources/Settings/OwlTemplateMigration.swift` and their tests | Existing Codable keys, IDs, paths, backup/restore versions, pending recovery and rollback |
| Automatic expansion | `tests/OwlDynamicAutomaticTests.swift` and automatic-expansion suites | Prefix conflict rules, delimiter keep/drop, Esc/interrupt restoration, no per-key parsing |
| AI | `tests/OwlLLMGatewayTests.swift`, `tests/OwlLLMStreamingRecordingTests.swift`, `tests/OwlAIConversationModelTests.swift` | Provider payloads, stream splitting, history, cancellation, explicit-action privacy |
| Resources | `tests/OwlRustResourceTransactionTests.swift`, `tests/OwlUserMigrationTests.swift` | Generation format/activation/rollback, journal replay, original snapshot and pinsExternalOnly |
| Agent/host | `tests/OwlAgentDeliveryTests.swift`, `tests/OwlAgentBridgeContractTests.swift` | Wire compatibility, one write, replay, cancellation, secure-input refusal |

Inspect the owning implementation before each migration for exact serialized versions
and keys. Keep the existing format during the implementation switch; a format change
needs its own recovery design and acceptance. Chrome cursor/automatic-expansion evidence
remains in #331; migration does not waive the current Chromium range restrictions.

The build produces both static archives for native tests and universal distribution.
The delivery checker requires the App ABI call/free symbols in the shipped binary.
The full gate tests both App crates and checks ownership coverage. Unit, Swift-host,
installed-host and published-artifact evidence remain separate.
