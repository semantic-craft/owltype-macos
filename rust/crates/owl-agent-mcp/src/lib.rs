//! Owltype's agent access (#208): `owltype-mcp` serves MCP over stdio and forwards each tool call
//! over the Owl Agent Bridge protocol to Owltype.app, which listens on a private Unix socket.

pub mod bridge;
pub mod client;
pub mod server;
