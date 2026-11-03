# owl-agent-mcp

## Overview
Workspace crate and executable for Owltype agent access over MCP and the local app bridge.

## Subdirectories & Boundaries
- [Source contract](./src/EGM.md): typed bridge protocol, private socket client, and MCP server.

## Interface
- `Cargo.toml:package.name` exports `owl-agent-mcp`; `Cargo.toml:[[bin]]` builds `owltype-mcp` from `src/main.rs`.
- `Cargo.toml:dependencies.rmcp` pins external MCP SDK 3.8.0 with server/stdio transport support; the SDK is not implemented locally.

## Invariants
- `src/bridge.rs:PROTOCOL_VERSION` and typed protocol DTOs are the helper/app compatibility boundary.

## Side Effects
- `src/main.rs:main` serves stdio; `src/client.rs:call_once` communicates with the app over a Unix socket.

## Verification
- From `rust/`: `cargo test -p owl-agent-mcp`.
