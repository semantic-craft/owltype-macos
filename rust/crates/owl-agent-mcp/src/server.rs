//! The MCP side: tools named after the bridge methods. Each call opens its own bridge connection,
//! so a restarted Owltype or a toggled Agent access switch takes effect on the next call.

use crate::bridge::{Call, Component, Outcome};
use crate::client::{call_once, BridgeError, CALL_TIMEOUT};
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Implementation, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerConfig, Tool, ToolAnnotations,
};
use rmcp::service::RequestContext;
use rmcp::{ErrorData as McpError, RoleServer, ServerHandler};
use serde_json::{json, Map, Value};
use std::sync::Arc;
use std::time::Duration;

const INSTRUCTIONS: &str = "Owltype is a macOS Chinese input method. These tools read its redacted \
status and the templates the user chose to expose. They never return what the user is typing.";

/// One MCP tool and the bridge call it makes.
struct ToolSpec {
    name: &'static str,
    title: &'static str,
    description: &'static str,
    read_only: bool,
    input_schema: fn() -> Value,
    call: fn(Map<String, Value>) -> Result<(Call, Duration), String>,
}

fn no_arguments() -> Value {
    json!({ "type": "object", "properties": {}, "additionalProperties": false })
}

fn expect_no_arguments(arguments: Map<String, Value>, call: Call) -> Result<(Call, Duration), String> {
    if arguments.is_empty() {
        Ok((call, CALL_TIMEOUT))
    } else {
        Err("this tool takes no arguments".into())
    }
}

const TOOLS: &[ToolSpec] = &[ToolSpec {
    name: "owltype_status",
    title: "Owltype status",
    description: "Owltype's version, dictionary resource generation, current input schema, Chinese or \
English mode and how many templates are exposed to agents. Contains no typed text.",
    read_only: true,
    input_schema: no_arguments,
    call: |arguments| expect_no_arguments(arguments, Call::OwltypeStatus),
}];

/// Names of the tools this build offers, in listing order.
pub fn tool_names() -> Vec<&'static str> {
    TOOLS.iter().map(|tool| tool.name).collect()
}

#[derive(Clone, Default)]
pub struct OwltypeMcp;

impl OwltypeMcp {
    fn tool(spec: &ToolSpec) -> Tool {
        let Value::Object(schema) = (spec.input_schema)() else { unreachable!("tool schemas are objects") };
        let mut tool = Tool::new(spec.name, spec.description, Arc::new(schema));
        tool.title = Some(spec.title.into());
        tool.annotations = Some(ToolAnnotations::with_title(spec.title).read_only(spec.read_only).destructive(false));
        tool
    }

    /// Runs one tool against the bridge. Bridge failures are tool errors the agent can read, not
    /// protocol errors, so the client keeps the session.
    pub async fn run(name: &str, arguments: Map<String, Value>, agent_client: Option<Component>) -> CallToolResult {
        let Some(spec) = TOOLS.iter().find(|tool| tool.name == name) else {
            return CallToolResult::error(vec![ContentBlock::text(format!("unknown tool {name}"))]);
        };
        let (call, timeout) = match (spec.call)(arguments) {
            Ok(call) => call,
            Err(why) => return CallToolResult::error(vec![ContentBlock::text(why)]),
        };
        match call_once(&call, agent_client, timeout).await {
            Ok(outcome) => Self::success(outcome),
            Err(error) => Self::failure(&error),
        }
    }

    fn success(outcome: Outcome) -> CallToolResult {
        let value = outcome.to_value();
        let mut result = CallToolResult::success(vec![ContentBlock::text(value.to_string())]);
        result.structured_content = Some(value);
        result
    }

    fn failure(error: &BridgeError) -> CallToolResult {
        CallToolResult::error(vec![ContentBlock::text(error.to_string())])
    }
}

impl ServerHandler for OwltypeMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("owltype-mcp", env!("CARGO_PKG_VERSION")).with_title("Owltype"))
            .with_instructions(INSTRUCTIONS)
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        Ok(ListToolsResult::with_all_items(TOOLS.iter().map(Self::tool).collect()))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let agent_client = context
            .peer
            .peer_info()
            .map(|info| Component { name: info.client_info.name.clone(), version: info.client_info.version.clone() });
        let arguments = request.arguments.unwrap_or_default();
        Ok(Self::run(&request.name, arguments, agent_client).await.into())
    }
}
