//! The MCP side: tools named after the bridge methods. Each call opens its own bridge connection,
//! so a restarted Owltype or a toggled Agent access switch takes effect on the next call.

use crate::bridge::{Call, Component, DeliverParams, Outcome, RenderParams, TemplateRef};
use crate::client::{call_once, BridgeError, CALL_TIMEOUT, DELIVER_GRACE};
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
status and the templates the user chose to expose, preview them, and offer text for the user to \
confirm into the field they are typing in. They never return what the user is typing.";

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

fn template_id_schema() -> Value {
    json!({
        "type": "object",
        "properties": { "id": { "type": "string", "description": "Template id from templates_list" } },
        "required": ["id"],
        "additionalProperties": false
    })
}

fn render_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string", "description": "Template id from templates_list" },
            "arguments": {
                "type": ["object", "string"],
                "description": "Parameter values by key (the parameters' `key` from templates_list); omitted ones use their defaults. \
A client that cannot send nested objects may pass the same map as a JSON string.",
                "additionalProperties": { "type": "string" }
            }
        },
        "required": ["id"],
        "additionalProperties": false
    })
}

fn deliver_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "requestId": {
                "type": "string",
                "pattern": "^[A-Za-z0-9._:-]{1,128}$",
                "description": "Your id for this delivery. Reuse it to retry: a delivery with the same id is written at most once and a retry returns its outcome."
            },
            "text": { "type": "string", "minLength": 1, "maxLength": 20000, "description": "The text to write" },
            "timeoutMs": {
                "type": "integer", "minimum": 5000, "maximum": 600000,
                "description": "How long to wait for the user's confirmation; 120000 when omitted"
            }
        },
        "required": ["requestId", "text"],
        "additionalProperties": false
    })
}

fn deliver_call(arguments: Map<String, Value>) -> Result<(Call, Duration), String> {
    let params: DeliverParams = decode(arguments)?;
    params.validate().map_err(|field| format!("invalid {field}"))?;
    let timeout = Duration::from_millis(params.timeout_ms()) + DELIVER_GRACE;
    Ok((Call::DeliverText(params), timeout))
}

/// Antigravity CLI sends tool arguments as flat primitives only, so `arguments` may arrive as the
/// JSON text of the map.
fn render_params(mut arguments: Map<String, Value>) -> Result<RenderParams, String> {
    if let Some(Value::String(text)) = arguments.get("arguments") {
        let map: Value = serde_json::from_str(text).map_err(|error| format!("invalid arguments: `arguments` is not a JSON object: {error}"))?;
        arguments.insert("arguments".into(), map);
    }
    decode(arguments)
}

fn decode<T: serde::de::DeserializeOwned>(arguments: Map<String, Value>) -> Result<T, String> {
    serde_json::from_value(Value::Object(arguments)).map_err(|error| format!("invalid arguments: {error}"))
}

const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        name: "owltype_status",
        title: "Owltype status",
        description: "Owltype's version, dictionary resource generation, current input schema, Chinese or \
English mode and how many templates are exposed to agents. Contains no typed text.",
        read_only: true,
        input_schema: no_arguments,
        call: |arguments| expect_no_arguments(arguments, Call::OwltypeStatus),
    },
    ToolSpec {
        name: "templates_list",
        title: "List Owltype templates",
        description: "The templates the user exposed to agents in Owltype settings, with their parameters. \
Templates the user did not expose are never listed.",
        read_only: true,
        input_schema: no_arguments,
        call: |arguments| expect_no_arguments(arguments, Call::TemplatesList),
    },
    ToolSpec {
        name: "template_get",
        title: "Get an Owltype template",
        description: "One exposed template with its body and parameters.",
        read_only: true,
        input_schema: template_id_schema,
        call: |arguments| Ok((Call::TemplateGet(decode::<TemplateRef>(arguments)?), CALL_TIMEOUT)),
    },
    ToolSpec {
        name: "template_render",
        title: "Preview an Owltype template",
        description: "Fill an exposed template with arguments and return the preview text, any missing \
parameters and diagnostics. Writes nothing anywhere; clipboard fields preview empty.",
        read_only: true,
        input_schema: render_schema,
        call: |arguments| Ok((Call::TemplateRender(render_params(arguments)?), CALL_TIMEOUT)),
    },
    ToolSpec {
        name: "deliver_text",
        title: "Write text where the user is typing",
        description: "Offer text to the field the user is typing in. Owltype shows it in a native preview \
and writes it only if the user confirms; Return is never pressed. Answers delivered (verified false when \
the field could not be read back), cancelled, target_changed (with a reason) or expired. If the user is \
in this agent's own terminal, the preview asks them to switch to the target field first.",
        read_only: false,
        input_schema: deliver_schema,
        call: deliver_call,
    },
];

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
        // A 2026-07-28 client (Antigravity CLI) never sends initialize: it names itself in each
        // request's _meta instead.
        let agent_client = context
            .peer
            .peer_info()
            .map(|info| info.client_info.clone())
            .or_else(|| context.meta.client_info())
            .map(|info| Component { name: info.name, version: info.version });
        let arguments = request.arguments.unwrap_or_default();
        Ok(Self::run(&request.name, arguments, agent_client).await.into())
    }
}
