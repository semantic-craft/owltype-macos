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
selection/application plans, onboarding mappings, schema failure/backoff and idle eligibility. Native controls keep their existing
keys and value formats. The Swift adapter decodes the immutable catalog once and caches
normalized multi-value and fuzzy projections until their raw inputs change. The existing
per-session last-applied option slots remain native transport caches.

`owl_app_keyboard_refresh` and `owl_app_keyboard_can_apply` are allocation-free ABI 1
scalar calls for input boundaries: 0/1 Boolean inputs; refresh returns 0 (none), 1 (defer)
or 2 (apply), and can-apply returns 0/1. They perform no I/O or callbacks. Ordinary input
never JSON-decodes the complete catalog per key. Options that rebuild an engine wait
until its composition is idle; settings-triggered native session replacement also waits
for all live compositions, preserving selected phrase progress that raw-input replay loses.
Safe live options retain their current application behavior. Settings and onboarding schema
selection use `selectSettingsSchema`, which queues the native effect at this same idle boundary.
The separate `selectSchema` effect interface remains immediate for explicit host/menu operations;
this is not a claim that every schema switch is deferred. The per-key schema backoff decision
uses `owl_app_keyboard_schema_idle_action` (0 already active, 1 attempt, 2 known failure).

[`keyboard_export.rs`](../../rust/crates/owl-app-core/src/keyboard_export.rs) owns the
retained YAML preview/export strings, complete file plan and managed-block rendering.
This does not reintroduce YAML into normal settings activation. Shared write/backup/rollback
transactions live in `config_writer` and the template storage modules below. Input commit
transforms remain assigned to lifecycle/input closeout.

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

## Template semantics

[`template.rs`](../../rust/crates/owl-app-core/src/template.rs) owns both grammars,
UTF-16 token/diagnostic ranges, parameter identity/defaults/options, context requirements,
initial values, nonrecursive expansion, clipboard decisions, cursor grapheme boundaries
and final readiness. `OwlTemplateEngine` retains the existing App interface as Codable DTOs.
User-authored requests rejected by the bounded ABI become blocking template diagnostics,
not `required()` preconditions. Readiness exchanges only compact diagnostic/decision facts,
so repeated parameters can produce output larger than the request limit. No template body
or parameter value is logged.

Temporal rendering uses the invocation's frozen Foundation calendar, locale, zone and
resolved default patterns. Rust parses TR35 patterns and offset syntax, validates the
calendar range and arithmetic direction, requests numeric week-field facts, and builds
the final pattern. Swift executes Calendar additions, VerbatimFormatStyle requests and
DateFormatter formatting only. It does not rescan pattern syntax. Non-Gregorian calendars,
DST arithmetic, custom first-weekday/minimum-days rules and native hour-cycle preferences
therefore retain their existing Foundation semantics. Library storage and invocation state are described below.

## Template storage

`owl_app_storage_call` is the synchronous storage ABI alongside the bounded pure dispatcher.
It borrows requests and native service context for one calling-thread operation. Rust invokes
one explicit native primitive at a time (read, atomic write/rename, permissions, lock, UUID,
collation fact or commit notification); it owns the complete operation, journal phases and
error recovery. Native effect errors use opaque per-call tokens so the original Swift Error
can cross back without serializing it. Domain validation still returns user-facing messages.
No callback/context is retained or sent to a worker thread. These storage operations preserve
the existing callers' scheduling; ordinary keys do not invoke filesystem effects.

`template_library`, `template_editor`, `picker`, `template_import`, `template_backup`,
`prompt_store` and `quick_send` own their models and decisions. UI projections remain Codable
DTOs. Foundation supplies title ranks, case comparison and localized substring facts; Rust
chooses pin priority, deduplication representatives and ordering. `foundation_text` preserves
Foundation whitespaces/newlines (including U+200B) without normalizing authored content.
The automatic trie and conflict validation are built once by Rust; per-key recognition
remains the #361 boundary and consumes immutable native-decoded nodes.

`template_transaction` serializes public mode/load/current reads with the process lock,
without creating files. Writes also hold the original nonblocking per-directory flock.
The native call tracks acquired canonical keys and both recursive lock depths and releases
unbalanced acquisitions after an ABI-caught panic. Pure template queries take neither lock.
Expected-library checks fence editor commits; state is written last. Ordinary saves retain
thrown-failure restoration, while migration/restore/delete persist snapshots and expected
writes before mutation. Restart recovery verifies transaction identity and exact bytes,
refuses external changes, and distinguishes a landed rename from bookkeeping failure.
Only a fully settled library publishes the existing native commit notification.


## Automatic recognition and invocation sessions

`template_session.rs` owns the ephemeral runtime, recognizer, binding and invocation state.
`owl_app_session_new` (ABI 1) returns an owned opaque handle and an owned JSON status buffer;
`owl_app_session_call` borrows it synchronously; `owl_app_session_free` consumes it once.
Swift serializes calls/destruction on its owner thread. An optional index handle is distinct,
live and borrowed for that event. No Rust callback, I/O, worker or shared mutable singleton
is involved. Creation and runtime library publication accept storage-sized snapshots;
other events have the pure dispatcher's 4 MiB request bound. Native wrappers turn rejected
user values into blocked evaluations, not traps. A context-transfer failure remains presentable
with the original template and a blocking diagnostic; it neither invalidates the invocation nor
requests the clipboard again. Input is never truncated into a usable result. Response buffers
have no output-size bound.

The runtime uses the existing `automatic_index` builder, retaining one Rust trie. Keystrokes
send only event facts and receive mark/restore/invoke intents; they never serialize the index,
parse templates or read storage. Swift retains only the opaque index reference and IMK target
objects. Publication first validates a replacement index; the native will-change notification
flushes old marked input before publishing the committed snapshot to Rust.

Rust increments a publication revision on every accepted snapshot, a policy revision only
when enable/disabled-host policy changes, and per-entry versions only for changed or deleted
IDs (including tombstones). IDs use the template library's existing uppercase UUID convention.
An invocation binds its selected entry's version and value, so editing another entry does not
invalidate it. An old version cannot revive after delete/recreate or an observed mismatch.
The automatic source additionally binds session, mode, schema and policy facts. Runtime
publication/version generation and comparison have no independent Swift implementation.

Every invocation handle is a distinct request identity. Rust owns frozen clipboard/calendar
facts, parameter mapping, evaluation and trailing delimiter checks, confirmation, dispatch
admission, cancellation and completion generation. Native asynchronous completion echoes the
accepted generation into the same owned handle; cancelled/replaced/invalidated calls reject it.
The native `state` property is an observable UI projection, updated only after Rust accepts an
operation. Native callbacks/closures are consumed as resources, not a second business state.

`host_delivery.rs` owns original preservation, the independent original/result write slots,
expected presentation suspension, cancellation, readback consumption and UTF-16 cursor intent.
Swift owns field identity and expected IMK rebind, supplies facts and executes returned effects. A refused or unverifiable host write is a delivery outcome, not cancellation of the user's
preview: preparation failure still yields a retained, explicitly copyable result. Production
and the dynamic-automatic tests share the same thin delivery-to-invocation initializer.
Automatic input-session identity is checked by the Rust source binding; each invocation handle
owns its request/session lifetime and confirmation/cancellation generation. Manual/K host-field
and IMK rebind generations remain in the existing delivery adapter for #362. A new controller
is therefore not equated with a new logical host target. No synchronous AX read was added, Chromium
capability restrictions are unchanged, and #331 still requires its host implementation/acceptance.


## Host delivery and Chromium

The owned `delivery` session uses the existing serialized App session ABI. Every original
preservation, result dispatch and verification receipt is consumed before native callbacks;
reentrant confirmation and duplicate/late readback cannot repeat an effect or completion.
Expanded results enter in bounded Unicode-scalar chunks, so a valid result larger than 4 MiB
is still written once. Host readback remains bounded to 65,536 UTF-16 units; unavailable
proof yields a retained copyable result, never a retry, speculative deletion or truncation.

Native IMK range policy remains unchanged. Chromium's AX field identity, UTF-16 selection,
bounded string-for-range readback, character count and settable selection are proved separately.
An explicit replacement selects only the previously verified original range and uses ordinary
IMK insertion, without a denied IMK replacement range. Rust reserves the result slot before
selection preparation. The native selection setter runs once; Rust consumes up to eight
25 ms observation tokens until the original text and requested selection are confirmed.
Every observation rechecks field/source identity and the captured host generation. A fresh
admission after the final native reads authorizes at most one insert; duplicate or cancelled
callbacks cannot write. The native AX setter captures its field before final selection admission;
no reentrant host query occurs between that admission and the actual selection effect.
A rejected/unsettled selection reports `selectionNotPrepared`, with
no text dispatch. Native insert receipts distinguish a call actually made from a pre-call
refusal, while host acceptance still requires post-write readback. No uncertain write is retried.
The existing disabled-by-default `OwlDebugLiveInputTrace` records only selection set/ack,
admission, actual dispatch, readback and cursor phase metadata; it never includes host text.

[`client_capability.rs`](../../rust/crates/owl-app-core/src/client_capability.rs) owns host
classification, override precedence and all capability reason codes. Swift passes raw native
facts and caches at most eight immutable input/decision projections, under a native lock.
The pure ABI performs no I/O or host callbacks. Existing Chromium restrictions, privacy and
explicit workaround semantics are retained. No per-key network, disk or AX work is added. Cursor placement independently validates the inserted text and a bounded
host grapheme context, then reads the actual selection back. Secure or unreadable fields fail closed.

Candidate/manual launches, field capture, original-preservation readback and result verification
wait until the host has returned from key processing. Ordinary keys add no synchronous AX,
network or disk access. Native AX/IMK evidence is not implied by a passing synthetic-host suite.

For Chromium automatic expansion, the shared Rust recognizer observes normal key processing;
no key is intercepted or replayed by the added path. After the first literal semicolon is
committed, the adapter binds its field and start coordinate outside the key event. A complete
trigger is used only when the same generation, field, caret and full original text are proven
again. Rust's committed-original mode preserves that text without a preservation write, and
replaces it once after confirmation. Fullwidth punctuation is not an ASCII trigger. Unsupported
AX capabilities or rapid changes before capture leave ordinary input in place. Return/Tab may
perform the host's normal action; changed focus, selection or page prevents expansion. The
existing non-Chromium marked-text delimiter behavior is unchanged. Installed Chrome acceptance
and its limitations remain tracked in #331; this implementation is not installation evidence.

The `focus` session owns capture-required failures, restoration polling/timeout, pending
cancellation and dispatch admission. Swift transfers the owned handle with the captured native
application, activates it and schedules timers. Poll tokens reject duplicate or superseded
callbacks. A restored application with an unverifiable field reaches the delivery adapter's
specific refusal; only an application that never returns yields `focusNotRestored`.
Every delivery effect takes a fresh binding admission after planning reads, preventing a
field change during native text queries from authorizing a write into the new target.

## Providers, requests and streaming

`provider_store.rs` owns profile defaults, catalog inference, active/default selection and CRUD,
legacy migration, scheme/host/default-port origin checks, Qwen Workspace rules and registry
transactions. The native provider host supplies raw atomic file writes, ISO-8601 formatting,
Foundation URL facts, UUID/time, preferences and the unchanged Keychain APIs. `providers.json`
keeps schema 1, its existing path, optional-field omission and secret-name convention. Keys never
enter that file or telemetry. The synchronous storage ABI carries explicit provider operations;
callback errors retain opaque tokens so public store failures preserve their native Error values.

The registry stages independent credential references before committing a profile. A thrown write
rereads the file; ambiguous contents retain both old and staged keys. Only a proved unreferenced
key is retired. Workspace batches can settle a proved landed write, while single-profile edits
retain the original failure outcome. A separate owned `providerRegistry` session holds only the
probe digest; native per-call key references supply digest facts and perform Keychain effects.
Fresh references do not inherit verification markers. Optional session facts use object envelopes.

`provider_wire.rs`, `provider_search.rs` and `provider_catalog.json` own capabilities, payloads,
Chat/Responses decoding, SSE dialects, retry policy, error classification/sanitization, model lists,
search results and grounding. Native code encodes the returned body plan with the original codec;
this preserves both canonical request bodies and historical numeric wire representations.
Provider request/response rules use storage-sized synchronous envelopes because network replies
and explicit AI payloads are not limited by the input-session request bound. Pure rules do no I/O.

Owned `providerStream` sessions buffer raw bytes across arbitrary UTF-8 splits and decide deltas,
errors, completion and cancellation. Native URLSession AsyncBytes are only buffered and forwarded;
Swift performs no UTF-8 or SSE parsing. It retains the caller's session, including its configured
transport behavior. Large native chunks are split only for bounded ABI transfer, never truncated.
Owned `providerCall` sessions govern retry admission; native tasks execute sends and sleeps and
reject cancelled results before parsing/telemetry. No provider call is added to ordinary input.

Existing request recording and public provider/storage suites exercise the actual App ABI.
The network recorder uses an explicit ephemeral session and a local URL/method allowlist;
unmatched requests fail locally. These are synthetic protocol and native-adapter checks, not
personal account or installed Keychain acceptance. Signing and Keychain storage identities are
unchanged; no real account or upgrade matrix is required by this internal rules migration.
