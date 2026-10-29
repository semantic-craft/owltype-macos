//! Owl Agent Bridge protocol (`shared/contracts/agent-bridge/bridge.schema.json`): the JSON-RPC 2.0
//! messages owltype-mcp exchanges with `OwlAgentBridge` in Owltype.app, one JSON object per line over
//! a Unix domain socket. The Swift side decodes the same samples into `OwlAgentBridgeProtocol`.
//!
//! Every object rejects unknown fields, so a field carrying input text cannot appear without a
//! contract change on both sides.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use std::collections::BTreeMap;

/// Wire protocol version negotiated by `hello`.
pub const PROTOCOL_VERSION: u32 = 1;
/// Version of the contract files; bumped with any change to the schema or samples' meaning.
pub const CONTRACT_VERSION: u32 = 1;
/// Longest line either side accepts, newline excluded.
pub const MAX_LINE_BYTES: usize = 1 << 20;
/// Longest text `deliver_text` accepts, in Unicode scalar values.
pub const MAX_DELIVER_CHARS: usize = 20_000;
/// `deliver_text` confirmation window when the caller names none, and its bounds.
pub const DEFAULT_DELIVER_TIMEOUT_MS: u64 = 120_000;
pub const DELIVER_TIMEOUT_RANGE_MS: std::ops::RangeInclusive<u64> = 5_000..=600_000;

/// The literal `"2.0"`; any other value fails to decode.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct JsonRpc;

impl Serialize for JsonRpc {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str("2.0")
    }
}

impl<'de> Deserialize<'de> for JsonRpc {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value == "2.0" {
            Ok(JsonRpc)
        } else {
            Err(serde::de::Error::custom(format!("unsupported jsonrpc {value:?}")))
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(u64),
    Text(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Method {
    Hello,
    OwltypeStatus,
    TemplatesList,
    TemplateGet,
    TemplateRender,
    DeliverText,
}

impl Method {
    pub const ALL: [Method; 6] = [
        Method::Hello,
        Method::OwltypeStatus,
        Method::TemplatesList,
        Method::TemplateGet,
        Method::TemplateRender,
        Method::DeliverText,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Method::Hello => "hello",
            Method::OwltypeStatus => "owltype_status",
            Method::TemplatesList => "templates_list",
            Method::TemplateGet => "template_get",
            Method::TemplateRender => "template_render",
            Method::DeliverText => "deliver_text",
        }
    }

    pub fn parse(name: &str) -> Option<Method> {
        Method::ALL.into_iter().find(|method| method.as_str() == name)
    }
}

/// A request as it arrives; `call()` checks the method and its parameters, so a server can answer
/// `method_not_found` and `invalid_params` separately.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub jsonrpc: JsonRpc,
    pub id: RequestId,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Call {
    Hello(HelloParams),
    OwltypeStatus,
    TemplatesList,
    TemplateGet(TemplateRef),
    TemplateRender(RenderParams),
    DeliverText(DeliverParams),
}

/// Why a request could not become a `Call`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CallError {
    UnknownMethod(String),
    InvalidParams(String),
}

impl Request {
    pub fn new(id: RequestId, call: &Call) -> Request {
        let params = match call {
            Call::Hello(params) => Some(to_value(params)),
            Call::OwltypeStatus | Call::TemplatesList => None,
            Call::TemplateGet(params) => Some(to_value(params)),
            Call::TemplateRender(params) => Some(to_value(params)),
            Call::DeliverText(params) => Some(to_value(params)),
        };
        Request { jsonrpc: JsonRpc, id, method: call.method().as_str().to_owned(), params }
    }

    pub fn call(&self) -> Result<Call, CallError> {
        let method = Method::parse(&self.method).ok_or_else(|| CallError::UnknownMethod(self.method.clone()))?;
        let params = self.params.clone();
        let call = match method {
            Method::Hello => Call::Hello(required(params)?),
            Method::OwltypeStatus => none(params, Call::OwltypeStatus)?,
            Method::TemplatesList => none(params, Call::TemplatesList)?,
            Method::TemplateGet => Call::TemplateGet(required(params)?),
            Method::TemplateRender => Call::TemplateRender(required(params)?),
            Method::DeliverText => {
                let params: DeliverParams = required(params)?;
                params.validate().map_err(|field| CallError::InvalidParams(field.to_owned()))?;
                Call::DeliverText(params)
            }
        };
        Ok(call)
    }
}

impl Call {
    pub fn method(&self) -> Method {
        match self {
            Call::Hello(_) => Method::Hello,
            Call::OwltypeStatus => Method::OwltypeStatus,
            Call::TemplatesList => Method::TemplatesList,
            Call::TemplateGet(_) => Method::TemplateGet,
            Call::TemplateRender(_) => Method::TemplateRender,
            Call::DeliverText(_) => Method::DeliverText,
        }
    }
}

fn to_value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).expect("bridge types always serialize")
}

fn required<T: for<'de> Deserialize<'de>>(params: Option<Value>) -> Result<T, CallError> {
    let params = params.ok_or_else(|| CallError::InvalidParams("params".to_owned()))?;
    serde_json::from_value(params).map_err(|error| CallError::InvalidParams(error.to_string()))
}

fn none(params: Option<Value>, call: Call) -> Result<Call, CallError> {
    match params {
        None => Ok(call),
        Some(Value::Object(map)) if map.is_empty() => Ok(call),
        Some(_) => Err(CallError::InvalidParams("params".to_owned())),
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Component {
    pub name: String,
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HelloParams {
    pub protocol_version: u32,
    pub helper: Component,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_client: Option<Component>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HelloResult {
    pub protocol_version: u32,
    pub app: AppBuild,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppBuild {
    pub version: String,
    pub build: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputMode {
    Chinese,
    English,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InputSchema {
    pub id: String,
    pub name: String,
}

/// Redacted App state. It never carries composing, committed, clipboard or host text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Status {
    pub app_version: String,
    pub app_build: String,
    pub resource_generation: String,
    pub input_schema: InputSchema,
    pub input_mode: InputMode,
    pub exposed_template_count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Parameter {
    pub key: String,
    pub name: String,
    pub is_required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_value: Option<String>,
    pub options: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Requirement {
    Clipboard,
    Date,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateSummary {
    pub id: String,
    pub title: String,
    pub parameters: Vec<Parameter>,
    pub requirements: Vec<Requirement>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateList {
    pub templates: Vec<TemplateSummary>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateRef {
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Template {
    pub id: String,
    pub title: String,
    pub body: String,
    pub parameters: Vec<Parameter>,
    pub requirements: Vec<Requirement>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateDetail {
    pub template: Template,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenderParams {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arguments: Option<BTreeMap<String, String>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Warning,
    Error,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostic {
    pub severity: Severity,
    pub message: String,
}

/// A preview only; nothing is written to any field. `cursor_offset` counts UTF-16 code units.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Render {
    pub preview_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_offset: Option<u32>,
    pub missing_keys: Vec<String>,
    pub diagnostics: Vec<Diagnostic>,
}

/// `request_id` is the caller's idempotency key: resubmitting it, also after a reconnect, never
/// writes twice.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DeliverParams {
    pub request_id: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

impl DeliverParams {
    /// The first field that breaks the contract's bounds.
    pub fn validate(&self) -> Result<(), &'static str> {
        let id_ok = (1..=128).contains(&self.request_id.len())
            && self.request_id.bytes().all(|b| b.is_ascii_alphanumeric() || b".-_:".contains(&b));
        if !id_ok {
            return Err("requestId");
        }
        if self.text.is_empty() || self.text.chars().count() > MAX_DELIVER_CHARS {
            return Err("text");
        }
        if self.timeout_ms.is_some_and(|ms| !DELIVER_TIMEOUT_RANGE_MS.contains(&ms)) {
            return Err("timeoutMs");
        }
        Ok(())
    }

    pub fn timeout_ms(&self) -> u64 {
        self.timeout_ms.unwrap_or(DEFAULT_DELIVER_TIMEOUT_MS)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetChangedReason {
    FocusChanged,
    TargetQuit,
    SecureInput,
    NoTarget,
    UnverifiableTarget,
}

impl TargetChangedReason {
    pub const ALL: [TargetChangedReason; 5] = [
        TargetChangedReason::FocusChanged,
        TargetChangedReason::TargetQuit,
        TargetChangedReason::SecureInput,
        TargetChangedReason::NoTarget,
        TargetChangedReason::UnverifiableTarget,
    ];
}

/// The closed set of `deliver_text` outcomes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum DeliverResult {
    #[serde(rename_all = "camelCase")]
    Delivered { request_id: String, verified: bool, replayed: bool },
    #[serde(rename_all = "camelCase")]
    Cancelled { request_id: String, replayed: bool },
    #[serde(rename_all = "camelCase")]
    TargetChanged { request_id: String, reason: TargetChangedReason, replayed: bool },
    #[serde(rename_all = "camelCase")]
    Expired { request_id: String, replayed: bool },
}

impl DeliverResult {
    pub const STATUSES: [&'static str; 4] = ["delivered", "cancelled", "target_changed", "expired"];

    pub fn status(&self) -> &'static str {
        match self {
            DeliverResult::Delivered { .. } => "delivered",
            DeliverResult::Cancelled { .. } => "cancelled",
            DeliverResult::TargetChanged { .. } => "target_changed",
            DeliverResult::Expired { .. } => "expired",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "i32", into = "i32")]
pub enum ErrorCode {
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    UnsupportedProtocolVersion,
    HelloRequired,
    AgentAccessDisabled,
    TemplateNotFound,
    DeliveryBusy,
}

impl ErrorCode {
    pub const ALL: [ErrorCode; 10] = [
        ErrorCode::ParseError,
        ErrorCode::InvalidRequest,
        ErrorCode::MethodNotFound,
        ErrorCode::InvalidParams,
        ErrorCode::InternalError,
        ErrorCode::UnsupportedProtocolVersion,
        ErrorCode::HelloRequired,
        ErrorCode::AgentAccessDisabled,
        ErrorCode::TemplateNotFound,
        ErrorCode::DeliveryBusy,
    ];

    pub fn code(self) -> i32 {
        match self {
            ErrorCode::ParseError => -32700,
            ErrorCode::InvalidRequest => -32600,
            ErrorCode::MethodNotFound => -32601,
            ErrorCode::InvalidParams => -32602,
            ErrorCode::InternalError => -32603,
            ErrorCode::UnsupportedProtocolVersion => -32001,
            ErrorCode::HelloRequired => -32002,
            ErrorCode::AgentAccessDisabled => -32003,
            ErrorCode::TemplateNotFound => -32004,
            ErrorCode::DeliveryBusy => -32005,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            ErrorCode::ParseError => "parse_error",
            ErrorCode::InvalidRequest => "invalid_request",
            ErrorCode::MethodNotFound => "method_not_found",
            ErrorCode::InvalidParams => "invalid_params",
            ErrorCode::InternalError => "internal_error",
            ErrorCode::UnsupportedProtocolVersion => "unsupported_protocol_version",
            ErrorCode::HelloRequired => "hello_required",
            ErrorCode::AgentAccessDisabled => "agent_access_disabled",
            ErrorCode::TemplateNotFound => "template_not_found",
            ErrorCode::DeliveryBusy => "delivery_busy",
        }
    }
}

impl TryFrom<i32> for ErrorCode {
    type Error = String;
    fn try_from(code: i32) -> Result<Self, Self::Error> {
        ErrorCode::ALL.into_iter().find(|known| known.code() == code).ok_or_else(|| format!("unknown error code {code}"))
    }
}

impl From<ErrorCode> for i32 {
    fn from(code: ErrorCode) -> i32 {
        code.code()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ErrorData {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supported_protocol_versions: Option<Vec<u32>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorObject {
    pub code: ErrorCode,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<ErrorData>,
}

/// A response line. `result` stays untyped until the caller, who knows which method it asked,
/// decodes it with `Response::result_as`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Response {
    Success(Success),
    Failure(Failure),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Success {
    pub jsonrpc: JsonRpc,
    pub id: RequestId,
    pub result: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Failure {
    pub jsonrpc: JsonRpc,
    pub id: Option<RequestId>,
    pub error: ErrorObject,
}

/// The typed result of each method.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Hello(HelloResult),
    Status(Status),
    TemplateList(TemplateList),
    TemplateDetail(TemplateDetail),
    Render(Render),
    Deliver(DeliverResult),
}

impl Outcome {
    pub fn decode(method: Method, result: Value) -> Result<Outcome, serde_json::Error> {
        Ok(match method {
            Method::Hello => Outcome::Hello(serde_json::from_value(result)?),
            Method::OwltypeStatus => Outcome::Status(serde_json::from_value(result)?),
            Method::TemplatesList => Outcome::TemplateList(serde_json::from_value(result)?),
            Method::TemplateGet => Outcome::TemplateDetail(serde_json::from_value(result)?),
            Method::TemplateRender => Outcome::Render(serde_json::from_value(result)?),
            Method::DeliverText => Outcome::Deliver(serde_json::from_value(result)?),
        })
    }

    pub fn to_value(&self) -> Value {
        match self {
            Outcome::Hello(value) => to_value(value),
            Outcome::Status(value) => to_value(value),
            Outcome::TemplateList(value) => to_value(value),
            Outcome::TemplateDetail(value) => to_value(value),
            Outcome::Render(value) => to_value(value),
            Outcome::Deliver(value) => to_value(value),
        }
    }
}
