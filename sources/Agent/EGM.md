# Local agent bridge

## Overview

App-side Unix socket bridge for the bundled owltype-mcp helper, exposing redacted input status, explicitly exposed templates and user-confirmed text delivery. Native sockets/signature checks/UI effects remain in Swift; access, template and delivery policies call the Rust application core.

## Interface

- `OwlAgentBridgeProtocol` defines line-delimited JSON-RPC 2.0 requests/results for hello, owltype_status, templates_list, template_get, template_render and deliver_text; `OwlJSONValue` supports strict structural round-trip decoding. [OwlAgentBridgeProtocol.swift:OwlAgentBridgeProtocol] [OwlAgentBridgeProtocol.swift:OwlJSONValue]
- `OwlAgentBridge.start` / `stop` manage the socket; `OwlAgentBridgeService.handle` supplies asynchronous replies and `OwlAgentBridgeCancellation` reports disconnect cancellation. [OwlAgentBridge.swift:OwlAgentBridge] [OwlAgentBridge.swift:OwlAgentBridgeService] [OwlAgentBridge.swift:OwlAgentBridgeCancellation]
- `OwlAgentAccess.start` follows the enabled preference and implements the service; status contains app/build/resource/schema/mode/template-count metadata. [OwlAgentAccess.swift:OwlAgentAccess] [OwlAgentBridgeProtocol.swift:Status]
- `OwlAgentPeerVerifying.admit` and `OwlAgentPeerVerifier.Policy` define peer admission. [OwlAgentPeerVerifier.swift:OwlAgentPeerVerifier]
- `OwlAgentTemplates.exposed`, `find`, `summary`, `detail` and `render` expose the permitted template subset and preview rendering. [OwlAgentTemplates.swift:OwlAgentTemplates]
- `OwlAgentDeliveryCoordinator` adapts the agentDelivery Rust session to `OwlAgentDeliveryHost`, `OwlAgentDeliveryTarget` and `OwlAgentDeliveryPreview`; the live host and panel implement native effects. [OwlAgentDelivery.swift:OwlAgentDeliveryCoordinator] [OwlAgentDeliveryPanel.swift:OwlAgentLiveDeliveryHost] [OwlAgentDeliveryPanel.swift:OwlAgentDeliveryPanel]
- `OwlAgentCallLog.records`, `record`, `clear` and `flush` expose the redacted call history. [OwlAgentCallLog.swift:OwlAgentCallLog]

## Invariants

- Socket parent must be a current-user-owned directory, set to 0700; only an owned socket may be removed at the socket path, and the new socket is chmodded 0600. [OwlAgentBridge.swift:preparePrivateDirectory] [OwlAgentBridge.swift:removeStaleSocket] [OwlAgentBridge.swift:startOnQueue]
- Admission requires matching UID plus a valid audit-token-derived code signature. Team-signed apps require the same Team ID and an identifier starting owltype-mcp; ad-hoc apps require exact bundled helper path and cdhash. An unreadable reference refuses all peers. [OwlAgentPeerVerifier.swift:ownPolicy] [OwlAgentPeerVerifier.swift:admit] [OwlAgentPeerVerifier.swift:allows]
- Strict decoding rejects fields lost in re-encoding. Connections enforce 1 MiB lines, protocol version 1, successful hello before service calls and unique in-flight request IDs. Connection closure cancels pending requests. [OwlAgentBridgeProtocol.swift:decodeStrict] [OwlAgentBridge.swift:Connection]
- Bridge access defaults off; turning it off stops the listener and connections. Status values omit host/composition/clipboard text. [OwlAgentAccess.swift:OwlAgentAccessPreferences] [OwlAgentAccess.swift:apply] [OwlAgentBridgeProtocol.swift:Status]
- Template rendering passes an empty clipboard reader; exposure filtering and argument validation are delegated to named agent rules. [OwlAgentTemplates.swift:exposed] [OwlAgentTemplates.swift:render]
- The delivery panel never becomes key/main and only enables confirmation after binding a target and a 0.6-second delay; callbacks are cleared after a decision. Request idempotency, busy/timeout and target-transition policy live in the Rust agentDelivery session. [OwlAgentDeliveryPanel.swift:OwlAgentDeliveryPanel] [OwlAgentDelivery.swift:dispatch]
- Delivery outcomes distinguish confirmed from unverified host attempts; the live host delegates to OwlTemplateHostDelivery with a UTF-16 cursor offset. [OwlAgentDelivery.swift:outcomeCode] [OwlAgentDeliveryPanel.swift:deliveryResult]

## Side Effects

- Creates/listens/reads/writes/closes a local socket and schedules dispatch timers on its serial utility queue. [OwlAgentBridge.swift:OwlAgentBridge]
- Reads defaults, bundle/resource/template metadata and native input state; delivery observes workspace changes, reads process ancestry, opens previews and asks the captured host adapter to write text. [OwlAgentAccess.swift:OwlAgentAccess] [OwlAgentDeliveryPanel.swift:OwlAgentLiveDeliveryHost] [OwlAgentDelivery.swift:dispatchPerformWrite]
- Call history stores only timestamp/client/method/outcome fields, passes a 200-entry limit to the Rust append rule, writes calls.json atomically with mode 0600 and posts change notifications. [OwlAgentCallLog.swift:OwlAgentCallRecord] [OwlAgentCallLog.swift:record] [OwlAgentCallLog.swift:persist]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
