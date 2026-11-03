# Native panels and interaction adapters

## Overview

AppKit windows and SwiftUI surfaces for candidates, input status, snippets, AI writing and source-verification receipts. Native adapters capture focus and accessibility facts and execute effects; reusable interaction decisions are delegated to the Rust app-core sessions where wired.

## Interface

- [OwlSwiftUICandidatePanel.swift:OwlPanelContent](./OwlSwiftUICandidatePanel.swift) is the immutable candidate-content boundary. `OwlSwiftUICandidatePanel.update` accepts it with a settings snapshot; [OwlCandidatePanelView.swift](./OwlCandidatePanelView.swift) renders horizontal, vertical and scroll rows and emits selection/page/pin/remove callbacks.
- [OwlCandidatePanelGeometry.swift](./OwlCandidatePanelGeometry.swift), [OwlFloatingPanelPositioner.swift](./OwlFloatingPanelPositioner.swift) and [OwlHostCaretAnchorMemory.swift](./OwlHostCaretAnchorMemory.swift) resolve sizing, screen placement and host-scoped caret memory. [OwlInputStatusPanel.swift](./OwlInputStatusPanel.swift) follows one active controller; [OwlStatusHUD.swift](./OwlStatusHUD.swift) presents timed mode messages.
- [OwlQuickSendPanel.swift](./OwlQuickSendPanel.swift) loads either the legacy phrase/prompt picker or [OwlTemplatePickerView.swift](./OwlTemplatePickerView.swift). [OwlPromptFillSheet.swift](./OwlPromptFillSheet.swift) owns parameter editing and retained-result presentation.
- [OwlTemplateInvocation.swift](./OwlTemplateInvocation.swift), [OwlPanelInsertionBroker.swift](./OwlPanelInsertionBroker.swift), [OwlTemplateHostDelivery.swift](./OwlTemplateHostDelivery.swift), [OwlTemplateContextCapture.swift](./OwlTemplateContextCapture.swift) and [OwlTemplateCursorPlacement.swift](./OwlTemplateCursorPlacement.swift) bind an invocation, frozen context, focus restoration, delivery outcome and UTF-16 cursor proof.
- [OwlQuickSendHotKey.swift](./OwlQuickSendHotKey.swift) defines recorded slots, the IMK matcher, event tap and recorder. [OwlSelectionMenuCoordinator.swift](./OwlSelectionMenuCoordinator.swift) captures explicitly requested selections and routes toolbox actions; [OwlSelectionRewrite.swift](./OwlSelectionRewrite.swift) sequences generation, confirmation and delivery.
- [OwlAIWindow.swift](./OwlAIWindow.swift) hosts [OwlAIConversationView.swift](./OwlAIConversationView.swift), [OwlAIPolishCardsView.swift](./OwlAIPolishCardsView.swift), [OwlPolishStyleBar.swift](./OwlPolishStyleBar.swift) and [OwlQuickReplyView.swift](./OwlQuickReplyView.swift). Chosen results use the supplied writeback coordinator; copying is a separate action.
- [JEVReplyPanel.swift](./JEVReplyPanel.swift) provides the optional local Kotone reply client. [OwlVerificationReceiptModel.swift](./OwlVerificationReceiptModel.swift) manages verification tasks and source actions; [OwlVerificationReceiptCard.swift](./OwlVerificationReceiptCard.swift) renders them. [OwlEmojiPanel.swift](./OwlEmojiPanel.swift) and [OwlEmojiPanelView.swift](./OwlEmojiPanelView.swift) browse glyphs.

## Invariants

- Candidate, emoji and input-status panels cannot become key/main windows. Candidate updates deduplicate equal content/settings only while visible; hiding or refreshing preferences invalidates the cache. Selection tokens preserve session/generation and absolute-versus-page index semantics.
- Caret validation rejects null, infinite, nonfinite, too-short and offscreen rectangles. Last-good anchors are associated with one host identity; a different host cannot borrow that anchor. Rendering does not itself commit engine text.
- Template browsing shows the loaded original body without expanding context. Explicit preview/use captures requested clipboard/time context once. Invocation binding checks latch changed-library invalidation and guard dispatch after reentrant native reads.
- Template original-text preservation and result delivery have distinct write slots and outcomes. A native insert call is not confirmed acceptance: readback, target identity and selection checks determine confirmation and cursor status. An uncertain result remains inspectable/copyable; this path does not automatically paste, retry insertion or simulate Return.
- Template host reads are bounded to 65536 UTF-16 units. Accessibility field capture avoids the synchronous key-event round trip; secure input, changed targets and missing proof refuse delivery. Cursor relocation additionally checks grapheme boundaries and matching inserted text.
- Recorded hotkeys require a letter and at least two supported modifiers. Summon slots default off; pinning has an unclaimed Control-Shift-P default. The event tap uses its own thread, consumes only matching shortcuts while Owltype is current, excludes candidate pinning, and passes through during recording.
- Selection tools read accessibility on explicit summon, subject to input-source, permission, capability and selection admission. Their replacement flow is distinct from template delivery and may fall back through paste to clipboard; its reported transport success is not a fresh host readback proof.
- AI polish/reply models use cancellation and generation checks for replaced requests. The UI supports explicit writeback as well as copy; old copy-only comments do not describe the entire current AI window.
- Kotone replies are display-only and do not insert text or read credentials. Requests run off the main thread; revision/request identity checks reject stale replies. Local socket transport has send/receive timeouts and a response-size guard.
- Receipt model state comes from its app-core session. Cancelling/closing invalidates work; finding a source and user confirmation are separate states. Unverified sources remain for manual review, and clickable model URLs pass the external-link policy.

## Side Effects

- Panels change window visibility/focus and may persist positions, status visibility, hotkeys or emoji recents. Explicit copy actions write the pasteboard; emoji picks without a host handler also copy.
- Template delivery can insert through IMK and set an existing accessibility selection after admission. AI selection writeback can use AX or synthetic paste through its separate inserter.
- User-triggered AI and verification actions call services; source actions open the default browser and may copy a query. Kotone uses a local Unix socket. Hotkey/selection coordinators install and remove event monitors/taps.

## Verification

Repository test entry: `make test`. Relevant tests cover candidate geometry/tokens, focus and template delivery, picker/hotkey rules, AI models and receipts. Native focus, hit testing, accessibility and actual host insertion require live acceptance; neither product tests nor live acceptance were run for this documentation bootstrap.
