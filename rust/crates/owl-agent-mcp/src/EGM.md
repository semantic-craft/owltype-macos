# Owl Agent MCP helper

## Overview
A stdio MCP server translates five tools into the Owl Agent Bridge JSON-RPC protocol over a private Unix socket. The app owns input state and delivery effects.

## Interface
- `lib.rs` exports `bridge`, `client`, and `server`; `main.rs:main` starts `OwltypeMcp` on stdio, accepts `--version`, and rejects unknown first arguments with exit code 64.
- `bridge.rs:Method` defines `hello`, `owltype_status`, `templates_list`, `template_get`, `template_render`, and `deliver_text`; `Request::call`, `Call`, `Outcome`, `Response`, and `ErrorCode` encode/decode their typed messages.
- `bridge.rs` exposes status, template/parameter/render DTOs plus `DeliverParams`, `DeliverResult`, and `TargetChangedReason`.
- `client.rs:socket_path`, `BridgeConnection::open`, `BridgeConnection::call`, and `call_once` expose socket lookup, handshake, and request execution; `BridgeError` represents transport/protocol/app failures.
- `server.rs:tool_names` and `OwltypeMcp::run` expose tool enumeration and execution; `ServerHandler` advertises the five non-hello methods as MCP tools using the external `rmcp` SDK.

## Invariants
- `bridge.rs:JsonRpc` accepts only `"2.0"`; bridge object DTOs use `deny_unknown_fields`. `PROTOCOL_VERSION` and `CONTRACT_VERSION` are 1.
- `bridge.rs:DeliverParams::validate` permits 1–128 ASCII alphanumeric/`.-_:` request-ID bytes, 1–20,000 Unicode scalar values of text, and an optional 5,000–600,000 ms timeout (default 120,000 ms).
- `bridge.rs:DeliverResult` limits outcomes to `delivered`, `cancelled`, `target_changed`, and `expired`; `Status` has only redacted metadata fields. Idempotency/delivery confirmation are app-side responsibilities, not storage maintained by this helper.
- `client.rs:verify_private` checks socket type/current-user ownership, path length at most 103 bytes, and a current-user-owned parent without group/other permissions. `BridgeConnection::open` also verifies the connected peer UID and negotiated protocol version.
- `client.rs:decode_answer` requires matching success IDs; a failure may have a null ID or matching ID. `server.rs:run` turns bridge failures into tool errors, retaining the MCP session.

## Side Effects
- `client.rs:socket_path` reads `OWLTYPE_AGENT_BRIDGE_SOCKET` or `HOME`; transport reads filesystem metadata and opens Unix sockets. Each `call_once` opens a connection, sends `hello`, executes one call, and closes it.
- `server.rs:OwltypeMcp::run` forwards requests to the app, including delivery requests that can cause app-side text insertion after confirmation. Read-only tool flags are defined by `server.rs:TOOLS`.
- `main.rs:main` reads stdin, writes MCP responses to stdout and errors to stderr, and runs a current-thread Tokio runtime.

## Verification
- From `rust/`: `cargo test -p owl-agent-mcp`. Actual app bridge availability and host text delivery require separate native integration verification.
