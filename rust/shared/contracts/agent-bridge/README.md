# Owl Agent Bridge contract

`owltype-mcp` (Rust, `rust/crates/owl-agent-mcp`) serves MCP over stdio to an agent client and
forwards each tool call to `OwlAgentBridge` inside Owltype.app (Swift, `sources/Agent`). This
directory is the contract between those two processes.

- **Transport:** a Unix domain socket in a directory only the user can open (0700, socket 0600):
  `~/Library/Application Support/Owltype/AgentBridge/bridge.sock`
  (`OWLTYPE_AGENT_BRIDGE_SOCKET` overrides it for tests and development builds). The helper refuses
  a socket or directory another user owns or can open, and a listener of another user.
  One UTF-8 JSON object per line, at most 1 MiB, JSON-RPC 2.0.
- **Handshake:** `hello` is the first request on every connection. It carries the bridge
  `protocolVersion` (independent of the MCP protocol version the helper negotiates with its
  client) and names the helper and the agent client for the App's call log.
- **Methods:** `owltype_status`, `templates_list`, `template_get`, `template_render` and
  `deliver_text`, named as the MCP tools. Template methods see only templates the user exposed to
  agents; an unexposed template answers `template_not_found`, the same as a missing one.
- **`deliver_text`:** the App shows a native preview and writes only after the user confirms. The
  answer is one of four statuses:

  | status | when |
  | --- | --- |
  | `delivered` | written once; `verified: false` when the host accepted it but its field could not be read back (Chrome) |
  | `cancelled` | the user dismissed the preview |
  | `target_changed` | the bound target is gone: `focus_changed`, `target_quit`, `secure_input`, `no_target` or `unverifiable_target` |
  | `expired` | no confirmation within `timeoutMs` |

  `requestId` is the caller's idempotency key. A repeated `requestId`, also on a new connection,
  returns the stored outcome with `replayed: true` and never writes again. Return is never pressed.

`bridge.schema.json` documents every message. The Rust `bridge` module and Swift
`OwlAgentBridgeProtocol` are the enforcement: both reject unknown fields, so no field carrying
input text can be added on one side only. `samples/` holds one file per message, named
`<method>.request[.variant].json`, `<method>.response[.variant].json` or `error.<code>.json`;
`samples/invalid/` holds messages both sides must reject. Tests on both sides read these files:

```bash
cargo test --manifest-path rust/Cargo.toml -p owl-agent-mcp
python3 scripts/verify.py swift --test OwlAgentBridgeContractTests
```

Change the schema, the samples and both type sets together, and bump `contractVersion` (and
`protocolVersion` when an existing message changes meaning).
