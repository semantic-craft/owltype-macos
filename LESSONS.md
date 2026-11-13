# Lessons from verified work

Each entry keeps the rule, reason, regression, a `Verify (验证点):` line (how to check later
that the lesson is in place: which file to read, which command to run, what result to expect),
and dates observed. Count distinct
review dates, not retries. Keep deterministic checks in the local gate.

## `codesign -R` inline requirements in package scripts must use `-R'=anchor ...'` without a separator `=`

**Pass inline `SecRequirement` strings to `/usr/bin/codesign` as `-R'=anchor ...'` (one `=`, which marks an inline requirement rather than a file path), never `-R='=anchor ...'`, and validate `-R` syntax against real `/usr/bin/codesign` in `scripts/pkg-leftovers.selftest.sh`.**

- Reason: on 2026-11-08 installing `package/Owltype-update.pkg` via `/usr/sbin/installer -pkg ... -target /` failed in `./postinstall` with `error: invalid or corrupted code requirement(s)` / `line 1:1: unexpected token: =`. Commit `678ffa2` (#414) wrote `-R='=anchor ...'` in `scripts/postinstall` (whereas `Installer.swift` wrote `-R'=anchor ...'`). Because `-R` is a short `getopt` option, `-R='=anchor ...'` passed `==anchor ...` as `optarg`, leaving a leading `=` in the requirement expression after `codesign` stripped the inline prefix. `scripts/pkg-leftovers.selftest.sh` had mocked `/usr/bin/codesign` as `exit 0` without checking `-R` syntax.
- Prevention: use `-R'=anchor ...'` in [postinstall](scripts/postinstall), matching [Installer.swift](installer/Sources/Installer.swift), and have the mock `codesign` in [pkg-leftovers.selftest.sh](scripts/pkg-leftovers.selftest.sh) forward any `-R*` argument to `/usr/bin/codesign --verify "$arg" /bin/ls` and fail on `invalid or corrupted code requirement`.
- Regression: [pkg-leftovers.selftest.sh](scripts/pkg-leftovers.selftest.sh) fails closed on `-R='=anchor ...'` and passes on `-R'=anchor ...'`.
- Scope: `scripts/postinstall` and `scripts/pkg-leftovers.selftest.sh`.
- Verify (验证点): `bash scripts/pkg-leftovers.selftest.sh` passes (`19 passed, 0 failed`) and `rg -n -- "-R='=" scripts/ installer/ sources/` prints nothing.
- Seen on 1 distinct date: 2026-11-08.

## Input-menu PDF icons must use pure vector paths without SVG masks and be verified through AppKit

**Author `resources/OwlMenuIcon.svg` with `fill-rule="evenodd"` vector subpaths rather than `<mask>`, and verify the generated `OwlMenuIcon.pdf` by drawing it through `NSImage` in AppKit.**

- Reason: on 2026-10-31 the installed 2.3.0 input menu bar and dropdown showed a blank space beside「猫头鹰输入法」even though `/Library/Input Methods/Owltype.app/Contents/Resources/OwlMenuIcon.pdf` matched the committed file from #308 (`741c795`). `OwlMenuIcon.svg` used `<mask id="owl-cutouts">` for the eye and wing cutouts; `rsvg-convert -f pdf` (Cairo 1.18.6) exported that `<mask>` as a PDF `/SMask /S /Alpha` containing a 1-bit `/DeviceGray` image with a nested 8-bit 22×16 `/SMask` and flipped matrix (`22 0 0 -16 0 16 cm`). CoreGraphics (`NSPDFImageRep`) rendered all pixels with alpha `0.0`; #308 had only inspected SVG rendering and PDF byte identity without rendering the generated PDF through AppKit.
- Prevention: express the eye oval and stroked wing curve as closed subpaths inside a `fill-rule="evenodd"` `<path>` with a separate `<circle>` for the pupil in [OwlMenuIcon.svg](resources/OwlMenuIcon.svg), so `rsvg-convert -f pdf` emits pure vector PDF path operators with no `/SMask` or bitmap objects.
- Regression: `testBundledMenuIconPDFRendersNonEmptyTemplateWithCutoutsInAppKit` in [ActivationPolicyTests.swift](tests/ActivationPolicyTests.swift) asserts that the bundled `OwlMenuIcon.pdf` contains no `/SMask` and renders >300 opaque pixels with opaque pupil/body and transparent eye/wing cutouts when drawn via `NSImage` into an `NSBitmapImageRep` (fails with `0` opaque pixels on the #308 PDF).
- Scope: `resources/OwlMenuIcon.svg`, `resources/OwlMenuIcon.pdf`, and AppKit/CoreGraphics PDF rendering.
- Verify (验证点): `python3 scripts/verify.py swift --test ActivationPolicyTests/testBundledMenuIconPDFRendersNonEmptyTemplateWithCutoutsInAppKit` passes and `rg -a '/SMask' resources/OwlMenuIcon.pdf` prints nothing.
- Seen on 1 distinct date: 2026-10-31.

## Upgrading across resource engine contracts must not require the old active generation to satisfy the new engine

**`Store::prepare` only verifies the active record when short-circuiting an identical digest; `Store::commit` drops an incompatible previous generation instead of retaining a broken rollback target, and `OwlDictPackCenter.refresh()` treats an outdated incompatible active generation as `.notInstalled`.**

- Reason: on 2026-10-31 Settings → 键盘输入 → 完整词库 showed `Rust 词库状态无法读取：资源文件缺失：files/msime-wubi.db` with a `重试` button that could never recover. On-disk `state/active/pinyin-wubi.json` held `version: 1` (built under `legacyEngine` before `files/msime-wubi.db` and `role: "wubi-dictionary"` were introduced in v4). `OwlDictPackCenter.refresh()` validated the v1 active state against the v4 `validate_compatible` contract and entered `.failed`; then `Store::prepare` ran `this.verify_record(&active["current"])` against the v4 `nativeEngine` before checking `this.version(&active, &m)`, failing with `missingEngineSQLiteFile("wubi-dictionary")` and blocking any upgrade to v4.
- Prevention: in `rust/crates/owl-app-core/src/resource.rs`, `Store::prepare` verifies `active["current"]` only when `active["current"]["digest"] == m["digest"]`, and `Store::commit` retains `active["current"]` as `previous` only if it passes current verification and compatibility checks. In `sources/DictPack/OwlDictPackCenter.swift`, `refresh()` treats an active generation older than `OwlRustCompatibleResources.packageVersion` that fails `activeGeneration()` validation as `.notInstalled` while preserving `.failed` diagnostics for corrupt current-version generations.
- Regression: `testOutdatedIncompatibleActiveGenerationRefreshesAsNotInstalledWhileCurrentCorruptFails` in `tests/OwlDictPackTests.swift` and `testPrepareAndActivateOverIncompatibleOlderActiveGenerationDropsUnusableRollbackTarget` in `tests/OwlRustResourceTransactionTests.swift`.
- Scope: Rust resource store and `OwlDictPackCenter` state machine across engine contract upgrades.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlDictPackTests --test OwlDictPackCenterTests --test OwlRustResourceTransactionTests --test OwlRustResourceContractTests`.
- Seen on 1 distinct date: 2026-10-31.

## Reserve delivery before selection preparation, but report actual dispatch

- Seen 1x (2026-10-30): installed #362 candidate `25e4263` recognized and rendered the
  Chrome automatic trigger, retained its result and left the literal selected. Source review
  confirmed that a failed synchronous AX selection readback could skip `controller.apply`
  while the Rust slot already reported `attemptedUnverified`. The actual Chrome failure
  phase remains a native-validation question; this source defect alone did not prove it.
- Regression: `testNativeDispatchRefusalIsNotReportedAsAnAttemptedWrite` failed with
  `attemptedUnverified` for zero insert calls. `testDelayedSelectionPreparationWaitsAndConsumesLateCallbacksOnce`
  failed because text was dispatched before the delayed selection was confirmed.
- Rust now separates reservation from the native write receipt. AX selection is set once,
  then observed with bounded, single-use tokens; fresh original/selection/binding/generation
  facts admit one insert. Failed preparation retains the result without claiming a text attempt.
  Duplicate receipts and cancellation cannot retry text or repeat cursor movement.
- Independent review found one remaining native query after selection admission: obtaining
  the AX field could reenter and cancel/change the generation before the setter. The regression
  `testReentryWhileCapturingSelectionWriterCannotChangeTheSelection` reproduced both cases.
  Capture the native setter first; then perform final Rust admission, with no host query between
  that admission and the captured setter. Cancellation must prevent selection changes as well as text.
- Verify (验证点): run `OwlTemplateHostDeliveryTests`, `OwlTemplateDeliveryTests`,
  `OwlDynamicAutomaticTests` and `OwlClientCapabilityPolicyTests` through `scripts/verify.py swift`.
  The failed/cancelled selection regression also checks bounded waiting and zero text writes.
  Installed Chrome/TextEdit validation must distinguish selection set/ack, actual dispatch
  and post-write readback using the opt-in metadata trace; synthetic tests are not that proof.

## Read fresh admission facts after native planning queries

**A native text/readiness query can reenter and change the target or cancel an invocation;
Rust must see the final binding/pending facts before allowing an effect.**

- Reason: #362 review found that delivery took `rejection` before its range/text reads.
  The App-host regression changed the target inside a text read and still received a write.
  A corresponding broker regression cancelled inside host readiness and still dispatched.
- Prevention: Rust independently admits original/result/cursor effects using the fresh native
  binding after planning. Focus polls receive `pending` after native readiness has returned.
- Regression: `testTargetChangingDuringReadbackCannotReceiveThePlannedWrite` and
  `testCancellationDuringHostReadinessDoesNotDispatch` both failed before their fixes.
- Scope: synthetic native reads through the real App ABI; native field/activation evidence is separate.
- Verify (验证点): run `OwlTemplateHostDeliveryTests` and `OwlPanelInsertionBrokerTests` with `scripts/verify.py swift`.
- Seen on 1 distinct date: 2026-10-30.

## A late host receipt cannot repeat a native effect

**Consume preservation/readback receipts in the owned delivery state before calling native
cursor or presentation effects; every write and completion has one slot.**

- Reason: the #362 App-host regression delivered the same settled-readback callback twice.
  After the user moved the caret back to the end, the old Swift path moved it again (2 moves)
  and overwrote that new position. The regression failed before the Rust delivery switch.
- Prevention: the Rust delivery session consumes verification and preservation receipts once,
  independently of its original/result write slots. Cancelled invocations discard late presentation.
- Regression: `testLateDuplicateReadbackCannotMoveTheCursorAgain` and
  `testOriginalPreservationWaitsBeforePresentingAndDiscardsCancelledReceipt` through the real App ABI.
- Scope: synthetic host and controlled native callbacks; not installed Chrome evidence.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlTemplateHostDeliveryTests`.
- Seen on 1 distinct date: 2026-10-30.

## Oversized captured context is a visible template error, not cancellation

**A failed context transfer must leave the invocation presentable with a blocking diagnostic;
only cancellation or a stale binding ends that invocation.**

- Reason: #361's first Rust session bridge marked `valid = false` when a clipboard payload
  exceeded the 4 MiB ABI request limit. `start` then returned without a window or diagnostic.
- Prevention: Rust retains a context-failure state, returns the original template and transport
  diagnostic, prevents confirmation, and does not request the clipboard again. No truncation.
- Regression: `testOversizedClipboardPresentsBlockedEvaluationWithoutRecapturingOrDelivering`
  failed at the actual `start/present` seam before the fix; it also checks explicit cancellation.
- Scope: synthetic clipboard provider through the real App session ABI; no personal clipboard read.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlTemplateDeliveryTests --test OwlTemplateClipboardTests`.
- Seen on 1 distinct date: 2026-10-30.

## An invocation binds the selected template version, not every library commit

**Keep per-entry revisions in the business core, using the library's canonical UUID form; a
changed or deleted selected entry invalidates the call, while another entry's edit does not.**

- Reason: the #361 regression first showed a previewed invocation still inserting after its
  library entry was removed. A first per-entry bridge then looked up lowercase IDs while the
  library decoder canonicalizes UUIDs to uppercase, so removal still appeared unregistered.
- Prevention: Rust runtime publication owns version/tombstone generation and normalized ID
  lookup; invocation events compare the selected value/version and permanently reject mismatches.
  A parameter window may legitimately return through a different IMK controller; host delivery
  validity must not be treated as invocation cancellation. Review of #361 found that doing so
  discarded the copyable result after unconfirmed original preservation. Production and the
  dynamic-automatic suite now share the same delivery/invocation wiring; that existing regression
  failed with the incorrect binding and also checks explicit copy after the fix.
- Regression: `testCommittedTemplateRevisionInvalidatesAnAlreadyPreviewedInvocation` failed
  before the binding and UUID fixes; `testEditingAnotherTemplateDoesNotInvalidateTheSelectedEntry`
  protects the scope of invalidation. Existing cancellation and rebind suites remain applicable.
- Scope: App-host Swift→Rust tests with synthetic template libraries. No installed-host claim.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlTemplateDeliveryTests --test OwlTemplateHostDeliveryTests`.
- Seen on 1 distinct date: 2026-10-30.

## A session event tap must not run on the main thread

**A head-inserted `.defaultTap` holds every keyDown in the login session until its callback returns, so it gets its own thread and its callback reads no main-thread state.**

- Reason: on 2026-10-29 typing froze in every app, including after switching to ABC, until the
  installed e38405f process was killed (PID 82777, killed at 23:22). The Quick Send hotkey tap was
  serviced on the main run loop. It had never been active before: every launch until 18:48 that
  day logged `event tap not installed: accessibility not trusted`; the first `event tap installed`
  is 18:48:19, after Accessibility was granted. What stalled the main thread is not known. In an
  isolated repro (head `.defaultTap` on a stalled run loop, marked F19 keyDowns swallowed by a tail
  tap), a 600 ms stall delayed every key by up to 594 ms, and a 1.2 s stall made WindowServer
  disable the tap and drop 6 of 8 keys; the same tap on its own thread delivered 8 of 8 within 8 ms.
  The timeout branch re-enabled the tap without logging, so Owltype's own log held no trace.
- Prevention: `OwlHotKeyEventTap` runs the tap on the `im.owltype.hotkey-tap` thread, reads combos
  from UserDefaults and "Owltype is current" from a lock-guarded flag that the main thread refreshes
  on input-source change and `activateServer`, and logs `event tap re-enabled after timeout`.
- Regression: `testEventTapConsumesOnlyAMatchedComboWhileOwltypeIsCurrent` and
  `testEventTapFlagsAreSharedAcrossThreads` in
  [OwlQuickSendPanelModelTests](tests/OwlQuickSendPanelModelTests.swift). Tap placement itself is
  not unit-testable: the XCTest host has no Accessibility trust.
- Scope: macOS 27, Accessibility granted. The tap's latency under a stalled main thread was
  measured with the repro, not on the installed IME; the Quick Send hotkey was not retried live.
- Verify (验证点): `/usr/bin/log show --last 1d --predicate 'subsystem == "im.owltype.inputmethod.Owltype" && category == "hotkey"'`
  shows `event tap installed on its own thread` for the installed build; `grep -n CFRunLoopGetMain sources/UI/OwlQuickSendHotKey.swift` finds nothing.

## A real MCP client is not the one the helper tests imitate

**Check the helper against a captured session from each client: Antigravity CLI speaks MCP 2026-07-28 without `initialize` and sends only flat tool arguments.**

- Reason: on 2026-10-29 the installed e38405f build passed every helper test, yet with agy 1.4.10
  the call log named no agent (the client is read from `initialize`, which agy never sends; it
  opens with `server/discover` and names itself in each request's `_meta`), and
  `template_render` could not be called with parameters (agy's `call_mcp_tool` sends only
  primitive values, so the `arguments` map arrived as a string and was refused). Quitting the
  bound app was reported as `focus_changed`: macOS activates another app before announcing the
  termination.
- Prevention: the helper reads the client from request `_meta` when there was no `initialize`
  and accepts `arguments` as JSON text; the delivery waits `leaveSettle` before naming why the
  bound app left the front.
- Regression: `names_a_stateless_client_from_its_request_meta` and
  `template_tools_forward_their_arguments` in
  [helper_stdio.rs](rust/crates/owl-agent-mcp/tests/helper_stdio.rs);
  `testTheBoundAppQuittingAfterAnotherTookTheFront` in
  [OwlAgentDeliveryTests](tests/OwlAgentDeliveryTests.swift).
- Scope: agy 1.4.10 and Grok Build 1.0.70 (initialize, MCP 2025-11-25) on macOS 27. Other
  clients are not covered.
- Verify (验证点): with Agent 接入 on, `agy -p "call owltype's template_render with 议题=发版"`
  returns a preview, and the call log in 设置 → Agent 接入 names `antigravity-client`.
- Seen on 1 distinct date: 2026-10-29.

## A merge is allowed only by a passed gate receipt for its exact head

**Merge with `scripts/merge-pr.py`, which refuses unless a passed full-gate receipt names the pull request's head; a gate log, a PR body or an earlier head is not that proof.**

- Reason: on 2026-10-29 PR #345 was merged on head `d2ae1a8` whose gate had failed. The merge
  command ran after a `grep -q "gate: ok" … && update-body` chain joined by `;`, so the failed
  check only skipped the body edit, and the body still claimed the earlier head's pass. The
  failure itself was not the change: `make owl-seed` hit `shallow.lock` in the cache
  `/tmp/owltype-rime-seed`, which every worktree shares, while another worktree's gate was
  fetching into it. A re-run on `d2ae1a8` passed (receipt `20261029T095608Z-full-8kprc1mf`).
- Prevention: [merge-pr.py](scripts/merge-pr.py) reads the `scripts/verify.py` receipts and
  merges only with `--match-head-commit` on a head that has a passed, clean, unchanged full
  gate; [ci.md](docs/operations/ci.md) names it as the merge command.
  [owl-seed.sh](scripts/owl-seed.sh) holds `/usr/bin/lockf` on the cache for the whole run, so
  concurrent gates wait instead of failing.
- Regression: [merge-pr.selftest.py](scripts/merge-pr.selftest.py) (failed, focused, other-head,
  moved, dirty, changed and unreadable receipts are refused), run by the gate.
- Scope: local merges by agents and the maintainer. A `gh pr merge` typed by hand still
  bypasses it; the ruleset cannot see local receipts.
- Verify (验证点): `python3 scripts/merge-pr.py <open PR> --dry-run` prints a receipt only after
  `scripts/gate.sh` passed on that head; two `make owl-seed` runs started together both succeed.
- Seen on 1 distinct date: 2026-10-29.

## A host waiting on the input method cannot answer accessibility

**Never read the host through accessibility in the same turn as a key event or an insert it is still processing; read it once that turn has returned.**

- Reason: on installed candidates for #331 (2026-10-29, builds dfbf8d6 and cb9314f) the candidate
  and automatic entries in TextEdit captured no field (`unverifiableTarget`) because the field
  was read inside `handle()`, while TextEdit waited for the key event's answer. After that was
  fixed, all three entries wrote the text once but every readback right after `insertText`
  timed out (`host field unreadable now`), so the cursor stayed at the end. The live trace
  named both; the 50 ms AX timeout made each one look like a missing field.
- Prevention: `captureOutsideKeyEvent` reads the field again after the key event when the first
  read fails. `deliver(_:completion:)` inserts once, then runs every post-insert check through
  `Access.settle`, which in production waits (25 ms polls, at most 8) until the host answers. A
  session re-activated during the insert is accepted only when the same AX field and a live
  client are proven again.
- Regression: `testFieldUnreadableDuringKeyEventIsReadAfterIt`,
  `testVerificationWaitsUntilTheHostHasProcessedTheInsert` and
  `testReactivatedSessionMustStillProveTheSameField` in
  [OwlTemplateHostDeliveryTests](tests/OwlTemplateHostDeliveryTests.swift).
- Scope: TextEdit manual, candidate and automatic entries land `{cursor}` on build 32383e9.
  Chrome ranges are denied by `OwlClientCapabilityPolicy`, so Chrome inserts once and leaves
  the cursor at the end, and automatic expansion does not trigger there at all.
- Verify (验证点): the regression tests pass; with `OwlDebugLiveInputTrace` on, a confirmed
  TextEdit template logs no `readback:` or `refused before insert` line and AX reports the
  caret at the `{cursor}` offset.
- Seen on 1 distinct date: 2026-10-29.

## Settings UI tests need an isolated desktop and real accessibility roles

**A settings control that VoiceOver cannot reach, or another process sharing the bundle id,
fails `OwlSettingsUITests`; the suite is not in the gate, so both drifted unnoticed.**

- Reason: on 2026-10-29 the suite failed 9 checks at main. `SettingsRadioRow` combined the whole
  row, so 双拼输入 and 五笔输入 surfaced as one row-wide pop-up (their scheme Picker) instead of a
  radio button. The AI page had replaced the `+ 供应商` buttons with the 选择供应商预设 menu.
  The rest were the desktop: the installed input method (`/Library/Input Methods/Owltype.app`)
  shares `im.owltype.inputmethod.Owltype`, so XCTest took its panels for the target's dialogs;
  another worktree's gate launched its own Owltype host mid-run; other agents' apps raised
  windows over the settings window and took keyboard focus.
- Prevention: a row with a trailing control labels only its own button. The suite selects an
  ASCII keyboard layout for the run, activates the app before each click or keystroke, waits
  for filter changes instead of reading `exists` at once, and attaches `app.debugDescription`
  when a control is missing. Run it when no other Owltype test or gate is running.
- Observed again on 2026-11-13: the broad settings journey passed once, then twice
  reported `template-save` at `{{844, -315}, {52, 35}}` as not hittable on a shared
  multi-display desktop. Preserve the failed receipts and investigate the actual
  visible/scroll geometry before attributing it to a product change; see
  [#423](https://github.com/semantic-craft/owltype-macos/issues/423).
- Regression: [OwlSettingsUITests.swift](tests/OwlSettingsUITests.swift), all four tests.
- Scope: the settings UI suite (scheme `OwltypeUITests`). The gate does not run it.
- Verify (验证点): `xcodebuild test -project Owltype.xcodeproj -scheme OwltypeUITests
  -destination 'platform=macOS' -only-testing:OwltypeUITests/OwlSettingsUITests` passes; on a
  miss, the attached tree names the role the control has.
- Seen on 1 distinct date: 2026-10-29.

## A host field that comes back after a window is not the IMK client you captured

**Bind a template delivery to the application and its focused accessibility field; take the IMK session from whatever IMK activated for that application when the field returns.**

- Reason: on installed 2.0.12 (2026-10-05) and 2.1.1 (2026-10-29) a template confirmed in the
  parameter window never reached TextEdit or a Chrome textarea and was reported as
  `focusNotRestored`. The live trace showed the host field returning through a new IMK
  controller (`controller init` and a fresh `activateServer` right after the window closed),
  while delivery still required `capturedController.client === capturedClient`. That never
  held, so restoration timed out and every cause was collapsed into one focus message. The
  candidate route also left its code as marked text: it assigned `preedit = ""` without
  sending, the next empty update was skipped as empty-to-empty, and TextEdit committed the raw
  `Kyshx` when the window took focus.
- Prevention: `EngineRuntime.activatedInputController` follows `activateServer` and
  `deactivateServer`; non-immediate delivery re-binds to it when its client reports the
  captured application, and the focused AX field must still equal the captured one. The broker
  reports the host's own refusal once the application is back, and `focusNotRestored` only
  when it never came back. `clearHostComposition()` sends the empty marked text before any
  window. Each refusal and cursor fallback writes a `template delivery` line to the live trace.
- Regression: `testDeliveryRebindsToTheSessionActivatedForTheSameApplication`,
  `testActivationRegistryFollowsIMKActivation` and
  `testTemplateCandidateClearsHostMarkedTextBeforeAnyWindow` in
  [OwlTemplateHostDeliveryTests](tests/OwlTemplateHostDeliveryTests.swift);
  `testRestoredApplicationReportsTheHostsOwnRefusal` in
  [OwlPanelInsertionBrokerTests](tests/OwlPanelInsertionBrokerTests.swift).
- Scope: unit tests cover the decision, not IMK. Installed-host results for TextEdit and Chrome
  are recorded in #331; WeChat and other hosts are not covered.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlTemplateHostDeliveryTests --test OwlPanelInsertionBrokerTests`
  passes; with `OwlDebugLiveInputTrace` on, a confirmed template in TextEdit logs no
  `template delivery refused` line.
- Seen on 2 distinct dates: 2026-10-05, 2026-10-29.

## A recorded request body must not read the clock

**A digest of a request body that embeds today's date passes only on the day it was recorded.**

- Reason: #323 recorded SHA-256 digests of every streaming and Ask request body. The Ask system
  prompt states the search date, and `OwlWebSearchGrounding.askSystemPrompt` took it from
  `Date()`. From 2026-10-29 the three `ask|deepseek|…#1` keys mismatched, so `scripts/gate.sh`
  failed on every head and blocked merges.
- Prevention: `OwlAskAnythingTransportAdapter` and `OwlAskAnythingModule` take `now:` (default
  `Date.init`) and pass the day to `askMessages`; the recording test pins it to 2026-10-28.
  Any new value in a recorded body that comes from the clock, a UUID or the environment gets the
  same injection before it is recorded.
- Regression: `testEveryStreamingAndAskRequestMatchesTheRecordedPreGatewayRequest` in
  [OwlLLMStreamingRecordingTests.swift](tests/OwlLLMStreamingRecordingTests.swift).
- Scope: request bodies recorded by that test. Production still states the current day.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlLLMStreamingRecordingTests` passes
  on any date; `grep -n "Date()" sources/Lane/OwlDeepSeekSearch.swift` shows only parameter
  defaults.
- Seen on 1 distinct date: 2026-10-29.

## A release App must be readable by the console user, whatever umask built it

**The PKG commits the App as root and finishes the install as the console user, so a file other users cannot read passes signing, notarization and every digest check and still fails the install.**

- Reason: the first 2.1.1 PKG (cohort `376fd854…`, revision 16026bf) failed in `postinstall`:
  `--finish-install` aborted because dyld got `errno=13` opening
  `Sparkle.framework/Versions/B/Sparkle`. The release worktree had been bootstrapped under
  `umask 077`, so all five Sparkle executables were 0700. `build-sparkle.py verify()` read only the
  receipt and Updater UUIDs, so the release reused that build as current. Cohort digests record
  modes, but they compare one copy with another, so the App, both PKG payloads and the DMG
  agreed on the wrong modes.
- Prevention: `release.sh` runs under `umask 022`; `build-sparkle.py` builds under `umask 022`,
  and `verify()` treats entries other users cannot read as not current, which triggers a rebuild.
  `finalize-release-bundle.py` refuses such entries anywhere in the App before signing.
- Regression: `test_entries_other_users_cannot_read_fail_the_finalizer` in
  [release-bundle.selftest.py](scripts/release-bundle.selftest.py) and
  `test_build_other_users_cannot_read_is_not_current` in
  [build-sparkle.selftest.py](scripts/build-sparkle.selftest.py).
- Scope: file modes of the built App only. A failed `--finish-install` still leaves the new
  files in place without rolling back; that path is not covered here.
- Verify (验证点): both selftests pass, and for a shipped App
  `find Owltype.app ! -type l \( ! -perm -o+r -o \( -type d -o -perm -u+x \) ! -perm -o+x \)`
  prints nothing. On the failed install it printed exactly the five Sparkle executables.
- Seen on 1 distinct date: 2026-10-27.

## Host composition end must execute the engine selection

**A correct preview inserted into the client does not prove native finish behavior.**

- Reason: Wubi `gggg`, highlight `五一`, then IMK composition end displayed `五一`,
  but reopening the session still put `王` first. The host inserted a preview and
  cancelled the engine instead of selecting through `FinishOnFocusLoss`.
- Prevention: route Rust composition end through the native action before inserting
  its returned commit; preserve plugin/bare-prefix raw rules and the snapshot clear.
- Regression: `testWubiFocusFinishCommitsAndLearnsHighlightedCandidate` observes both
  client text and the reopened session's candidate order, without reading journal tables.
- Verify (验证点): run that real controller integration test; the client commits `五一`
  and a new session returns `五一` first for `gggg`.
- Observed: 2026-10-26.

## The gate completes the checkout before the first check reads it

**`submodules` is the gate's second stage, right after `tools`; no later stage may be the first to need a submodule, and the receipt must not count that initialization as a source change.**

- Reason: the first full gate in a fresh worktree (`20261022T000748Z-full-60z149yn`, the head of
  PR #241) failed in `portable_scripts`: `build-sparkle.selftest.py` runs `git archive` against
  the pinned revision inside `Sparkle/`, still an empty directory, so git answered
  `fatal: not a tree object`. `git submodule update --init --recursive` lived in `bootstrap_seed`,
  four stages later. The main checkout has always had its submodules, so the order was never
  exercised; the run was repeated after a manual initialization. A gate that had reached the
  end would still have failed: [verify.py](scripts/verify.py) recorded every submodule as
  `uninitialized` before and in full after, which reads as `source-changed`.
- Prevention: `submodules` is the second entry of `gate_steps` in both modes and `bootstrap_seed`
  no longer initializes. The receipt records a submodule that matches its gitlink as `pinned`
  whether or not it is initialized, so initialization alone is never a source change, while a
  modified or re-pointed submodule is still recorded in full.
- Regression: `test_gate_initializes_submodules_before_any_check_reads_the_tree`,
  `test_submodule_initialization_during_check_is_not_a_source_change` and
  `test_edit_inside_a_submodule_during_check_is_a_source_change` in
  [verify.selftest.py](scripts/verify.selftest.py), run by the `navigation` stage of
  [the merge gate](scripts/gate.sh); all three fail on the previous scripts. The full gate of
  this change ran first in a worktree with no initialized submodule (PR #242).
- Seen on 1 distinct date: 2026-10-22.

## A probe must see the process that runs it and must not parse display text

**List servers with `pgrep -a`, because the App re-checking itself is the probe's parent; take a server's path and version from `proc_pidpath` and its bundle, not from `lsappinfo` text.**

- Reason: a tester's update to 2.0.20 through 检查更新 (2026-10-22) showed 「阶段「核验会话」失败：
  自检超时（selfCheckTimedOut）；未满足：运行中的猫头鹰不在 /Library/Input Methods（）；运行中的版本为 ，
  预期 2.0.20」 above 「刚才重新探测：没有运行中的猫头鹰进程」, while typing worked. Two faults. The
  installer's probe saw exactly one server mapping the installed executable's inode, but the path
  and version it parsed from `lsappinfo info -only executablepath,CFBundleVersion` were empty: the
  parser matched only `executable path="…"` and `Version="…"`, the layout macOS 27.0.1 prints
  (checked on two test Macs). What the tester's Mac printed is unknown; a 2020 write-up of
  `lsappinfo` on Catalina shows raw `"Key"="Value"` pairs, and a pid LaunchServices does not know
  prints nothing. Separately, the App's re-probe (#240) runs the probe as its child, and macOS
  `pgrep` leaves out its own ancestors unless given `-a`, so the running App never saw itself and
  every re-probe reported no server. Only fakes had exercised the re-probe before release.
- Prevention: `OwlSessionRestart.serverQuery` passes `-a`; the probe still drops the driver and
  itself. `OwlSessionRestart.server` takes the path from `proc_pidpath` and the version from the
  Info.plist beside the executable, read only while the process maps the file at that path. The
  probe no longer runs `lsappinfo`.
- Regression: `testServerQueryListsTheProcessThatRunsIt` (fails without `-a`) and
  `testServerFactsComeFromTheKernelAndTheBundle` in
  [OwlSessionRestartTests](tests/OwlSessionRestartTests.swift). Not verified: the fixed probe on the
  tester's Mac, whose macOS version is unknown.
- Verify (验证点): `make test TEST_ONLY='OwlSessionRestartTests'` passes; `rg -n 'usr/bin/lsappinfo' sources installer` finds nothing.
- Seen on 1 distinct date: 2026-10-22.

## A failed self-check must say which step failed and what it saw

**Record the stage, the error and the unmet conditions of a failed install self-check; re-probe before guidance and keep the reason in the support bundle.**

- Reason: the 2.0.14 report in #207 (filed 2026-10-11) and a tester's 2026-10-22 report after an
  update through 检查更新 both arrived as a screenshot of 「安装后的会话自检未通过」 with 「稍后处理」
  clicked, and typing worked in both. The App persisted only the failed version;
  `selfCheckTimedOut` named no stage, no condition and no probe result; the reason lived in the
  GUI dialog or `/var/log/install.log`, which neither tester sent. The prompt also fired without
  re-checking, so a transient failure showed stale guidance.
- Prevention: `OwlSessionRestart.run` reports each stage through `didEnter`; `diagnose` turns
  the thrown error and the last observation into a `Diagnosis` (stage, reason, unmet
  conditions, observation). The CLI prints `INSTALL_SESSION_DIAGNOSIS:` after
  `INSTALL_SESSION_FAILED:` and stores the record beside the failed version
  ([OwlInstallSelfCheckRecord](sources/Controller/OwlUpdateLogoutPrompt.swift)). At the
  input-safe time the App runs the same probe again and skips the prompt when every server
  condition holds; the alert and the support bundle section 「安装自检」 carry both facts.
- Regression: `testTimeoutDiagnosisNamesTheStageAndWhatTheLastProbeSaw`,
  `testSelectionThatNeverTakesEffectIsAttributedToTheSelectStage` and
  `testConsentTimeoutDiagnosisReportsOnlyTheEnableCondition` in
  [OwlSessionRestartTests](tests/OwlSessionRestartTests.swift);
  `test_selfCheck_failureStoresDiagnosisBesideVersion_passClearsBoth`,
  `test_recheckDecision_onlyACleanProbeCountsAsRecovered` and
  `test_recordRecovered_consumesPromptAndKeepsRecordMarkedRecovered` in
  [OwlUpdateLogoutPromptTests](tests/OwlUpdateLogoutPromptTests.swift). A tester's 2.0.20 alert
  (2026-10-22) carried a real failure's diagnosis and exposed two probe faults (previous entry); a
  passing re-probe on a tester's Mac remains unverified.
- Verify (验证点): `make test TEST_ONLY='OwlSessionRestartTests OwlUpdateLogoutPromptTests'` passes; a real failed self-check prints an `INSTALL_SESSION_DIAGNOSIS:` line after `INSTALL_SESSION_FAILED:`.
- Seen on 2 distinct dates: 2026-10-11, 2026-10-22.

## Run live tests through scripts/live-test.sh

**Live keys come from the environment only; `scripts/live-test.sh` loads them through direnv and fails when a named live test skips.**

- Reason: the DeepSeek key was in the project's `.envrc`, yet live tests skipped and the
  agent reported the key as missing. Three causes stacked: tests read keys from three places
  (`TEST_RUNNER_*` and legacy home-directory key files); the agent shell is not a login
  shell and had inherited a stale direnv export (DashScope and Ark keys, no DeepSeek key); and
  xcodebuild drops plain environment variables, so a skip looked like a clean run.
- Prevention: [OwlLiveKeys](tests/OwlLiveKeys.swift) is the only key reader and key list.
  [live-test.sh](scripts/live-test.sh) reads the names from it, always re-resolves them with
  `direnv exec` against the current `.envrc`, forwards them as `TEST_RUNNER_*`, and exits non-zero
  when a requested test skips. A blocked `.envrc` stops the run; the user approves it with
  `direnv allow`.
- Regression: [live-test.selftest.sh](scripts/live-test.selftest.sh) in the gate covers the
  stale-environment case, skip-as-failure, a blocked `.envrc` and keys never printed.
- Verify (验证点): `scripts/live-test.selftest.sh` passes; a live run through `scripts/live-test.sh` exits non-zero when a named live test skips.
- Seen on 1 distinct date: 2026-10-21.

## A web_search tool in the request is not a search

**Search with an explicit request, not a tool the model may ignore; take sources only from its results.**

- Reason: DeepSeek now serves `deepseek-v4-flash` as `deepseek-flash` (V4.1 Flash), which accepts
  the `web_search` tool and `tool_choice: required` yet never searches. It answered from memory
  with plausible official links, and its reasoning said it could not actually go online. Ask and
  source verification both showed these answers as searched. `deepseek-v4-pro` really searches:
  source verification took 17 to 23 seconds with links it had fetched.
- Prevention: DeepSeek search is a `POST /v1/tools/search` request
  ([OwlDeepSeekSearch](sources/Lane/OwlDeepSeekSearch.swift)); `deepseek-flash` answers from the
  numbered results with no `web_search` tool. Ask appends a sources footer built from the
  results, so a URL the model invents never reaches the user. Search failures with 401/402/403/404
  fail over to the next DeepSeek profile.
- Regression: `testSearchedAnswerNeverCarriesModelInventedSources` in
  [OwlAskAnythingModuleTests](tests/OwlAskAnythingModuleTests.swift),
  `testDeepSeekAloneSearchesAndFlashJudges` in
  [OwlSourceVerificationTests](tests/OwlSourceVerificationTests.swift); live checks
  `testAskWebSearchOnDeepSeekSearch` and `testSourceVerificationOnDeepSeekSearch` in
  [OwlSkillsLiveTests](tests/OwlSkillsLiveTests.swift).
- Verify (验证点): `make test TEST_ONLY='OwlAskAnythingModuleTests'` passes (includes `testSearchedAnswerNeverCarriesModelInventedSources`).
- Seen on 1 distinct date: 2026-10-21.

## The self-check budget must not include the user's consent

**Wait for the enable consent on its own deadline; start the 45-second self-check after it.**

- Reason: the same Mac as the next entry ran the notarized 2.0.17 GUI installer as a first install
  and got `INSTALL_SESSION_FAILED: selfCheckTimedOut`. The 45 seconds started before the
  「允许启用输入法」consent, so a late or hidden dialog spent the whole budget. A retry then ran as
  an update, which never requested enabling, so it could not recover. No probe output from that
  Mac was available; the consent wait is the inferred cause, and a surviving Owltype copy
  outside `/Library/Input Methods` (which the old code did not stop) is the other candidate.
- Prevention: `OwlSessionRestart.run` waits up to 120 seconds for enabled sources and fails with
  `inputSourceNotEnabled`; an update that finds them disabled requests enabling once; the session
  driver stops every process with the bundle id; the GUI shows consent guidance for that failure.
- Regression: `testConsentWaitDoesNotSpendTheSelfCheckBudget`,
  `testMissingConsentFailsWithItsOwnReason` and
  `testUpdateOfDisabledSourceRequestsEnableOnceSoRetryRecovers` in
  [OwlSessionRestartTests](tests/OwlSessionRestartTests.swift). A native GUI first install with
  consent remains unverified.
- Verify (验证点): `make test TEST_ONLY='OwlSessionRestartTests'` passes (includes `testConsentWaitDoesNotSpendTheSelfCheckBudget`).
- Seen on 1 distinct date: 2026-10-21.

## An existing App directory is not an existing install

**Classify first install versus update by `Contents/Info.plist`, not by the App directory.**

- Reason: a user's Mac had `/Library/Input Methods/Owltype.app` without `Contents/Info.plist`
  (an incomplete earlier removal). The GUI installer treated it as an update, and
  `--commit-install` failed reading the old Info.plist (`NSCocoaErrorDomain` 260,
  `INSTALL_FILES_FAILED`). preinstall would have failed too, running the missing executable.
- Prevention: the commit moves such a shell to the installer's `retained/` and publishes a
  first install; GUI and preinstall use the same Info.plist test, so session activation
  registers and enables the source instead of waiting for an update that has none.
- Regression: `testIncompleteLiveAppIsRetainedOutsideInputMethodsAndInstalledFresh` in
  [OwlInstallFilesTests](tests/OwlInstallFilesTests.swift). The GUI and preinstall
  classification has no offline test; a native install over an empty shell remains unverified.
- Verify (验证点): `make test TEST_ONLY='OwlInstallFilesTests'` passes (includes `testIncompleteLiveAppIsRetainedOutsideInputMethodsAndInstalledFresh`).
- Seen on 1 distinct date: 2026-10-21.

## Compare canonical paths with realpath, and test under /private

**Symlink checks must use realpath(3) on the raw path; file-system tests must run under the real `/private/...` path.**

- Reason: 2.0.16 moved install intermediates to `/private/var/db/...`. The candidate check
  compared `resolvingSymlinksInPath()` with the path, and Foundation drops a leading `/private`
  (so does `standardizedFileURL`), so the first real PKG install failed with `ELOOP` in
  `--commit-install`. The tests passed because their temp root was `/var/folders/...`, itself a
  symlinked path that Foundation round-trips unchanged. The live App stayed on 2.0.15; nothing
  was published.
- Prevention: `OwlBundleSwap.isCanonical` uses `realpath` against `url.path`; both bundle tests
  build their root with `realpath`, so it starts with `/private`.
- Regression: [OwlInstallFilesTests](tests/OwlInstallFilesTests.swift) and
  [OwlBundleSwapTests](tests/OwlBundleSwapTests.swift); the old check fails 4 of 8
  OwlInstallFilesTests. They run in [the merge gate](scripts/gate.sh). Offline tests still do not
  replace a real signed PKG install before publishing.
- Verify (验证点): `make test TEST_ONLY='OwlInstallFilesTests OwlBundleSwapTests'` passes; `rg -n realpath installer/Shared/OwlBundleSwap.swift` finds the check in `isCanonical`.
- Seen on 1 distinct date: 2026-10-20.

## Pin every gzip parameter a fixture depends on

**Fixtures that feed the canonical-archive gate must pass `compresslevel=9`, not rely on Python's default.**

- Reason: Python 3.15 lowered `gzip.GzipFile`'s default level from 9 to 6, which writes
  XFL `0x00` instead of `0x02`. The release-source and release-chain fixtures omitted the
  level, so the gzip header gate rejected them before the ownership and member-type checks
  they meant to exercise, and the full gate failed on main. The production writer already
  pinned the level and was unaffected.
- Prevention: pin `compresslevel=9` and `mtime=0` in every fixture that builds a
  `.tar.gz` for `check-archive-metadata`.
- Regression: [release-source-archive.selftest.py](scripts/release-source-archive.selftest.py)
  now recompresses a valid archive at level 6 and requires the gzip-metadata rejection.
  It runs in [the merge gate](scripts/gate.sh).
- Verify (验证点): `python3 scripts/release-source-archive.selftest.py` passes.
- Seen on 1 distinct date: 2026-10-19.

## Never install an ad hoc build as the input method

**Installed copies must carry a stable certificate requirement, not a per-build cdhash.**

- Reason: `install-dev.sh` re-signed the installed App ad hoc and `make install*` copied
  ad hoc or unsigned builds over the notarized copy. Keychain grants follow the designated
  requirement, so each rebuild would re-prompt for the login password; leftover ad hoc
  claims of the same bundle id made macOS resolve the input method to a dead build at login. A sibling app hit the Keychain prompt on
  three dates (2026-10-13, 10-16, 10-19).
- Prevention: [stable-sign-identity.sh](scripts/stable-sign-identity.sh) picks the identity;
  `install-dev.sh` rejects `# designated => cdhash` and identity changes before copying; the
  `make install*` targets refuse. Real upgrade with silent Keychain reads still needs a
  human-run install, which the self-test does not cover.
- Regression: [install-dev.selftest.sh](scripts/install-dev.selftest.sh) runs the real script
  with a fake bundle and mocked `codesign`/`security`; it failed 8/8 cases on the old script.
  It runs in [the merge gate](scripts/gate.sh).
- Verify (验证点): `scripts/install-dev.selftest.sh` passes.
- Seen in this project on 1 distinct date: 2026-10-19 (found by audit; same class as a sibling app).

## Every bundle that claims the id is a menu entry

**Uninstall and repair must clear all Owltype claims, not just the installed App.**

- Reason: a user's input menu showed two「猫头鹰输入法」entries, one with the 2.0.15 profile
  owl and one with the ≤2.0.14 badge icon. The old uninstaller deleted only
  `/Library/Input Methods/Owltype.app`, so older copies, installer `.Owltype.*` leftovers
  (LaunchServices registers them; 33 were on the development Mac) and stale records survived
  a reinstall. Which copy the user's Mac held is unconfirmed.
- Prevention: [repair-owltype.sh](scripts/repair-owltype.sh) and
  [uninstall-owltype.sh](scripts/uninstall-owltype.sh) share
  [owltype-maintenance-lib.sh](scripts/owltype-maintenance-lib.sh): remove stray copies,
  unregister every other claim, purge the list caches that mention the id, restart the menu agents.
- Regression: [uninstall-repair.selftest.sh](scripts/uninstall-repair.selftest.sh) runs both
  scripts against a fake system root with mocked privileged tools. It runs in
  [the merge gate](scripts/gate.sh). Not yet run on the affected Mac.
- Verify (验证点): `scripts/uninstall-repair.selftest.sh` passes.
- Seen on 1 distinct date: 2026-10-20.

## A librime session id is not a session identity

**Prove a session was recreated by its wrapper, never by comparing `RimeSessionId`s.**

- Reason: librime returns the `Session`'s heap address as its id
  ([service.cc](https://github.com/rime/librime/blob/1.17.0/src/rime/service.cc), from the retired submodule pin), so destroy-then-create often gets the
  freed address back. `testControllerRoundTrip` asserted a new id after applying
  settings and failed once in `gate.sh --quick`
  (`20261020T080929Z-quick-idniri2m`, both ids `524545235096`) while the next
  assertions, including the new page size, passed. A probe reused the id in 1250 of
  3000 destroy/create pairs. The `start_maintenance failed` line in that log came
  from a later test and is unrelated.
- Prevention: assert the old wrapper is invalid (`destroy` zeroes its id) and the
  controller holds a different wrapper. Product staleness checks that key on
  `sessionID` (snapshots, pin and expansion callbacks) also see reused ids; they pair
  it with input and revision state.
- Regression: [OwlInputHabitsIntegrationTests](tests/OwlInputHabitsIntegrationTests.swift)
  now checks wrapper identity, which is independent of allocator reuse. It runs in
  [the merge gate](scripts/gate.sh).
- Verify (验证点): `make test TEST_ONLY='OwlInputHabitsIntegrationTests'` passes; `scripts/gate.sh` runs it.
- Seen on 1 distinct date: 2026-10-20.

## Require positive evidence before judging a live trace

**An empty or unfinished trace is unverified, even when its error count is zero.**

- Reason: `omnibox judge` returned success for an empty file and a composition
  that never cleared. Zero `commitComposition finalize` lines did not show that
  the intended interaction happened.
- Prevention: require a non-empty composition and a final zero-length clear
  before emitting PASS; keep forced-finalize rejection. The judge covers these
  trace properties only; host identity, the actual input sequence, and visual
  acceptance remain the live host matrix's responsibility.
- Regression: [smoke-live.selftest.py](scripts/smoke-live.selftest.py) invokes the
  actual shell judge with empty, unrelated, clear-only, unfinished, valid and
  forced-finalize logs. It runs in [the merge gate](scripts/gate.sh).
- Verify (验证点): `python3 scripts/smoke-live.selftest.py` passes.
- Seen on 1 distinct date: 2026-10-15.

## Commit endpoint and replacement key reference together

**Write a replacement key under an independent secret name before committing its endpoint.**

- Reason: saving the endpoint first exposed the old key if Keychain failed and rollback
  also failed. An atomic config write can also succeed before permission hardening throws;
  a thrown save does not prove that nothing was persisted.
- Prevention: commit endpoint and new secret reference together; retire the old key only
  after confirmed success and only if no profile references it. An ambiguous save retains
  both keys; a readable old reference with no staged-key reference permits staged-key cleanup.
  Compare scheme/host/default-normalized port against the persisted profile: origin changes
  require a nonblank replacement key. Same-origin edits preserve the persisted key reference,
  and failed-save retries refresh the editing profile from the reloaded list.
  Probe requests also require a replacement key when the origin changes.
- Regression: `ProviderProfileStoreTests` reloads the real JSON store and checks both
  `defaultProfile` and `OwlCloudRouting` for retired/custom defaults. Post-write errors and
  key-write plus rollback failures produced 8 assertion failures before the fix.
- Scope: isolated file storage and injected secret-store failures; no live Keychain or
  installed-app upgrade acceptance is claimed.
- Verify (验证点): `make test TEST_ONLY='ProviderProfileStoreTests'` passes.
- Seen on 1 distinct date: 2026-10-21.

## Make one live call before merging a new external-API capability

**A feature that depends on a provider's live behavior is not mergeable until one real request has shown that behavior; mocked tests only prove our side.**

- Reason: #233 (d70c63f) added DeepSeek built-in web search to source verification with 8 mocked
  service tests and stated "未做：DeepSeek 真实联网调用" because no DeepSeek dev key was on the
  machine. The first live run showed Flash never searched and invented links, so the same day
  needed #236 (bdf9c5d, switch to v4-pro) and #237 (881f85c, search API plus flash), the latter
  shipped in 2.0.19.
- Done right: #237 ran `scripts/live-test.sh` with all six named live tests passing and listed
  per-test timings; #236 ran live checks before merge.
- Prevention: when no key is available, keep the PR open or behind a disabled default and ask for
  the key instead of merging on mocks.
- Verify (验证点):
- Seen on 1 distinct date: 2026-10-21.


## 删除开发产物前先检查运行引用与应用注册

- 起因与后果：2026-10-23 本机盘点发现多个项目已删除的构建／验收 App 仍有 LaunchServices 注册；删除目录不会自动注销。历史引入提交未确定。
- 修复：本次清理入口改为精确目录注销，包含嵌套辅助 App、已失效路径和同路径多条记录；注销失败或目录内有运行中的可执行文件就保留产物。删除后再核对注册。
- Done right：只处理调用方拥有的临时目录，不停止进程、不重建数据库；正式安装与其他工作区不在清理范围。
- Verify (验证点)：运行 cleanup_app_registrations 的回归，检查运行中副本、符号链接、注销失败及嵌套／重复记录；真实隔离 App 验证另记 PR，模拟测试不替代本机证据。
- Seen 1x (2026-10-23)。

## 被动候选预取不能改变已发布的选择身份

- 起因与后果：#266 的 Rust FFI `peek_candidates` 调用会展开候选的 `all_candidates`，在单字母候选超过初始上限时推进代次；控制器先取得当前页，再预取相邻页，旧文本可能被配上新代次 token。
- 修复：被动预取只读取当前缓存；显式翻页仍负责释放后续候选。不得仅更新代次而保留旧页快照。
- 回归与证据：`peek_preserves_published_generation_and_selection_with_withheld_candidates` 使用真实 FFI、SQLite 合成词库与单字母输入；修前代次从 3 变为 4 导致失败，修后同代次选择提交可见词，继续翻页能访问第 24 项之后的候选。
- Verify (验证点)：`cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi`；该结果只证明 FFI 行为，真实安装宿主验收另记对应 PR。
- Seen 1x (2026-10-25)。

### Real host numeric selection must include keypad keysyms

- During #249 installed TextEdit acceptance, System Events `keystroke "1"` produced macOS keycode 83 / `XK_KP_1` (65457). The Rust adapter handled only `XK_1...XK_9`, so the event passed through instead of selecting the visible candidate. Physical top-row keycode 18 correctly committed the displayed candidate.
- Map `XK_KP_1...XK_KP_9` through the same visible-index selection path. `OwlRustEngineTests.testKeypadDigitSelectsVisibleCandidate` fails before the mapping (unhandled key and missing commit) and exercises a real seed-backed session.
- Native input evidence must state the event path. CUA printable-key injection did not reproduce the physical IMK path on this host; the authorized System Events script did. Assert the intended foreground host/document and use actual key codes when a test means top-row digits. Keep keypad selection as its own regression instead of dismissing it as a script artifact.

### An empty engine context must clear native marked text

- #249 real TextEdit acceptance on `0621f6e` found that Esc hid the candidate panel but left underlined `ni'hao` in the host. Rust had cleared its input; `OwlRustSession.composition()` discarded every empty snapshot as nil. The existing IMK renderer sends empty marked text for a valid empty context, whereas nil only hides the panel.
- Preserve a valid empty Rust snapshot as an empty `EngineComposition`, matching the former librime seam. `testCancelReturnsEmptyContextToClearHostMarkedText` fails on the old adapter at the non-nil context assertion; it also covers deleting the last input character. An empty committed session now exposes an empty context, while destroyed/unavailable sessions still return nil.
- Engine cancellation alone is insufficient evidence: verify the actual host loses its marked text after Esc and after backspacing the last character, with no phantom commit on the next key.

### Host phrase cleanup must identify its own rows

- The FFI host-phrase synchronizer deleted `quick_parases` rows by `weight >= 900000` or by a tracked key/value pair. A tracked host row that shared the code and text of a base row therefore deleted the base row too, and the weight rule could delete unrelated high-weight base data. SQL errors were ignored.
- Keep host phrases in `EngineOptions` at query time. At session creation, quarantine an unreadable user journal through the engine's existing `quarantine_corrupt_journal` rule, rebuild `quick_parases` from the pinned source and replay quick-phrase operations from `msime_user.db`; this preserves user additions, deletions and learned weights while removing unjournaled legacy host rows without letting a corrupt journal block startup. A live host sync only performs that transaction when the old tracking table exists, and never infers row provenance from weight.
- Regression: `host_phrase_sync_preserves_base_rows_and_removes_only_legacy_imports` covers high-weight and same key/value base rows; `host_phrase_cleanup_failure_is_reported_and_atomic` checks failure atomicity; `legacy_host_migration_preserves_user_quick_phrase_state` covers journaled edits across two sessions; `corrupt_user_journal_is_quarantined_before_quick_phrase_replay` checks startup recovery.
- Verify (验证点): `cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi` passes with all four named tests.
- Seen on 1 distinct date: 2026-10-25.

### A Rime dictionary row may omit its weight column

- A valid source row such as `好\tvbg` has no third column and means weight 1. Treating three columns as mandatory rejects real Wubi data while the count assertions only report the downstream mismatch.
- Parse the text and code from the first two columns, default an absent or empty weight to 1, and reject only an explicitly unparsable weight.
- Regression: `test_parser_keeps_max_weight_and_reports_duplicate_and_rejected_rows` includes the two-column row and asserts `("vbg", "好", 1)`.
- Verify (验证点): `python3 scripts/build-owltype-msime-seed-db.selftest.py` passes.
- Seen on 1 distinct date: 2026-10-25.

### Synthetic test codes are not production dictionary evidence

- `testWubi86PureAndMixedSchemasZLookupAndPreferences` treated `gggg` as a unique four-code and `ffff` as empty, both inherited from the removed 50-row fixture. The real Wubi86 table has multiple `gggg` candidates and non-empty `ffff`, so seven assertions failed and later mixed-input checks cascaded.
- Choose uniqueness and empty-code fixtures from the pinned production table; currently `sebv → 极限` and nonexistent `bbbx`. Keep the production provenance assertions in the seed selftest so the fixture cannot silently return.
- dict-v2.0.39 derived about 600,000 Wubi phrases per profile, so `aaab` gained seven rows and stopped being an empty code (2026-10-29). Re-check both fixtures with SQL against both Wubi tables on every dictionary re-pin.
- Regression and Verify (验证点): `python3 scripts/verify.py swift --test OwlRustEngineTests` passes 15/15 after the fixture update. This is automated engine evidence, not native-host acceptance.
- Seen on 2 distinct dates: 2026-10-25, 2026-10-29.

### Publish seed data and its sidecars as one set

- The Wubi seed builder replaced `msime-pinyin.db` before writing the pinned license and source metadata. A later write failure could leave a new database beside old provenance files.
- Stage the database, license and metadata as sibling temporary files, replace them through the shared rollback-capable publisher in `scripts/resource_publish.py`, and restore every prior file if one installation step fails. Keep the tracked source license under `licenses/`, outside `data/`: the public-source boundary rejects tracked `data/*wubi*` paths as restricted data even when the file is only the upstream license.
- Regression: `test_publish_failure_restores_existing_wubi_artifacts` forces the metadata rename to fail after the database and license were installed, then checks all three old files are restored and no temporary file remains.
- Verify (验证点): `python3 scripts/build-owltype-msime-seed-db.selftest.py` passes 9/9; `bash scripts/check-public-source.sh` passes with `licenses/wubi86-jidian.LICENSE` tracked.
- The pinned official cache and product-set publishers reuse that same transaction.
  `fetch-msime-resources.selftest.py` injects failure after earlier members were replaced and
  proves resources, manifest and identity record restore byte-for-byte, including removal of
  members absent before publication (2026-10-26).
- Seen on 1 distinct date: 2026-10-25.

### A Rust archive existing is not evidence that it matches Rust source

- The Makefile treated `lib/libowl_msime_ffi.a` as up to date whenever the archive existed, so
  Swift kept linking an old archive after Rust source changed. Four Swift test candidates failed
  together for that one stale build; rebuilding the archive made the suite pass with 1399 tests
  and 0 failures.
- `20b59a1` made the archive depend on a phony `rust-ffi-check` target so Cargo decides whether
  the Rust inputs changed. A real Makefile plus an isolated fake builder showed `old` from the
  previous rule and `new-source` after the fix.
- Verify (验证点): inspect the `rust-ffi-check` dependency in `Makefile`; run the isolated fake
  builder and require `new-source`. The four Swift failures are one stale-archive event, not four
  independent regressions.
- Seen on 1 distinct date: 2026-10-25.

### Process-wide dictionary caches belong to the session lifecycle

- The Rust FFI kept process-wide journal and dictionary caches open after the last session wrapper
  was destroyed. B's real reset reproduced the consequence: a new session learned `尼`, but the
  learning did not reach the reset journal because the new session still used the old cached
  connection. The Swift `finalize()` contract was `Void`, so callers could neither wait for cache
  teardown nor fail closed when a session remained live.
- `owl_msime_engine_finalize()` now returns `false` without touching any cache while a session is
  live, then closes the upstream caches and returns `true` once all sessions are gone. Session
  create takes the read side of one lifecycle lock; destroy and finalize take the write side, and
  destroy holds it through session drop and flush. Swift destroys all wrappers before calling the
  hook. Deploy, user-dictionary reset, and legacy migration stop without deleting or importing data
  when finalize fails.
- Regression: `finalize_waits_for_sessions_and_allows_reopen` in
  [engine_lifecycle.rs](rust/crates/owl-msime-ffi/tests/engine_lifecycle.rs) proves that finalize
  fails with a live session, succeeds twice after destroy, and permits a reopened session; B also
  passed the real FFI reset path (51 focused tests plus the lifecycle integration) before merging
  it. [EngineSeamTests](tests/EngineSeamTests.swift) covers the Swift Boolean lifecycle contract.
- Verify (验证点): `cargo test --locked --manifest-path rust/Cargo.toml --package owl-msime-ffi`
  passes, `make test TEST_ONLY='EngineSeamTests'` passes, and reset/deploy/migration call sites guard
  `finalize()` instead of ignoring it. Real reset acceptance remains distinct from the unit test.
- Seen on 1 distinct date: 2026-10-26.


## Resource activation must preserve auxiliary catalogs and schema-owned keys

- Seen 1x (2026-10-26): PR #272 review found that activating a full dictionary replaced
  the resource root containing the bundled emoji catalog, and custom shuangpin's `;`
  was routed to candidate selection/punctuation before reaching its spelling handler.
- Regression: `OwlRustEngineTests.testActivatedDictionaryKeepsBundledEmojiCandidates`
  and `testShuangpinSemicolonSpellingPrecedesCandidateShortcut` fail on the shipped
  2.1.0 source (seven assertions). They exercise real SQLite/FFI sessions, not UI mocks.
- Fix: stage main dictionaries from the active generation while resolving auxiliary
  resources from the app; publish caret-aware semicolon spelling eligibility from
  Rust and consume it before host candidate shortcuts. Existing generations remain
  immutable and do not need a download to regain emoji suggestions.
- Verify (验证点): run `python3 scripts/verify.py swift --test OwlRustEngineTests`;
  test both shortcut settings, deletion/retyping and visible-candidate commit. These
  checks establish adapter behavior; installed-host timing is a separate measurement.

- 2026-10-26：异步模型配置返回时 worker 可能已从 loading 进入 missing；回归应接受这两种合法即时状态并继续等待/断言 missing。只接受 loading 的测试竞态会在销毁 session 前 panic，连带污染全局生命周期测试。本次 53 个 FFI 单测及 engine_lifecycle 重跑通过。

## Official resource schemas and Wubi composition survive pinyin alignment

- Seen 1x (2026-10-26): adopting the pinned official dictionary set exposed that the resource
  activation contract required Owl's optional `english_words.phonetic` column. The upstream
  database has `word`, `display`, and `weight`; requiring the extra column rejected a valid set
  before activation. Validate the upstream required schema and allow Owl's extra column.
- The same acceptance run exposed two Wubi adapter boundaries: enabling ordinary-pinyin sentence
  alternatives crowded out the prior Wubi partial-selection page, and treating the fifth-key top
  commit as a partial phrase held `工` instead of committing it before the next code. Retain the
  existing Wubi sentence policy and deduplication, and exclude its completed top commit from
  phrase holding. These rules do not change ordinary-pinyin sentence generation.
- Regression and Verify (验证点): `OwlRustEngineTests.testGenerationSwitchRollbackColdStartAndJournalReplayKeepUserState`,
  the existing six Wubi tests, `testActivatedDictionaryKeepsBundledEmojiCandidates`, and
  `testShuangpinSemicolonSpellingPrecedesCandidateShortcut` pass together (9 tests). The FFI
  `pure_wubi_fifth_key_tops_an_ambiguous_four_code` reproduces the missing commit before the
  adapter correction and passes afterwards. This proves the session/resource seam, not IMK installation.

## Verify both keyboard model scoring paths against the pinned host

**A ready model and a changed first candidate do not prove the engine lattice scorer is connected.**

- Reason: after pinning MSIME 0.55.0, the host's existing worker attached the keyboard model to the runtime reranker only. `tadefangjian` changed its first row to `他的房间`, but its later sentence and completion rows differed from the pinned Host API with `neural_keyboard` enabled. The existing settled-selection regression still passed.
- Prevention: hand the same validated worker-loaded model to the existing engine lattice scorer and runtime reranker. Refresh the published candidate identity when weights attach or detach; reattach after engine replacement. Missing, malformed and digest-mismatched models retain the ordinary non-neural candidate order.
- Regression: [model_parity.rs](rust/crates/owl-msime-ffi/tests/model_parity.rs) compares all six model-on/off rows with the pinned Host API oracle, cold/shared-cache sessions, selection, engine replacement, active-composition disable and failure fallback. It failed before the lattice handoff and passes after it. The Swift settled-selection regression uses `tadefangjian`, which the pinned desktop model actually moves with the official dictionary; each digit/token selection path starts with its own learning journal so the first selection cannot pre-promote the second case.
- Verify (验证点): materialize the official seed and locked models, then run `OWL_MODEL_PARITY_RESOURCES="$PWD/data/owl-rime/msime" cargo test --manifest-path rust/Cargo.toml -p owl-msime-ffi --test model_parity -- --ignored --nocapture`; expect one passed test. This checks the C ABI, not installed IMK delivery or pause scheduling.
- Seen on 1 distinct date: 2026-10-26.

## Traditional output follows the pinned phrase converter

- Seen 1x (2026-10-26): platform `Hans-Hant` converted `里面` to `裡面`, while the
  pinned upstream OpenCC standard configuration returns `裏面`. Consistent display
  and commit alone did not establish equivalent output.
- Use the upstream client-core converter through the C ABI for both visible and
  committed text. Keep the original candidate generation and selection identity.
- Regression and Verify (验证点):
  `OwlRustEngineTests/testPhraseAwareTraditionalOutputKeepsSelectionIdentity`
  fails at visible, peeked and committed output before the change, and passes after;
  it also selects with the pre-conversion token and turns conversion off again.

## Smart punctuation requires the native document context

- Seen 1x (2026-10-26): forwarding every idle punctuation key to the engine wrote
  `1。` where pinned macOS MSIME writes `1.`. Engine punctuation alone cannot infer
  the preceding document character or replace a previously committed mark.
- Reuse upstream client-core route/repeat/space-convert policy. The native host owns
  the client/caret fingerprint and checks actual text before replacement. An unreadable
  host may use only its owned shadow; posted replacement remains permission- and
  foreground-checked and cannot run in a secure or explicitly denied client.
- Verify (验证点): `OwlInputHabitsIntegrationTests` covers context and repeat,
  caret movement, immediate setting changes, opt-in space correction/revert and an
  unreadable host through a substituted posting boundary. No real terminal receives
  injected keys. These tests do not establish installed-host event timing acceptance.

## Fresh upstream defaults own ordinary pinyin candidate order

- Seen 1x (2026-10-26): after importing the pinned full dictionary, the real host
  differential still showed nine candidate-order differences. Owl's Chinese-only
  first-page transform hid upstream's exact English seats (`xi`, `chan`), and an
  emoji-off default removed default mixed rows. Host quick-phrase promotion also
  overrode upstream's fresh-install ordinary-mode boundary.
- Keep ordinary ranking in the pinned engine; retain the transform only for explicit
  user pins and Wubi policy. Enable macOS default emoji and static symbol names,
  disable fresh ordinary quick-phrase injection, and retain explicit K-mode access.
- Verify: `tests/fixtures/pinyin-parity/full-pinyin.json` and `mixed-input.json`
  against the unmodified pinned host; `testPinnedUpstreamMixedEnglishAndEmojiOrder`
  and the existing fuzzy/typo/English tests check the Swift session seam. The pinned
  engine treats legal `nihaao` literally; the former fixture's forced 你好 result
  must not be restored by another local correction policy.

## Native host capabilities belong in parity evidence

- Seen 1x (2026-10-26): the strict room trace exposed two boundary-page consumed
  differences. Both adapter layers filtered upstream `handled` through page
  movement, allowing composition-owned page keys to reach the document at an edge.
  Preserve `handled`; `testPaginationAndHighlightNavigation` fails at both boundary
  assertions before the fix and passes afterwards; the 75-event trace is equal.
- A new partial-selection trace also exposed a harness omission: bare
  `prepare_host` does not request macOS `MSIMESessionOptions` capabilities. The
  native profile now records the pinned three boolean overrides and joins
  `phrase_prefix` with `preedit` for native marked text, retaining raw views.
  Preserve `phrase_preedit`; do not remove held selections to fit a bare API trace.
- The same trace caught Left/Right always selecting candidates even at the first
  candidate with an unfinished caret, and Delete being dispatched as Backspace.
  Use the pinned macOS first-candidate/caret rule and `DeleteForward`. The parity
  transport also sends Return for `CommitRaw`, rather than Space selection.
- Verify: replay `editing.json` and `tadefangjian.json` against the pinned native
  host profile; the original raw profile remains explicitly reproducible. These
  checks prove the public session/marked-context contract, not installed IMK delivery.

## Host actions invalidate settled scoring even when the engine does not change

- Reason: a boundary-page action can return unconsumed without changing input or candidate generation. The controller only invalidated its debounce timer, so an already-running desktop score still passed its ticket check and refreshed candidates after that action. Engine identity alone did not cover the host pause lifecycle.
- Fix: capture a host action epoch with each settled job and reject publication after any invalidating host action; continue polling with `accept: false` to return the model. The pinned native host uses the same epoch ownership guard. Keep the existing 150 ms debounce and match its 60 Hz result poll.
- Regression: `testSettledActionInvalidationRejectsAResultEvenWithoutEngineMutation` failed before the fix (`accept` was true and the panel refreshed once), then passed. Controlled-clock coverage proves the 150 ms last-input pause and old-job drain/restart; a separate focus test deliberately retains engine state when clearing. `testSettledPauseUsesRealModelAndKeepsNativeSelectionAndEditsCurrent` connects the production controller, official desktop model, isolated journal and native text client, checking complete candidate order, stale/fresh token and digit commits, backspace, schema switch, focus loss, selection while scoring and page preservation.
- Verify: run `EngineSeamTests` and the named native integration test through the seeded Swift test host, together with existing `OwlRustEngineTests` model/ticket checks. Timer firing and a monotonic clock are controlled; no fixed sleep determines whether a worker result is stale. This checks in-process native host behavior, not installed IMK IPC delivery.
- Seen 1x (2026-10-26).

## Owl enhancement rows are distinct from native quick phrases

- Seen 1x (2026-10-26): treating bare host-api defaults as native macOS defaults would disable
  legitimate upstream quick-phrase candidates. Native `MSIMESessionOptions` enables them; Owl
  template/prompt/custom host rows instead require explicit K plus the complete stored trigger.
- Keep the native database candidate order and K prefix browsing intact. The thin host-table
  adapter switch defaults to upstream behavior; Owl alone disables ordinary host-table injection.
  Preserve stored content and codes, and strip the explicit mode prefix only when resolving an
  Owl invocation. Partial host triggers must never publish internal invocation markers.
- Regression: `OwlRustEngineTests.testOwlEnhancementsRequireExplicitKWithoutChangingOrdinaryCandidates`
  compares real ordinary candidates with/without a template, checks partial/full K triggers,
  visible commits, cancellation and return to ordinary input. Prompt interception and existing
  host delivery tests cover context, stale targets and single delivery.
- Verify (验证点): `cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi` and
  `python3 scripts/verify.py swift --test OwlRustEngineTests --test OwlPromptInterceptionTests
  --test OwlTemplateHostDeliveryTests` pass. These are isolated automated sessions, not installed
  IMK or live-provider acceptance.

## Learning parity must cross a process boundary and reach a real consumer

- Seen 1x (2026-10-26): T09 found that upstream `RemoveCandidate` had no Owl FFI or
  native consumer. Selection learning already worked, but a session-only reopen
  could still observe a process-wide dictionary cache instead of journal recovery.
- Fix: validated visible candidate tokens reach upstream removal from the existing
  context menu and macOS Ctrl-Option-Shift physical digits 1–8. Stale menu tokens
  and preview/punctuation identities are rejected. Single-character/source
  protection stays in the upstream engine.
- Regression: `testCandidateDeletionUsesPhysicalChordAndRejectsOldMenuToken` drives
  the controller shortcut/menu into a real session; `removal_uses_current_visible_identity_and_survives_reopen`
  covers the ABI. `tests/fixtures/pinyin-parity/learning.json` compares every page
  before/after selection, deletion and two restarts in fresh processes per endpoint,
  with independent checkpoints for the actual learning and recovery effects.
- Verify: run the learning fixture through `scripts/pinyin-parity.py` against the
  pinned reference library/resources, the named Swift test, and
  `cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi`.
  This proves the offline host seam; installed IMK acceptance remains separate.


## A parity trace must identify the input scheme it actually ran

- W01's inherited differential exporter always selected `rime_ice`; a Wubi request could therefore produce a valid-looking Pinyin export with the current run nonce. Selecting a requested scheme must succeed before export, and the runner must reject a returned configuration for another scheme.
- Regression: `ExportTransportTests.test_export_from_another_scheme_fails` failed before this check and passes after it. The real Wubi trace uses the existing Swift session and pinned MSIME Host API, retaining candidate and paging differences rather than ignoring them.
- Verify (验证点): `python3 scripts/pinyin-parity.selftest.py`; the exported `configuration.schema` must equal the requested schema. This is transport validity, not evidence that Wubi behavior is aligned.
- Seen on 1 distinct date: 2026-10-26.

### Resource delivery checks follow the approved split dictionary and auxiliary catalog

- Seen 1x (2026-10-26): Wubi parity resource assembly exposed two stale delivery assumptions:
  Wubi86 was required inside the pinyin database, although the fixed official release splits
  86/98 into `msime-wubi.db`; the approved MIT kaomoji restoration was rejected by an old
  emoji-only allowlist. The actual seed was valid but the delivery checker rejected it.
- Keep the split Wubi file and both nonempty tables required. The auxiliary exact-table
  contract includes emoji and the two MIT kaomoji tables recorded in
  [the retained notice](data/msime-others-NOTICE.txt); `symbol_catalog` remains forbidden.
- Regression: the existing complete-resource fixture now uses split Wubi and the approved
  four-table auxiliary catalog. It failed before the checker update and passes afterward;
  forbidden-symbol and unknown-table rejection regressions still pass.
- Verify (验证点): `python3 scripts/check-rust-delivery.selftest.py` passes 9 tests; run the
  checker against the actual generated resources before treating a fixture pass as packaging evidence.
## FFI session identity cannot be an allocator address

- Seen on 1 distinct date: 2026-10-26. The default-parallel FFI suite aborted with
  `POINTER_BEING_FREED_WAS_NOT_ALLOCATED` while dropping a refreshed `EngineSnapshot`.
  The guard was a set of live Box addresses: after one test destroyed its session,
  another session could reuse that address. The first test's idempotent destroy and
  post-destroy calls then targeted the new session. Checking membership before a bare
  dereference also did not preserve ownership across the call.
- Fix: non-recycled opaque identities resolve through a thread-local owning registry.
  The engine's existing thread confinement is preserved; stale and foreign-thread
  handles fail closed. Async host tests must remain on MainActor across awaits when
  retaining a session, matching the production IMK thread contract. Destroy and thread
  exit drop/flush sessions under the lifecycle
  lock before retiring active identities, so finalize cannot close a live cache.
- Regression: `destroyed_handle_cannot_alias_a_reopened_session` reaches the real
  create/destroy/reopen FFI path and fails on the previous source in 0.05 seconds:
  stale destroy removes the reopened session. `session_rejects_foreign_thread_calls_and_destroy`
  guards the owner-thread boundary; `finalize_waits_for_sessions_and_allows_reopen`
  also covers host-thread exit with an unclosed wrapper.
- Verify (验证点): `cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi`
  must pass with the default parallel runner. Repeat with AddressSanitizer when
  investigating memory regressions; a successful ordinary retry alone is not evidence
  that an observed invalid free has been resolved.

## Resource activation must capture the complete compatibility set

**A resource generation includes auxiliary dictionaries, context sidecars, models and the binary's configuration version; each session captures that generation for both dictionary and model loading.**

- Reason: the parity update audit found the production updater still rebuilding reduced Pinyin from legacy YAML. Activation switched only the main/English databases while session creation and model configuration kept reading the current bundle. A synthetic activated emoji database returned bundled apples instead of its own candidate; the focused host-seam regression failed before the fix.
- Prevention: production preparation copies the binary-pinned complete resource set into the existing transaction. Activation and rollback validate the whole manifest and configuration/model compatibility. Session model and auxiliary paths belong to the captured generation. A missing/corrupt active member falls back to a fully verified previous combination, then the bundled seed if none is usable; incomplete generations are never supplemented member-by-member.
- Regression: `testActivatedGenerationUsesItsOwnAuxiliaryResources`, `testProductionUpdatePreparesTheCompletePinnedCombination`, `testIncompleteGenerationCannotOmitAuxiliaryResources`, and `testGenerationSwitchRollbackColdStartAndJournalReplayKeepUserState` in `OwlRustEngineTests` cover actual sidecar candidates, official model scoring with unavailable bundle models, complete preparation, interrupted activation/retry, missing/corrupt sidecars, rollback, and learning replay in isolated roots.
- Verify (验证点): run those focused Swift tests and `OwlRustResourceTransactionTests`; the synthetic candidate changes with the active generation and returns after rollback, while the learned candidate remains first. Future binary/model/config changes must advance the compatible package/configuration version together. No old-user migration is implied.
- Seen on 1 distinct date: 2026-10-26.

## Preserve lint failure status when reviewing merged source

- Seen 1x (2026-10-26): T04 segment routing raised `OwlRustSession.process` complexity to22. The merger reported lint clean after searching `error:` even though the configured GitHub reporter writes `::error`; later shell commands also masked its failure status. T12 correctly surfaced the blocker.
- Fix: extract the existing segment-chord route into a dedicated private helper, preserving active-composition/modifier guards and false-versus-not-applicable behavior. Run lint as its own command and inspect both exit status and reporter errors; do not infer success from a later command. No lint configuration was relaxed.
- Verify: `swiftlint lint --quiet` exits0 with no `::error`; existing `testSegmentChordEditsPinyinRatherThanPassingToHost` and `testShuangpinSegmentEditingAndShoudaoSelection` still pass. This fixes the source gate, not installed IMK acceptance.

### Wubi lookup goldens follow the pinned native suffix query

- Seen 1x (2026-10-26): preserving Owl's former full-z-spelling lookup kept `zi → 子`,
  but fixed native 0.55 only queries the suffix `i` and returns no candidates.
  Spec #294 supersedes the earlier instruction to retain this local difference.
- Restore the pinned suffix-only query and original two Wubi golden files. A real
  session checks `zi`, the `zhai → 海` code annotation, and that selecting a lookup
  row does not promote it in the subsequent Pinyin query.
- Verify (验证点): `testWubiZLookupUsesOnlyNativeSuffixAndDoesNotLearnPinyinFrequency`
  and the two `wubi_mixed_*` scripted golden scenarios, with strict fields retained.

### Preserve native Wubi candidate rows and phrase selection

- Seen 1x (2026-10-26): the real Swift mixed-Wubi trace differed from pinned
  MSIME 0.55.0 at 39 fields. Owl disabled sentence alternatives in Wubi and removed
  repeated visible words across distinct code rows, changing candidate positions
  and partial selection. After restoring those upstream paths, fifth-code handling
  still committed the selected prefix early instead of holding it in native
  phrase preedit.
- Fix: keep the upstream sentence-alternative default and mixed candidate merge;
  retain Pinyin-specific dedup. Restore the runtime selection predicate shared by
  native fifth-code handling. Direct Host API probes confirm pure fifth-code
  continuation holds the prefix with either flag; mixed continuation does so only
  when enabled, and refuses the invalid continuation when disabled.
- Verify: `tests/fixtures/wubi-parity/wubi86-mixed.json` through the actual
  Swift/reference differential seam, plus existing Swift commit-preference,
  mixed-code-row selection and pure ambiguity tests. Installed IMK acceptance is
  outside these isolated-source observations.

### Compare learning defaults through selection and restart

- Seen 1x (2026-10-26): Wubi's Swift preference and FFI constructor defaulted
  learning off although pinned MSIME 0.55.0 defaults it on. The actual Swift/native
  53-event selection, personal phrase, deletion and process-restart trace exposed
  33 differences: 五一 stayed behind王 and new你尼 was absent at codewqnx. The
  focused Swift and FFI selection/reopen regressions independently failed.
- Fix: align the absent preference, initial settings state and FFI default;
  preserve an explicit false and reuse upstream per-code/profile learning,
  reverse-lookup guard, shared journal and generation replay. The remaining
  `nin` difference after learning came from another Owl fork: once a journal
  exists, native fixed-position processing restores Wubi-first producer groups,
  while Owl preserved decoder Pinyin-first order. Restore only that Wubi branch;
  leave general Pinyin positioning unchanged. No new algorithm, reset or migration.
- Verify: `tests/fixtures/wubi-parity/learning.json` through strict native/Swift
  replay; `testWubiLearningDefaultsToNativeAndPreservesExplicitOptOut` and
  `wubi_learning_default_persists_native_selection`. The final combined Wubi98
  path is checked after its schema/profile plumbing is integrated.

## Native parity includes the controller and marked-text host

- Seen 1x (2026-10-26): strict session traces did not exercise controller shortcut
  passthrough or the native host's paired punctuation. Command/ordinary Control/Option
  left a live conversion behind; pairing used the old insert-and-move convenience.
- Native pinyin now finishes through pinned runtime `Action::Finish` before returning
  application chords, while dedicated IME shortcuts and segment editing keep ownership.
  Pairing follows the pinned macOS host: committed opening, marked closing tail,
  closing on commit/focus, and fresh quote opening despite engine alternation.
- Regression and Verify (验证点): run `python3 scripts/verify.py swift --test
  OwlInputHabitsIntegrationTests --test OwlAutoPairTests --test KeyTranslationTests`.
  The native tests drive actual controller → Rust → NSTextView and failed before the
  fix. Session-only differential evidence cannot substitute for this boundary.
- The differential runner now owns a separate temporary DerivedData tree and calls
  `cleanup_app_registrations.prepare` before removal and after removal, also on failure
  or interruption. `python3 scripts/pinyin-parity.selftest.py` preserves caller data
  and fails closed when unregistering fails; JSON evidence stays outside that tree.
- Explicit product exception: slash-to-English remains an Owltype feature per the
  user's current decision. No unlicensed symbol catalog was imported.
### Test hosts must not share a persistent preferences domain

- Seen 1x (2026-10-26): the real settled-model oracle intermittently saw eight
  candidates after explicitly setting six. Every worktree used the fixed
  `im.owltype.inputmethod.Owltype.tests` suite; another test host's settings baseline
  writes eight. Main-actor isolation does not isolate CFPreferences across processes.
- `test-defaults-isolation.selftest.py` compiles the actual `OwlDefaults` selector
  and runs two Foundation processes with page sizes six and eight. Before the fix
  they publish the same suite and the first process reads the peer's eight.
- Give each test/UI-test process a unique suite and remove it on normal exit.
  Synchronize domain removal and remove its exact UUID plist on exit: a removed
  domain can remain observable as `{}`, and a `defaults read` observer can itself
  recreate an empty plist. Verify the file before reading and require the saved
  key to be absent. The first cleanup assertion was initially misreported green;
  independent review caught it before integration.
  Production preferences still use `UserDefaults.standard`. The existing exact
  six-row model oracle and its page-size precondition remain unchanged.
- Verify: `python3 scripts/test-defaults-isolation.selftest.py` passes; the real
  model/controller regression must also pass through the ordinary native host.

### A split resource file needs the native resource schema contract

- Seen 1x (2026-10-26): W02 correctly published original split `msime-wubi.db`,
  but the shared legacy engine-resource descriptor still required `wubi86` in
  `msime-pinyin.db`. The existing complete-resource test failed while building
  the real official package, before any activation, with missing-tablewubi86.
- Fix: retain the legacy merged/custom descriptor and derive the production
  native descriptor from its common requirements, locating both86/98 tables in
  the split role. The fixed native configuration also pins the official Wubi
  resource digest, like its existing model pins: a self-consistent manifest with
  an empty98 table cannot claim native alignment.
- Verify: actual official production prepare/activate, a self-digested empty98
  rejection, and the existing generation lifecycle extended with86/98 candidates
  and shared-journal replay before update, after update, recovery and rollback.
  The legacy builder retains its own merged contract. Bare Xcode test hosts have
  no full SharedSupport payload; offline production-factory tests explicitly
  supply the pinned seed, without treating that fixture omission as product proof.
### Native capabilities and fresh preferences are different controls

- Seen 1x (2026-10-26): the native macOS `quick_phrase_candidates` capability is
  true, but pinned 0.55 `MixedInputPreferences::default()` sets `quick_phrase`
  false. Treating capability as preference hard-enabled ordinary dictionary
  phrases; all seven official codes produced 14 candidate-order differences.
- Keep the shared fresh default OFF for Pinyin and Wubi; explicit ON follows
  the pinned pre-mixing insertion/counting rules for both. Wubi must not retain
  #307's post-mixing visible-seat exception under #294. Neither disables K
  browsing or Owl's explicit AI/template entry. A live toggle queues until the native runtime is idle, preserving the current
  raw composition and IDs; the next composition applies the preference.
- Verify: replay `native-quick-phrases.json` and `native-quick-phrases-on.json`
  against native-mac-host. The ON corpus selects all eight official rows and
  requires deduplication of the existing dictionary `yyds` row. Keep all six
  earlier corpora, Wubi regressions and the normal gates; do not waive an ON
  mismatch with the OFF group. See `testNativeQuickPhrasePreferencePreservesLiveComposition`.

## Delivery and acquisition share the licensed resource contract

- Seen 1x (2026-10-26): final Release validation still rejected `kaomoji` and
  `kaomoji_catalog` after the seed importer had accepted their fixed MIT data and
  bundled the original license. Provenance and generated seed metadata still said
  emoji-only, and the SBOM regression still excluded the retained source component.
- The delivery checker now reuses `fetch-msime-others.py`'s exact four-table,
  row-count and canonical-content-hash contract and pins the kaomoji MIT text and
  source notice. `symbol_catalog` and unknown tables remain forbidden. Metadata
  names the licensed retained subset without licensing the complete upstream DB.
- Verify (验证点): `python3 scripts/check-rust-delivery.selftest.py` rejects missing,
  empty, added or changed kaomoji rows and missing/modified attribution;
  `python3 scripts/release-bundle.selftest.py` verifies its SBOM component and
  pinned license. Run the real `scripts/check-rust-delivery.py` against the Release
  App as well; passing synthetic fixtures alone cannot establish shipped content.

### Legacy resource fixtures must use the product's split-Wubi generation preparation

- Seen 1x (2026-10-26): the final gate's FFI library suite had54passes/3failures.
  The seed smoke test called the legacy Pinyin/English constructor without a
  Wubi resource root; migration fixtures directly copied those two databases
  and skipped split-Wubi assembly. The official seed was present, including
  Wubi86=126078 andWubi98=135372; skipping missing resources was not the cause.
- Production `OwlUserMigrationImport.prepareGeneration` already creates the
  complete generation before calling the importer. Align only the test fixtures
  and their reset/session helpers with that public generation path. Keep every
  original migrated-row count, idempotence, learning/reopen, replaced-journal
  inode and rollback assertion; do not change the migration algorithm or weaken
  distinct-root validation to accommodate an obsolete fixture layout.
- Verify: `cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi
  --lib` passes57/57 with verified official split dictionaries. This is isolated
  fixture coverage, not a production-data reset or a new full-gate pass.


## Public dictionary scanner collisions require content proof

- Seen 1x (2026-10-26): the final artifact scan's Eraser detector matched the
  adjacent serialization of one public English word and its identical display
  column in the unchanged official dict-v2.0.24 English DB. The hit was unverified;
  the complete DB matched the pinned official manifest and the match was not a
  standalone database cell. No matched bytes were printed or retained in evidence.
- The shared policy permits only that exact artifact/TruffleHog/Eraser unverified
  finding, with both the raw-match digest and complete public-file digest pinned,
  the expected App resource location, and a read-only same-row word/display proof.
  This does not exempt the DB/path, the detector or generic keys. Modified DBs,
  different raw matches/detectors, history and verified/unknown findings still fail.
- Verify (验证点): run `python3 scripts/secret-finding-policy.selftest.py`, including
  positive/negative public-row cases and unchanged generic-key/container checks,
  then `scripts/check-secrets.sh --artifacts` on the actual built App. Keep only
  hashes, classification, source identity and redacted scanner decisions as evidence.


## Scan one validated view of an inert package payload

- Seen 1x (2026-10-26): the formal Release PKG scan extracted the inert App ZIP,
  then scanned the original ZIP too. TruffleHog's recursive archive result named
  only the ZIP, so the strict public-dictionary exception correctly could not
  prove its exact DB bytes and same-row content. Do not extend that exception to
  an archive or waive a detector/path to compensate for the duplicated view.
- In disposable scan trees only, the existing staged-package checker validates
  every ZIP member/path/link and a complete ZIP32 layout. All member bytes are
  CRC checked with full compressed-stream consumption; internal link targets
  and AppleDouble members become ordinary scan files, and comments, extra fields
  and header metadata are retained in a scanner-visible text-named file. Prefix,
  trailer, gap, overlap, duplicates, corrupt CRC and unsupported layouts fail closed.
  Remove the temporary original only after the complete scan view exists.
- Outer package scripts and Distribution remain scanned. DMGs stay read only;
  their owned scan copy expands nested PKGs through the same path. Ordinary ZIPs
  are retained. Temporary App registrations are checked before and after cleanup.
- Verify (验证点): `python3 scripts/check-staged-pkg.selftest.py` checks full
  content/metadata coverage, rejection boundaries and real generic-key detection
  in seven layers. Run `secret-finding-policy.selftest.py` and the actual artifact
  gate on installer PKG, update PKG and DMG; retain source artifact/receipt hashes
  before and after. Product tests/builds alone do not establish this gate.
## Progress snapshots must paginate PR commits as well as files

- Seen 1x (2026-10-26): PR #309 reached141 commits; its files fit one page, but
  the old commits(last:100) query correctly failed closed and could not refresh.
- Read both connections completely, validating counts, unique rows and advancing
  cursors. Fence every page and the final read with the same PR head and base.
  Other bounded connections still reject truncation before writing any page.
- Verify (验证点): `scripts/progress-sync.selftest.py` covers141 commits/151 files,
  head/base drift, empty/error/duplicate pages and cursor failures; it runs in the
  existing portable_scripts gate. A rejected snapshot preserves prior output.

## Preserve metadata adjacency and cleanup ownership on failed expansion

- Seen 1x (2026-10-26): joining ZIP header/name/extra/comment fields with newlines
  split a synthetic generic key across adjacent central extra/comment fields.
  The real Gitleaks regression returned clean before the fix. Keep each ZIP
  record contiguous in the scan view; separators belong only between records.
- A failed pkgutil expansion may already leave partial App bundles. Mark the
  disposable tree as App-owning before expansion, so failures still use the
  exact registration cleanup. If DMG detach fails, retain the tree and fail
  before removing anything inside the still-mounted image.
- Verify (验证点): staged-package real-scanner extra/comment boundary case and
  secret-policy partial-expansion shell regression pin these failure paths.

## Prove corresponding-source context before applying a public DB exception

- Seen 1x (2026-10-26): the formal corresponding-source TAR correctly retained
  the full App seed, including the official English SQLite dictionary. Its known
  unverified Eraser row-pair match was rejected because the existing exception
  required an App resource location. Do not remove seed data or turn the DB
  digest, detector or source-looking path into an exception by itself.
- Reuse the release source validator to bind the original TAR to its cohort,
  canonical archive metadata, Git source, App seed and source manifest. Bind the
  actual scanner extraction to those same source/seed fingerprints before
  accepting only its exact dictionary location. Retain all existing finding,
  official DB digest and read-only same-row SQL predicates. This content proof
  does not authorize a release or allow reuse of a cohort after a new commit.
- Verify (验证点): `secret-finding-policy.selftest.py` builds a real Git/cohort/TAR
  fixture and rejects forged context, changed DB/manifest/output digest, verified
  or other findings, history and other locations. Run the actual source TAR
  scanner red/green and compare original artifact/cohort hashes before and after.

## Settings must preserve selected phrase progress until idle

- Seen 1x (2026-10-30): #358's real engine regression selected `你好`, left raw suffix `wo`,
  then changed Wubi wildcard and continued with `men`. The old settings path lost the selected
  phrase and returned `men`, without the `我们` candidate. A controller regression also showed
  settings/onboarding schema selection clearing `nihao` before the idle guard.
- Preserve both engine option eligibility and native session refresh timing. Replaying only
  `rawInput` cannot reconstruct a selected phrase prefix. Settings/onboarding schema changes
  enter the same idle queue; explicit host/menu schema effects remain immediate.
- Verify (验证点): `EngineRuntimeTests/testKeyboardApplyPreservesCompositionUntilIdle`,
  `OwlRustEngineTests/testMixedWubiPartialPhraseSelectionContinuesInPinyinTail`, and
  `OwlInputHabitsIntegrationTests/testControllerRoundTrip` exercise the real App/input seam.
  Check continued commit `你好我们` and eventual idle drain. PR #369's exact-head gate
  `f0c3240620cbe2aecc483db4409a18cd29087e41` passed 1470 Swift tests (1 designed skip).
  Evidence establishes isolated native/engine behavior, not installed-host acceptance.

## Template migration must retain canonical Unicode equality and derived readiness

- Seen 1x (2026-10-30): #359's first native FFI run split canonically equivalent `é` and
  `é` names into two parameters. Rust byte equality also disagreed with Swift for defaults,
  options and supplied keys. Use ICU NFC only for comparison; retain authored and inserted bytes.
- The same run exposed two transport seams: internally tagged serde requests cannot decode
  numeric-key maps from their buffered JSON content, and invocation wrappers reconstruct
  Evaluation values. Keep temporal-fact keys as strings and readiness derived by Rust for
  every Evaluation, including reconstructed ones.
- Verify (验证点): `OwlTemplateEngineTests/testCanonicalUnicodeParameterIdentityAndOptionsAcrossRustBoundary`
  must merge the names and accept decomposed option values. Existing invocation, temporal,
  clipboard and cursor suites must still deliver through the real Swift→Rust seam.
  `testOversizedTemplatePayloadBlocksWithoutCrashing` checks parser and renderer rejection
  as diagnostics instead of ABI precondition crashes. These are isolated App-host checks.

- The independent #359 review also found ICU dot's VT/FF exclusions missing from the
  legacy regex, turning multiline literals into empty substitutions, and a readiness request
  that resent the whole expanded preview through the 4 MiB input limit. Existing legacy and
  transport tests now replay both failures, including a small request producing 5,000,000
  output bytes. Send only compact readiness facts; a request limit is not an output limit.

## Preserve automatic-index error precedence across the App ABI

- Seen 1x (2026-10-30): the #360 migration initially compared all trigger pairs before
  building an index. Equal triggers with immediate expansion then reported a prefix conflict,
  while the existing public seam requires duplicateTrigger. Five assertions in
  `OwlAutomaticExpansionTests/testPrefixValidationDependsOnShorterModeInBothInsertionOrders`
  failed. Rust now builds the actual trie and checks terminal duplication before descendants;
  Swift decodes its immutable nodes without maintaining another conflict rule.
- Verify (验证点): run that existing App-host test through `scripts/verify.py swift`.
  Both insertion orders and all expansion modes must retain the original typed error.
  This is isolated regression evidence, not installed keyboard acceptance.

## Storage migration must retain Foundation text classes and read isolation

- Seen 1x (2026-10-30): #360 review found Rust's default whitespace set omitted U+200B,
  changing empty-content rejection, legacy code normalization and empty queries. It also
  found `.lines()` missed CR/VT/FF/NEL/LS/PS in the orphan prompt-table audit, allowing
  activation without the missing JSON bodies. Two real App-seam regressions reproduced
  10 failed assertions before the fix. `foundation_text` now supplies the original three
  CharacterSet contracts; parser, stores, editor and picker share them.
- The same migration exposed a read path bypass: `currentLibrary` could return staged JSON
  while another thread held the write transaction. The concurrent public-read regression
  failed before Rust mode/load/current acquired a native process-lock effect. Read locks
  create no directory/file and acquire no cross-process flock; pure candidate/picker
  operations do not wait on this storage lock. The native call defer releases both lock
  kinds after errors or ABI-contained panics, using the acquired canonical directory key.
- Verify (验证点): run `OwlTemplateStoreTests/testFoundationWhitespaceIsPreservedAcrossLibraryAndLegacyBoundaries`,
  `OwlTemplateMigrationTests/testOrphanPromptTableWithCarriageReturnCannotActivateAnEmptyLibrary`
  and `OwlTemplateStoreTests/testConcurrentCurrentLibraryReadWaitsForTheCompleteSave`
  with `scripts/verify.py swift`. Existing save/recovery and Unicode-template suites must
  remain green. These synthetic fixtures do not establish installed-host acceptance.

## Preserve the caller's session and wrap optional session replies

- Seen 1x (2026-10-30): the #363 raw-stream prototype created a new URLSession from the
  caller's configuration. The existing global URLProtocol recorder did not intercept that
  session: one request containing only the synthetic `sk-test` reached the provider and was
  rejected with 401. No personal key was read or sent. The run was stopped immediately.
- Keep the caller's URLSession and forward AsyncBytes without decoding UTF-8 or parsing SSE.
  The existing recording table now injects an ephemeral session with an explicit protocol
  class into the real streaming and search clients; socket replacement is no longer implicit.
  Its allowlist rejects unknown URL/method pairs locally. The existing table also caught
  the native encoders' different decimal representations: retain the Rust-selected original
  codec so both canonical bodies and Content-Length remain unchanged.
- The same run found a nullable probe digest returned at the top of a session value. The
  native session envelope treats a missing/null value as an ABI error; wrap the optional
  digest in an object. The digest stays in Rust, never the key.
- Verify (验证点): `OwlLLMStreamingRecordingTests` must match every existing recorded request;
  `OwlProviderRegistryTests` must complete staged-key saves with and without a prior probe.
  `OwlResponsesStreamingClientTests/testRawByteBoundariesAndCancellationReachRustParser`
  verifies arbitrary UTF-8 splits and terminal cancellation through the real session ABI.

## Provider changes must retire an active AI request

- Seen 1x (2026-10-30): the #364 migration audit found no event connecting provider
  configuration writes to an already-streaming conversation. The isolated
  `testProviderConfigurationChangeRetiresTheOldStream` reproduced an old answer
  becoming `done` and entering history after the configuration-change notification.
- Successful native profile writes now emit a notification after the Rust transaction
  returns, including the write-landed-before-error case. Conversation sessions retire
  their generation and preserve any already-visible partial answer. Replacing the AI
  window model also tears down the previous session. Native Task cancellation remains
  an execution optimization; Rust independently rejects retired callback generations.
- Verify (验证点): `OwlAIConversationModelTests` covers the provider-change regression
  and late deltas/completion/failure through the owned App session ABI. Existing stop,
  regeneration, explicit context and history-limit tests remain the feature seam.
- Scope: isolated notifications/streams and real App FFI, with no real provider key,
  account, installed input method or network request. This is not live-account evidence.

## Explicit AI text is not a bounded control event

- Seen 1x (2026-10-30): independent #364 review found that selections, questions and
  model results above the ordinary 4 MiB event bound reached the native ABI precondition
  before Rust could apply content limits. This was a source-review finding; the failing
  fatal path was not run against an installed input method.
- AI text now enters through owned session snapshots, like existing template-library
  snapshots. Small control events reference the snapshot; the ordinary event bound
  remains intact. Rust applies the original per-feature limits and owns admission.
- Verify (验证点): existing context and conversation suites exercise a 4.5 MB selection,
  question, structured result and streamed answer through the real App ABI.

## Typesetting fingerprints must retain multi-scalar letters

- Seen 1x (2026-10-30): independent #364 review found that a single-letter regex omitted
  Indic conjuncts, decomposed Hangul and letter-plus-joiner graphemes, allowing changed
  text to have an empty matching fingerprint. Native read-only Character checks confirmed
  the mismatch.
- Keep the whole grapheme whenever any scalar is alphanumeric, and compare canonical
  normalized fingerprints. This conservatively protects letters without a script whitelist.
- Verify (验证点): the existing typesetting suite checks those multi-scalar forms and
  distinguishes changed Hangul; the formatter's existing no-content-change tests remain.
- Scope: synthetic text and App FFI tests, no account, network or installed UI acceptance.


## Resource migration keeps typed errors and byte-identical recovery records

- Seen 1x (2026-10-30): the #365 App ABI migration initially wrapped resource domain
  errors as template errors; the existing stale-prepared and same-version-conflict
  tests caught both mismatches. Keep domain error projection before the shared
  storage host's fallback mapping.
- The same migration's existing deterministic-stage test, extended with the prior
  Foundation encoding contract, found a 1507-byte Rust manifest where the prior
  encoder produced 1538 bytes. Staging compares bytes, so equivalent JSON would
  reject an existing completed stage as a collision. Preserve colon spacing, empty
  container newlines, sorted keys and final newline in the Rust writer.
- Native scan errors are stable diagnostic facts, not randomly generated ABI error
  tokens: they participate in the migration request digest. Preserve native decode
  diagnostic text for malformed pin JSON for the same reason.
- Verify (验证点): `OwlRustResourceTransactionTests` and
  `OwlUserMigrationTests/testStagingIsDeterministicAndRepeatedPreparationReusesIt`
  exercise the public Swift→Rust boundary with isolated files. No installed user
  resources or personal journal were read, migrated or reset.

- The first complete #365 gate also found `scripts/msime_pin.py` still checking
  the removed Swift literals. Move the existing pin-consistency check with the
  Rust catalog owner; a focused runtime pass alone does not cover repository
  maintenance scripts. The original gate failure is retained in its receipt.

## Status-panel preferences must use the test-isolated defaults owner

- Seen 1x (2026-11-02): local installer preparation at 480471d ran 1503 tests
  with two assertions failing in `OwlInputHabitsIntegrationTests/testControllerRoundTrip`.
  The user's status panel was disabled; direct `UserDefaults.standard` reads escaped
  the existing test suite isolation. A separate CFPreferences home did not isolate it.
- Route status-panel reads and writes through `OwlDefaults.standard`, which retains
  standard defaults in production and uses an empty process-specific suite in tests.
- Verify: the existing controller round-trip test passes with the user's real panel
  preference still disabled. Full release validation remains required for each artifact;
  this regression is not first-install or real typing acceptance.

## Acceptance fixtures must not enter the daily input method

- Seen 1x (2026-11-02): #362 installed-host acceptance left `;;owlnative362` in the
  user's template library and automatic expansion enabled; a separate `test 1.0`
  status call remained in the daily Agent log. The user found both in normal settings.
- Test hosts previously isolated preferences but defaulted file storage to the real
  user root unless callers supplied both environment overrides. Test/UI hosts now
  allocate private data/log subdirectories automatically; explicit roots also isolate
  preferences and reject production overlaps. Personal Keychain entry points refuse
  test-host access. Caller-owned fixtures stay caller-owned; automatic roots are
  removed on normal exit. Abrupt process death can leave a system-temp directory.
- Installed typing/MCP acceptance requires a separate macOS test session; a settings
  preview is not typing evidence and a data override alone does not isolate IMK/helper
  routing. See [acceptance isolation](docs/operations/installation.md#acceptance-data-isolation).
- Verify: `scripts/test-defaults-isolation.selftest.py` exercises real Foundation
  processes, default/explicit roots, symlink overlap rejection, independent preferences
  and cleanup. `OwlAgentSettingsTests` exercises template storage in the App test root;
  `ProviderProfileStoreTests` verifies rejection before personal Keychain calls.

## Agent access must share the test-isolated preference owner

- Seen 1x (2026-11-02): after the storage-isolation change, the Agent switch getter,
  setter and default service initializer still used Foundation's standard domain.
  The new default-path regression reproduced a read escaping the test suite. It
  deliberately checked both read states before attempting any default write, so
  the failing run did not modify the daily switch.
- Route all three defaults through `OwlDefaults.standard`. Production retains its
  existing domain; XCTest, settings previews and explicit test roots use the isolated
  suite. Keep explicit dependency injection for bridge/transport fixtures.
- Verify: `OwlAgentSettingsTests/testDefaultAgentSwitchAndServiceUseIsolatedPreferences`
  toggles off/on/off through the default setter, checks default service admission,
  and compares the daily persistent domain after each transition. The existing
  bridge switch test checks listener start/stop. Confirm the isolated suite is
  removed after the host exits; never seed the user's daily preference for a red run.

## Retired voice callbacks and buffered command input must preserve the next operation

- Seen 1x (2026-11-03): post-release review of 2.4.0 reproduced old ASR cancellation
  stopping a new recording, and an old polish error inserting its raw transcript into
  the new target. Cancellation alone does not retire a transport callback. The voice
  coordinator now checks a recording generation after suspension and in error, audio,
  permission and timer callbacks before changing state or writing text.
- The same review reproduced `//x` becoming `///x` and Command/Option/Control chords
  discarding a buffered `/` or `/a`. Flush the previous prefix exactly once and consume
  any new slash still owned by the command detector; flush before passing chords on.
- AI association and Jev reranking requested an empty host range. Read a bounded UTF-16
  range before the selection/marked composition under the existing capability policy,
  and keep unavailable or document-start context empty.
- Verify: the six regressions added to `OwlVoiceInputIntegrationTests`,
  `OwlAIWindowWritebackTests` and `OwlAICandidateTests` failed on the original code.
  The five related suites then passed 134 tests after the fix. Tests use suspended fake
  transports and synthetic IMK clients through the App test host; they do not establish
  real microphone, provider-account or installed input-method acceptance.

## Kotone socket v1 reply model must enforce whole-group candidate invariants and preserve safe failure codes

- Seen 1x (2026-11-03): `JEVReplyModel` in `sources/UI/JEVReplyPanel.swift` previously accepted any non-empty candidate array without checking the 2–3 count, trimmed uniqueness, or 2000 Unicode scalar limit, treated `status: "needs_clarification"` (empty candidates) as a generic failure, and collapsed all `ok: false` responses into `JEVTransport.Failure.invalid`.
- Enforce the Owltype v1 compatibility table in `JEVReplyModel.validateAndExtractCandidates`: handle `status == "needs_clarification"` with empty `candidates` as a clarification prompt, accept missing `status` as legacy `ready` and missing `source` as legacy v1 request-bound compatibility (while rejecting `null` or mismatched `source`/`status`), require 2–3 unique non-empty trimmed candidates of at most 2000 Unicode scalars (rejecting the entire group on any violation), and map allowlisted `ok == false` codes (`paused`, `scenario_disabled`, `request_invalidated`, `model_quota_exhausted`, `model_rate_limited`) to local static messages without echoing provider text.
- Verify (验证点): `python3 scripts/verify.py swift --test JEVReplyModelTests` passes all v1 compatibility, safe error code, and late cancelled response cases.

## Reply candidates need a total deadline and revocable copy ownership

- Seen 1x (2026-11-02): the optional reply client accepted one, four, duplicate and blank
  candidates. The new public-model regression failed four assertions before enforcing the
  shared 2–3 distinct-text contract. It also had no explicit copy effect and disabled editing
  while generation was running, preventing the requested mid-flight correction.
- Copy now requires a current candidate and writes only on the explicit button action.
  Editing, cancellation and closing retire its request identity. Nonblocking socket I/O
  uses one monotonic deadline; a service sending intermittent bytes cannot reset the limit.
- Verify (验证点): `python3 scripts/verify.py swift --test JEVReplyModelTests --test JEVTransportTests`
  covers candidate admission, a private pasteboard, an old response released after a new
  result, real-socket cancellation/deadlines and ordinary pinyin after service unavailability.
  `bash scripts/live-test.selftest.sh` keeps the local-service profile restricted to its own
  live suite without weakening other providers' credential and skip-as-failure checks.
- Scope: isolated native model, real socket and engine tests. Installed selection, focus,
  shortcut and input-method acceptance remain separate; a safely failed live generation
  must be recorded as failure, not as language-quality success.

## Keep the offline test exclusion contract in sync with new live suites

- Seen 1x (2026-11-02): adding `JEVReplyServiceLiveTests` to the product test
  exclusions left the release-chain selftest expecting exactly five skipped suites.
  Native tests passed, but the complete gate correctly rejected the stale contract.
- The selftest now names the local-service suite alongside the five credential-gated
  suites. Keep the exact exclusion count and per-suite uniqueness checks; do not
  replace them with a broad Live-name match or permit skipping offline privacy tests.
- Verify (验证点): `bash scripts/release-chain.selftest.sh` checks the actual `make -n test`
  output; `bash scripts/live-test.selftest.sh` checks that the local-service profile
  cannot select provider suites or treat a skipped live test as success. These are
  synthetic script checks, not live-service or installed-host acceptance.

## Progress refresh must preserve reviewed sections and their evidence

- Seen 1x (2026-11-03): retiring the obsolete external board projection for #335 exposed
  that `progress/sync.py` replaced the project review and cleared tracked PR facts.
  The existing one-page and paginated snapshot tests, extended with an editorial
  section and extra issue/PR evidence, failed on the original implementation.
- Preserve non-generated sections and tracked issue/PR numbers, refreshing their
  facts before writing. A snapshot refresh must not silently replace a reviewed
  implementation/acceptance conclusion with tracker state.
- Verify: `python3 scripts/progress-sync.selftest.py` covers preservation alongside
  pagination and head/base drift rejection. Retired projection flags must fail
  before GitHub access or output writes. This is isolated snapshot validation,
  not external task dispatch or shared-ledger acceptance.

## A plain SwiftUI button needs an interaction shape inside its label

**Use `.buttonStyle(.owlPlain)`. Put the full intended hit area inside the label.**

- Reason: on 2026-11-10, a window-local AppKit click probe against `18e6b40` clicked the text, the empty right side, and the key chip in template and radio row fixtures. The template and radio each ran once; the rectangular positive control ran three times. The Agent exposure checkbox also ignored the empty part of its row.
- Prevention: the shared style makes its label rectangular. The radio label includes its spacer and decorative key chips. Keep its real trailing picker separate so VoiceOver can reach both controls.
- Regression: SwiftLint reports `owl_plain_button_hit_area` against the original template and radio sources. The Settings UI suite clicks the right side of every visible sidebar row and checks the actual selection. It also clicks the empty part of a template row and the Agent exposure row.
- Verify (验证点): `swiftlint lint` and `python3 scripts/verify.py swift --test OwlSettingsUITests`.
- Seen on 1 distinct date: 2026-11-10.

## Settings navigation reads snapshots without resetting a draft

**Load templates and provider status off the main thread. Keep Carbon TIS calls on the main queue.**

- Reason: the template and Agent pages revalidated the same library during synchronous page entry. Opening the template page also republished the automatic expansion index and notified the active input session. On 2026-11-10 an isolated diagnostics run trapped in `TISCreateInputSourceList` after moving the whole report to a worker.
- Prevention: publish library data separately from the draft. Agent refreshes discard results for superseded requests. Capture TIS values on main and build the remainder of the diagnostic report on a worker.
- Regression: `testLoadingTemplatesLeavesAnInProgressDraftUntouched` holds the read open until an edit occurs. The Settings UI suite opens Diagnostics and continues through the remaining pages. It runs in its own scheme with a separate preview bundle ID.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlSettingsActionTests --test OwlSettingsUITests`.
- Seen on 1 distinct date: 2026-11-10.

## Restore the open settings editor from the menu

**If Settings is already open or minimized, bring its existing window forward.**

- Reason: on 2026-11-10 the baseline settings window had a disabled minimize button. Opening Settings from the menu also replaced its hosting view and its draft state.
- Prevention: `OwlSettingsWindow.restoreIfOpen` deminiaturizes the existing window. Closing the window still allows the menu to open a fresh settings view.
- Regression: `testReopenSettingsRestoresMinimizedEditorAndCanOpenAfterClose` clicks the native minimize button, opens Settings from the menu, appends text without refocusing the field, and repeats after closing the window.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlSettingsUITests/testReopenSettingsRestoresMinimizedEditorAndCanOpenAfterClose`.
- Seen on 1 distinct date: 2026-11-10.

## Host-facing floating panels share the nonactivating policy

**Use `OwlFloatingPanel` for panels that leave keyboard input with the host. A display-only capsule passes mouse events through.**

- Reason: an isolated AppKit probe on 2026-11-10 showed that the voice capsule could receive mouse events even though it has no controls. Candidate windows also repeated the nonactivating rules instead of sharing them.
- Prevention: the common base inserts the nonactivating mask and prevents subclasses from becoming key or main. Interactive panels accept the first click; the voice capsule ignores mouse events.
- Regression: `testHostFacingPanelsCannotBecomeKeyOrMain` checks the four concrete panels, including the voice capsule's mouse behavior.
- Verify (验证点): `python3 scripts/verify.py swift --test OwlCandidatePanelAppearanceLifecycleTests`. This proves AppKit window policy, not installed input method delivery.
- Seen on 1 distinct date: 2026-11-10.

## A Rust symbol elsewhere in the bundle cannot replace the main executable

**Require the main executable at its launch path and check the Rust symbols in that file.**

- Reason: on 2026-11-10, the standalone Rust delivery check passed after moving the executable to `Contents/MacOS/Owltype.misplaced` in an isolated release copy.
- Regression: `test_rejects_a_misplaced_main_executable` renames the main program and also tests a replacement program without the required symbols.
- Verify (验证点): `python3 scripts/check-rust-delivery.selftest.py` passes, and `make release` validates the built bundle before removing local signatures.
- Seen on 1 distinct date: 2026-11-10.

## A clean checkout can still have an active build

- Seen 1x (2026-11-13): the Chinese-name change started from a clean release
  checkout while another chat's full gate was still running there. Its Release
  build picked up the new display name, so that receipt could not establish the
  original release revision. The name change was moved into an independent
  worktree and the original checkout was restored.
- Before editing a checkout used for release work, check active build processes
  and their working directories as well as Git status. Use a separate worktree
  when another task owns a running gate. A clean Git status alone does not prove
  exclusive ownership.
- Verify: each gate receipt must report an unchanged source snapshot and its
  built manifest must match the intended revision. Discard mixed-build evidence
  and rebuild from the restored or isolated checkout.

## Product-name practice needs the matching keyboard replay

- Seen 1x (2026-11-13): restoring the Chinese display name also changed the
  onboarding practice target. The full native suite still typed the former
  name's pinyin and failed the real-engine completion assertion.
- Keep the replay aligned with the visible target. The integration test now
  types each syllable, selects the corresponding candidate through the input
  controller, and checks that uncommitted text cannot complete practice.
- Verify: `OwlInputHabitsIntegrationTests/testControllerRoundTrip` must produce
  `OwlPracticeProof.target` through the real engine and finish the native field.
