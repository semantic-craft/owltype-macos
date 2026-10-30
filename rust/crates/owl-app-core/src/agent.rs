//! Owltype Agent Business Core (`agent.rs`).
//! Pure business rules governing Agent access, JSON-RPC bridge contracts, template exposure,
//! delivery state transitions, call logging, and CLI configuration generation.
//! Zero platform GUI (AppKit) or socket I/O dependencies.

use crate::template::{self, Diagnostic as EngineDiagnostic, Parsed, TemporalFact};
use crate::template_library::{valid_id, Entry, Library};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

// ============================================================================
// Constants
// ============================================================================

pub const PROTOCOL_VERSION: u32 = 1;
pub const CONTRACT_VERSION: u32 = 1;
pub const MAX_LINE_BYTES: usize = 1 << 20; // 1 MiB
pub const MAX_DELIVER_CHARS: usize = 20_000;
pub const DEFAULT_DELIVER_TIMEOUT_MS: u64 = 120_000;
pub const DELIVER_TIMEOUT_RANGE_MS: std::ops::RangeInclusive<u64> = 5_000..=600_000;
pub const OUTCOME_LIFETIME_SECS: u64 = 600;
pub const STORED_OUTCOME_LIMIT: usize = 256;
pub const CALL_LOG_LIMIT: usize = 200;
pub const TOOL_TIMEOUT_SECONDS: u32 = 610;
pub const BIND_POLLS: u32 = 10;
pub const BIND_POLL_INTERVAL_SECS: f64 = 0.2;
pub const SLOW_BIND_POLL_INTERVAL_SECS: f64 = 0.5;
pub const LEAVE_SETTLE_SECS: f64 = 0.5;

// ============================================================================
// Wire Protocol & Common Models
// ============================================================================

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "i32", into = "i32")]
pub enum ErrorCode {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    UnsupportedProtocolVersion = -32001,
    HelloRequired = -32002,
    AgentAccessDisabled = -32003,
    TemplateNotFound = -32004,
    DeliveryBusy = -32005,
}

impl ErrorCode {
    pub fn code(self) -> i32 {
        self as i32
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
    fn try_from(v: i32) -> Result<Self, Self::Error> {
        match v {
            -32700 => Ok(ErrorCode::ParseError),
            -32600 => Ok(ErrorCode::InvalidRequest),
            -32601 => Ok(ErrorCode::MethodNotFound),
            -32602 => Ok(ErrorCode::InvalidParams),
            -32603 => Ok(ErrorCode::InternalError),
            -32001 => Ok(ErrorCode::UnsupportedProtocolVersion),
            -32002 => Ok(ErrorCode::HelloRequired),
            -32003 => Ok(ErrorCode::AgentAccessDisabled),
            -32004 => Ok(ErrorCode::TemplateNotFound),
            -32005 => Ok(ErrorCode::DeliveryBusy),
            other => Err(format!("unknown error code {other}")),
        }
    }
}

impl From<ErrorCode> for i32 {
    fn from(code: ErrorCode) -> i32 {
        code.code()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorData {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supported_protocol_versions: Option<Vec<u32>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorObject {
    pub code: ErrorCode,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<ErrorData>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
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

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Render {
    pub preview_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_offset: Option<u32>,
    pub missing_keys: Vec<String>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DeliverParams {
    pub request_id: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

impl DeliverParams {
    pub fn validate(&self) -> Result<(), &'static str> {
        validate_deliver_params(&self.request_id, &self.text, self.timeout_ms)
    }

    pub fn effective_timeout_ms(&self) -> u64 {
        self.timeout_ms.unwrap_or(DEFAULT_DELIVER_TIMEOUT_MS)
    }
}

pub fn validate_deliver_params(
    request_id: &str,
    text: &str,
    timeout_ms: Option<u64>,
) -> Result<(), &'static str> {
    let allowed = |b: u8| b.is_ascii_alphanumeric() || b".-_:".contains(&b);
    if !(1..=128).contains(&request_id.len()) || !request_id.bytes().all(allowed) {
        return Err("requestId");
    }
    if text.is_empty() || text.chars().count() > MAX_DELIVER_CHARS {
        return Err("text");
    }
    if let Some(ms) = timeout_ms {
        if !DELIVER_TIMEOUT_RANGE_MS.contains(&ms) {
            return Err("timeoutMs");
        }
    }
    Ok(())
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

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum DeliverStatus {
    Delivered { verified: bool },
    Cancelled,
    TargetChanged { reason: TargetChangedReason },
    Expired,
}

impl DeliverStatus {
    pub fn name(&self) -> &'static str {
        match self {
            DeliverStatus::Delivered { .. } => "delivered",
            DeliverStatus::Cancelled => "cancelled",
            DeliverStatus::TargetChanged { .. } => "target_changed",
            DeliverStatus::Expired => "expired",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum DeliverResult {
    #[serde(rename_all = "camelCase")]
    Delivered {
        request_id: String,
        verified: bool,
        replayed: bool,
    },
    #[serde(rename_all = "camelCase")]
    Cancelled {
        request_id: String,
        replayed: bool,
    },
    #[serde(rename_all = "camelCase")]
    TargetChanged {
        request_id: String,
        reason: TargetChangedReason,
        replayed: bool,
    },
    #[serde(rename_all = "camelCase")]
    Expired {
        request_id: String,
        replayed: bool,
    },
}

impl DeliverResult {
    pub fn from_status(request_id: String, status: DeliverStatus, replayed: bool) -> Self {
        match status {
            DeliverStatus::Delivered { verified } => DeliverResult::Delivered {
                request_id,
                verified,
                replayed,
            },
            DeliverStatus::Cancelled => DeliverResult::Cancelled {
                request_id,
                replayed,
            },
            DeliverStatus::TargetChanged { reason } => DeliverResult::TargetChanged {
                request_id,
                reason,
                replayed,
            },
            DeliverStatus::Expired => DeliverResult::Expired {
                request_id,
                replayed,
            },
        }
    }
}

// ============================================================================
// Domain 1: Access & Status Pure Functions
// ============================================================================

pub fn check_access(enabled: bool) -> Result<(), ErrorObject> {
    if enabled {
        Ok(())
    } else {
        Err(ErrorObject {
            code: ErrorCode::AgentAccessDisabled,
            message: "Agent access is turned off in Owltype settings".to_string(),
            data: None,
        })
    }
}

pub fn resolve_schema_name(schema_id: &str) -> String {
    let cat = crate::keyboard::catalog();
    if let Some(schemas) = cat.get("schemas").and_then(|s| s.as_array()) {
        for s in schemas {
            if s.get("id").and_then(|id| id.as_str()) == Some(schema_id) {
                if let Some(name) = s.get("name").and_then(|n| n.as_str()) {
                    return name.to_string();
                }
            }
        }
    }
    schema_id.to_string()
}

pub fn assemble_status(
    app_version: &str,
    app_build: &str,
    resource_generation: &str,
    schema_id: &str,
    schema_name: Option<&str>,
    ascii_mode: bool,
    exposed_template_count: u32,
) -> Status {
    let name = schema_name
        .map(|s| s.to_string())
        .unwrap_or_else(|| resolve_schema_name(schema_id));
    Status {
        app_version: app_version.to_string(),
        app_build: app_build.to_string(),
        resource_generation: resource_generation.to_string(),
        input_schema: InputSchema {
            id: schema_id.to_string(),
            name,
        },
        input_mode: if ascii_mode {
            InputMode::English
        } else {
            InputMode::Chinese
        },
        exposed_template_count,
    }
}

// ============================================================================
// Domain 2: Template Exposure & Preview Pure Functions
// ============================================================================

pub fn is_template_exposed(entry: &Entry) -> bool {
    entry.exposed_to_agents.unwrap_or(false)
        && entry.review_state.is_none()
        && entry.execution_issue().is_none()
}

pub fn exposed_templates<'a>(library: &'a Library) -> Vec<&'a Entry> {
    library.entries.iter().filter(|e| is_template_exposed(e)).collect()
}

pub fn find_exposed_template<'a>(library: &'a Library, id: &str) -> Option<&'a Entry> {
    if !valid_id(id) {
        return None;
    }
    exposed_templates(library)
        .into_iter()
        .find(|e| e.id.eq_ignore_ascii_case(id))
}

pub fn parse_entry_requirements(parsed: &Parsed) -> Vec<Requirement> {
    let mut requirements = Vec::new();
    if parsed.context_requirements.contains("clipboard") {
        requirements.push(Requirement::Clipboard);
    }
    if parsed.context_requirements.contains("temporal") {
        requirements.push(Requirement::Date);
    }
    requirements
}

pub fn parse_entry_parameters(parsed: &Parsed) -> Vec<Parameter> {
    parsed
        .parameters
        .iter()
        .map(|p| Parameter {
            key: p.key.clone(),
            name: p.name.clone(),
            is_required: p.is_required,
            default_value: p.default_value.clone(),
            options: p.options.clone(),
        })
        .collect()
}

pub fn template_summary(entry: &Entry) -> TemplateSummary {
    let parsed = entry.parsed(false);
    TemplateSummary {
        id: entry.id.to_uppercase(),
        title: entry.title.clone(),
        parameters: parse_entry_parameters(&parsed),
        requirements: parse_entry_requirements(&parsed),
    }
}

pub fn template_detail(entry: &Entry) -> TemplateDetail {
    let summary = template_summary(entry);
    TemplateDetail {
        template: Template {
            id: summary.id,
            title: summary.title,
            body: entry.body.clone(),
            parameters: summary.parameters,
            requirements: summary.requirements,
        },
    }
}

pub fn list_templates(library: &Library) -> TemplateList {
    TemplateList {
        templates: exposed_templates(library)
            .into_iter()
            .map(template_summary)
            .collect(),
    }
}

pub fn get_template(library: &Library, id: &str) -> Result<TemplateDetail, ErrorObject> {
    match find_exposed_template(library, id) {
        Some(entry) => Ok(template_detail(entry)),
        None => Err(ErrorObject {
            code: ErrorCode::TemplateNotFound,
            message: "Template not found".to_string(),
            data: None,
        }),
    }
}

pub fn render_template(
    entry: &Entry,
    arguments: Option<&BTreeMap<String, String>>,
    temporal_facts: Option<&BTreeMap<String, TemporalFact>>,
) -> Result<Render, ErrorObject> {
    let parsed = entry.parsed(false);
    let known_keys: BTreeSet<&str> = parsed.parameters.iter().map(|p| p.key.as_str()).collect();

    if let Some(args) = arguments {
        let mut unknown_keys: Vec<&str> = args
            .keys()
            .filter(|k| !known_keys.contains(k.as_str()))
            .map(|s| s.as_str())
            .collect();
        unknown_keys.sort_unstable();
        if let Some(first_unknown) = unknown_keys.first() {
            return Err(ErrorObject {
                code: ErrorCode::InvalidParams,
                message: format!("Unknown template argument {first_unknown}"),
                data: Some(ErrorData {
                    field: Some("arguments".to_string()),
                    supported_protocol_versions: None,
                }),
            });
        }
    }

    let mut values = parsed.initial_values.clone();
    if let Some(args) = arguments {
        for (k, v) in args {
            values.insert(k.clone(), v.clone());
        }
    }

    let empty_temporal = BTreeMap::new();
    let temporal = temporal_facts.unwrap_or(&empty_temporal);

    // Agent render never reads clipboard: allow_empty = true, clipboard = ""
    let evaluation = template::render(&parsed, &values, "", None, true, temporal);

    let mut diagnostics: Vec<Diagnostic> = evaluation
        .diagnostics
        .into_iter()
        .map(|d: EngineDiagnostic| Diagnostic {
            severity: if d.severity == "error" {
                Severity::Error
            } else {
                Severity::Warning
            },
            message: d.message,
        })
        .collect();

    if parsed.context_requirements.contains("clipboard") {
        diagnostics.push(Diagnostic {
            severity: Severity::Warning,
            message: "剪贴板内容不会提供给 Agent，预览中留空。".to_string(),
        });
    }

    Ok(Render {
        preview_text: evaluation.preview_text,
        cursor_offset: evaluation.cursor_offset.map(|o| o as u32),
        missing_keys: evaluation.missing_keys,
        diagnostics,
    })
}

// ============================================================================
// Domain 3: Delivery State Machine & Outcome Cache
// ============================================================================

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TemplateHostDeliveryOutcome {
    Confirmed,
    ConfirmedWithCursor(CursorPositionOutcome),
    AttemptedUnverified,
    OriginalPreservationUnverified,
    NotAttempted(DeliveryRejectionReason),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorPositionOutcome {
    Positioned,
    LeftAtEnd,
    PositionUnverified,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryRejectionReason {
    MissingHost,
    FocusNotRestored,
    TargetChanged,
    UnverifiableTarget,
    SecureInput,
    OriginalNotPreserved,
    SelectionNotPrepared,
}

pub fn map_host_delivery_outcome(
    outcome: &TemplateHostDeliveryOutcome,
    target_quit: bool,
) -> DeliverStatus {
    match outcome {
        TemplateHostDeliveryOutcome::Confirmed
        | TemplateHostDeliveryOutcome::ConfirmedWithCursor(_) => {
            DeliverStatus::Delivered { verified: true }
        }
        TemplateHostDeliveryOutcome::AttemptedUnverified
        | TemplateHostDeliveryOutcome::OriginalPreservationUnverified => {
            DeliverStatus::Delivered { verified: false }
        }
        TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::SecureInput) => {
            DeliverStatus::TargetChanged {
                reason: TargetChangedReason::SecureInput,
            }
        }
        TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::UnverifiableTarget) => {
            DeliverStatus::TargetChanged {
                reason: TargetChangedReason::UnverifiableTarget,
            }
        }
        TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::MissingHost) => {
            DeliverStatus::TargetChanged {
                reason: if target_quit {
                    TargetChangedReason::TargetQuit
                } else {
                    TargetChangedReason::NoTarget
                },
            }
        }
        TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::FocusNotRestored)
        | TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::TargetChanged)
        | TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::OriginalNotPreserved)
        | TemplateHostDeliveryOutcome::NotAttempted(DeliveryRejectionReason::SelectionNotPrepared) => {
            DeliverStatus::TargetChanged {
                reason: TargetChangedReason::FocusChanged,
            }
        }
    }
}

pub fn map_outcome_code(outcome_code: &str, target_quit: bool) -> DeliverStatus {
    match outcome_code {
        "confirmed" | "confirmed_with_cursor" => DeliverStatus::Delivered { verified: true },
        "unverified"
        | "attempted_unverified"
        | "original_preservation_unverified" => DeliverStatus::Delivered { verified: false },
        "secure_input" => DeliverStatus::TargetChanged {
            reason: TargetChangedReason::SecureInput,
        },
        "unverifiable_target" => DeliverStatus::TargetChanged {
            reason: TargetChangedReason::UnverifiableTarget,
        },
        "missing_host" => DeliverStatus::TargetChanged {
            reason: if target_quit {
                TargetChangedReason::TargetQuit
            } else {
                TargetChangedReason::NoTarget
            },
        },
        "focus_changed"
        | "focus_not_restored"
        | "target_changed"
        | "original_not_preserved"
        | "selection_not_prepared" => DeliverStatus::TargetChanged {
            reason: TargetChangedReason::FocusChanged,
        },
        "expired" => DeliverStatus::Expired,
        _ => DeliverStatus::Cancelled,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredOutcome {
    pub status: DeliverStatus,
    pub at_secs: u64,
}

#[derive(Clone, Debug)]
pub struct OutcomeCache {
    pub outcomes: BTreeMap<String, StoredOutcome>,
    pub lifetime_secs: u64,
    pub limit: usize,
}

impl Default for OutcomeCache {
    fn default() -> Self {
        Self::new(OUTCOME_LIFETIME_SECS, STORED_OUTCOME_LIMIT)
    }
}

impl OutcomeCache {
    pub fn new(lifetime_secs: u64, limit: usize) -> Self {
        Self {
            outcomes: BTreeMap::new(),
            lifetime_secs,
            limit,
        }
    }

    pub fn get(&self, request_id: &str, now_secs: u64) -> Option<DeliverStatus> {
        let stored = self.outcomes.get(request_id)?;
        if stored.at_secs.saturating_add(self.lifetime_secs) >= now_secs {
            Some(stored.status.clone())
        } else {
            None
        }
    }

    pub fn store(&mut self, request_id: String, status: DeliverStatus, now_secs: u64) {
        self.drop_expired(now_secs);
        self.outcomes
            .insert(request_id, StoredOutcome { status, at_secs: now_secs });
        self.trim();
    }

    pub fn drop_expired(&mut self, now_secs: u64) {
        let oldest = now_secs.saturating_sub(self.lifetime_secs);
        self.outcomes.retain(|_, stored| stored.at_secs >= oldest);
    }

    pub fn trim(&mut self) {
        if self.outcomes.len() > self.limit {
            let mut by_time: Vec<(String, u64)> = self
                .outcomes
                .iter()
                .map(|(k, v)| (k.clone(), v.at_secs))
                .collect();
            by_time.sort_by_key(|(_, at)| *at);
            let to_remove = self.outcomes.len() - self.limit;
            for (key, _) in by_time.into_iter().take(to_remove) {
                self.outcomes.remove(&key);
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Delivery Coordinator State Machine
// ----------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TargetInfo {
    pub process_id: i32,
    pub application_name: String,
    pub is_terminated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeliveryPhase {
    WaitingForTarget,
    AwaitingInputSession { process_id: i32, polls_left: u32 },
    ReadyForUser,
    Leaving { target_process_id: i32 },
    Writing { target_process_id: i32 },
    Decided,
}

#[derive(Clone, Debug)]
pub struct PendingDelivery {
    pub request_id: String,
    pub text: String,
    pub ancestors: BTreeSet<i32>,
    pub target: Option<TargetInfo>,
    pub phase: DeliveryPhase,
    pub waiters: Vec<u64>, // waiter IDs
}

#[derive(Clone, Debug, PartialEq)]
pub enum DeliveryEvent {
    SubmitRequest {
        request_id: String,
        text: String,
        timeout_ms: Option<u64>,
        client_pid: i32,
        ancestors: BTreeSet<i32>,
        frontmost_pid: Option<i32>,
        is_secure_input: bool,
        initial_bind: Result<TargetInfo, TargetChangedReason>,
        waiter_id: u64,
    },
    AttachWaiter {
        request_id: String,
        waiter_id: u64,
    },
    CancelWaiter {
        waiter_id: u64,
    },
    UserDecision {
        confirmed: bool,
        frontmost_pid: Option<i32>,
        is_secure_input: bool,
        rebind_if_needed: Result<TargetInfo, TargetChangedReason>,
    },
    TimeoutFired,
    ApplicationActivated {
        process_id: i32,
        own_pid: i32,
    },
    PollFired {
        frontmost_pid: Option<i32>,
        bind_result: Result<TargetInfo, TargetChangedReason>,
    },
    ApplicationTerminated {
        process_id: i32,
    },
    LeaveSettleFired {
        target_terminated: bool,
    },
    HostWriteCompleted {
        outcome: TemplateHostDeliveryOutcome,
        target_terminated: bool,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum DeliveryAction {
    ShowPreview {
        text: String,
        agent_name: String,
    },
    ShowTarget {
        name: Option<String>,
    },
    DismissPreview,
    ScheduleTimeout {
        timeout_seconds: f64,
    },
    SchedulePoll {
        interval_seconds: f64,
    },
    ScheduleLeaveSettle {
        seconds: f64,
    },
    PerformWrite {
        text: String,
        target_pid: i32,
    },
    CompleteWaiters {
        waiters: Vec<u64>,
        result: DeliverResult,
    },
    RejectWaiter {
        waiter_id: u64,
        error: ErrorObject,
    },
}

#[derive(Clone, Debug, Default)]
pub struct DeliveryCoordinatorCore {
    pub outcomes: OutcomeCache,
    pub pending: Option<PendingDelivery>,
}

impl DeliveryCoordinatorCore {
    pub fn new() -> Self {
        Self {
            outcomes: OutcomeCache::default(),
            pending: None,
        }
    }

    pub fn handle_event(&mut self, event: DeliveryEvent, now_secs: u64) -> Vec<DeliveryAction> {
        let mut actions = Vec::new();

        match event {
            DeliveryEvent::SubmitRequest {
                request_id,
                text,
                timeout_ms,
                ancestors,
                frontmost_pid,
                is_secure_input,
                initial_bind,
                waiter_id,
                ..
            } => {
                self.outcomes.drop_expired(now_secs);

                // 1. Check idempotency in outcome cache
                if let Some(status) = self.outcomes.get(&request_id, now_secs) {
                    actions.push(DeliveryAction::CompleteWaiters {
                        waiters: vec![waiter_id],
                        result: DeliverResult::from_status(request_id, status, true),
                    });
                    return actions;
                }

                // 2. Check busy state
                if let Some(ref mut pending) = self.pending {
                    if pending.request_id == request_id {
                        pending.waiters.push(waiter_id);
                    } else {
                        actions.push(DeliveryAction::RejectWaiter {
                            waiter_id,
                            error: ErrorObject {
                                code: ErrorCode::DeliveryBusy,
                                message: "Another deliver_text request is waiting for confirmation"
                                    .to_string(),
                                data: None,
                            },
                        });
                    }
                    return actions;
                }

                // 3. Begin new pending request
                let timeout_sec =
                    timeout_ms.unwrap_or(DEFAULT_DELIVER_TIMEOUT_MS) as f64 / 1000.0;
                let mut pending = PendingDelivery {
                    request_id: request_id.clone(),
                    text: text.clone(),
                    ancestors: ancestors.clone(),
                    target: None,
                    phase: DeliveryPhase::WaitingForTarget,
                    waiters: vec![waiter_id],
                };

                actions.push(DeliveryAction::ScheduleTimeout {
                    timeout_seconds: timeout_sec,
                });

                // Check terminal ancestor vs initial bind
                if let Some(front) = frontmost_pid {
                    if ancestors.contains(&front) {
                        actions.push(DeliveryAction::ShowTarget { name: None });
                        self.pending = Some(pending);
                        return actions;
                    }
                }

                if is_secure_input {
                    self.finish(
                        &mut actions,
                        &pending,
                        DeliverStatus::TargetChanged {
                            reason: TargetChangedReason::SecureInput,
                        },
                        now_secs,
                    );
                    return actions;
                }

                match initial_bind {
                    Ok(target) => {
                        actions.push(DeliveryAction::ShowTarget {
                            name: Some(target.application_name.clone()),
                        });
                        pending.target = Some(target);
                        pending.phase = DeliveryPhase::ReadyForUser;
                        self.pending = Some(pending);
                    }
                    Err(reason) => {
                        self.finish(
                            &mut actions,
                            &pending,
                            DeliverStatus::TargetChanged { reason },
                            now_secs,
                        );
                    }
                }
            }

            DeliveryEvent::AttachWaiter {
                request_id,
                waiter_id,
            } => {
                if let Some(ref mut pending) = self.pending {
                    if pending.request_id == request_id {
                        pending.waiters.push(waiter_id);
                        return actions;
                    }
                }
                if let Some(status) = self.outcomes.get(&request_id, now_secs) {
                    actions.push(DeliveryAction::CompleteWaiters {
                        waiters: vec![waiter_id],
                        result: DeliverResult::from_status(request_id, status, true),
                    });
                }
            }

            DeliveryEvent::CancelWaiter { waiter_id } => {
                if let Some(ref mut pending) = self.pending {
                    pending.waiters.retain(|id| *id != waiter_id);
                    if pending.waiters.is_empty()
                        && !matches!(pending.phase, DeliveryPhase::Writing { .. })
                    {
                        let req = pending.clone();
                        self.finish(&mut actions, &req, DeliverStatus::Cancelled, now_secs);
                    }
                }
            }

            DeliveryEvent::UserDecision {
                confirmed,
                frontmost_pid,
                is_secure_input,
                rebind_if_needed,
            } => {
                let Some(mut pending) = self.pending.clone() else {
                    return actions;
                };
                if pending.phase == DeliveryPhase::Decided
                    || matches!(pending.phase, DeliveryPhase::Writing { .. })
                    || matches!(pending.phase, DeliveryPhase::Leaving { .. })
                {
                    return actions;
                }

                if !confirmed {
                    self.finish(&mut actions, &pending, DeliverStatus::Cancelled, now_secs);
                    return actions;
                }

                // If confirmed, target must be bound
                if pending.target.is_none() {
                    if let Some(front) = frontmost_pid {
                        if !pending.ancestors.contains(&front) {
                            if let Ok(target) = rebind_if_needed {
                                pending.target = Some(target);
                            }
                        }
                    }
                    if pending.target.is_none() {
                        actions.push(DeliveryAction::ShowTarget { name: None });
                        self.pending = Some(pending);
                        return actions;
                    }
                }

                let target = pending.target.as_ref().unwrap();
                if target.is_terminated {
                    self.finish(
                        &mut actions,
                        &pending,
                        DeliverStatus::TargetChanged {
                            reason: TargetChangedReason::TargetQuit,
                        },
                        now_secs,
                    );
                    return actions;
                }
                if is_secure_input {
                    self.finish(
                        &mut actions,
                        &pending,
                        DeliverStatus::TargetChanged {
                            reason: TargetChangedReason::SecureInput,
                        },
                        now_secs,
                    );
                    return actions;
                }

                // Transition to writing
                pending.phase = DeliveryPhase::Writing {
                    target_process_id: target.process_id,
                };
                actions.push(DeliveryAction::DismissPreview);
                actions.push(DeliveryAction::PerformWrite {
                    text: pending.text.clone(),
                    target_pid: target.process_id,
                });
                self.pending = Some(pending);
            }

            DeliveryEvent::TimeoutFired => {
                if let Some(pending) = self.pending.clone() {
                    if !matches!(pending.phase, DeliveryPhase::Writing { .. })
                        && !matches!(pending.phase, DeliveryPhase::Leaving { .. })
                    {
                        self.finish(&mut actions, &pending, DeliverStatus::Expired, now_secs);
                    }
                }
            }

            DeliveryEvent::ApplicationActivated {
                process_id,
                own_pid,
            } => {
                let Some(mut pending) = self.pending.clone() else {
                    return actions;
                };
                if pending.phase == DeliveryPhase::Decided {
                    return actions;
                }

                if let Some(ref target) = pending.target {
                    if process_id != target.process_id
                        && process_id != own_pid
                        && !matches!(pending.phase, DeliveryPhase::Leaving { .. })
                        && !matches!(pending.phase, DeliveryPhase::Writing { .. })
                    {
                        pending.phase = DeliveryPhase::Leaving {
                            target_process_id: target.process_id,
                        };
                        actions.push(DeliveryAction::DismissPreview);
                        actions.push(DeliveryAction::ScheduleLeaveSettle {
                            seconds: LEAVE_SETTLE_SECS,
                        });
                        self.pending = Some(pending);
                    }
                    return actions;
                }

                // Not yet bound
                if !pending.ancestors.contains(&process_id) && process_id != own_pid {
                    pending.phase = DeliveryPhase::AwaitingInputSession {
                        process_id,
                        polls_left: BIND_POLLS,
                    };
                    actions.push(DeliveryAction::SchedulePoll {
                        interval_seconds: BIND_POLL_INTERVAL_SECS,
                    });
                    self.pending = Some(pending);
                }
            }

            DeliveryEvent::PollFired {
                frontmost_pid,
                bind_result,
            } => {
                let Some(mut pending) = self.pending.clone() else {
                    return actions;
                };
                let DeliveryPhase::AwaitingInputSession {
                    process_id,
                    polls_left,
                } = pending.phase
                else {
                    return actions;
                };
                if frontmost_pid != Some(process_id) {
                    return actions;
                }

                if let Ok(target) = bind_result {
                    actions.push(DeliveryAction::ShowTarget {
                        name: Some(target.application_name.clone()),
                    });
                    pending.target = Some(target);
                    pending.phase = DeliveryPhase::ReadyForUser;
                    self.pending = Some(pending);
                    return actions;
                }

                if polls_left > 0 {
                    pending.phase = DeliveryPhase::AwaitingInputSession {
                        process_id,
                        polls_left: polls_left - 1,
                    };
                    actions.push(DeliveryAction::SchedulePoll {
                        interval_seconds: BIND_POLL_INTERVAL_SECS,
                    });
                } else {
                    pending.phase = DeliveryPhase::AwaitingInputSession {
                        process_id,
                        polls_left: 0,
                    };
                    actions.push(DeliveryAction::SchedulePoll {
                        interval_seconds: SLOW_BIND_POLL_INTERVAL_SECS,
                    });
                }
                self.pending = Some(pending);
            }

            DeliveryEvent::ApplicationTerminated { process_id } => {
                if let Some(pending) = self.pending.clone() {
                    if let Some(ref target) = pending.target {
                        if target.process_id == process_id {
                            self.finish(
                                &mut actions,
                                &pending,
                                DeliverStatus::TargetChanged {
                                    reason: TargetChangedReason::TargetQuit,
                                },
                                now_secs,
                            );
                        }
                    }
                }
            }

            DeliveryEvent::LeaveSettleFired { target_terminated } => {
                if let Some(pending) = self.pending.clone() {
                    if matches!(pending.phase, DeliveryPhase::Leaving { .. }) {
                        let reason = if target_terminated {
                            TargetChangedReason::TargetQuit
                        } else {
                            TargetChangedReason::FocusChanged
                        };
                        self.finish(
                            &mut actions,
                            &pending,
                            DeliverStatus::TargetChanged { reason },
                            now_secs,
                        );
                    }
                }
            }

            DeliveryEvent::HostWriteCompleted {
                outcome,
                target_terminated,
            } => {
                if let Some(pending) = self.pending.clone() {
                    let status = map_host_delivery_outcome(&outcome, target_terminated);
                    self.finish(&mut actions, &pending, status, now_secs);
                }
            }
        }

        actions
    }

    fn finish(
        &mut self,
        actions: &mut Vec<DeliveryAction>,
        request: &PendingDelivery,
        status: DeliverStatus,
        now_secs: u64,
    ) {
        self.pending = None;
        actions.push(DeliveryAction::DismissPreview);
        self.outcomes
            .store(request.request_id.clone(), status.clone(), now_secs);

        let result = DeliverResult::from_status(request.request_id.clone(), status, false);
        actions.push(DeliveryAction::CompleteWaiters {
            waiters: request.waiters.clone(),
            result,
        });
    }
}

// ============================================================================
// Domain 4: Call Log Ring Buffer
// ============================================================================

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CallRecord {
    pub at: String, // ISO8601 string
    pub client: String,
    pub method: String,
    pub outcome: String,
}

#[derive(Clone, Debug)]
pub struct CallLogCore {
    pub limit: usize,
    pub records: Vec<CallRecord>,
}

impl Default for CallLogCore {
    fn default() -> Self {
        Self::new(CALL_LOG_LIMIT)
    }
}

impl CallLogCore {
    pub fn new(limit: usize) -> Self {
        Self {
            limit,
            records: Vec::new(),
        }
    }

    pub fn record(&mut self, entry: CallRecord) {
        self.records.insert(0, entry);
        if self.records.len() > self.limit {
            self.records.truncate(self.limit);
        }
    }

    pub fn clear(&mut self) {
        self.records.clear();
    }

    pub fn classify_outcome(status: Option<&str>, error_code_name: Option<&str>) -> String {
        classify_call_outcome(status, error_code_name)
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(&self.records)
    }

    pub fn from_json(json: &str) -> Result<Vec<CallRecord>, serde_json::Error> {
        serde_json::from_str(json)
    }
}

pub fn classify_call_outcome(status: Option<&str>, error_code_name: Option<&str>) -> String {
    if let Some(err) = error_code_name {
        err.to_string()
    } else if let Some(st) = status {
        st.to_string()
    } else {
        "ok".to_string()
    }
}

// ============================================================================
// Domain 5: Settings & CLI Config Generation
// ============================================================================

pub fn shell_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

pub fn agy_command(helper_path: &str) -> String {
    format!("agy mcp add owltype {}", shell_quoted(helper_path))
}

pub fn grok_command(helper_path: &str) -> String {
    format!("grok mcp add owltype {}", shell_quoted(helper_path))
}

pub fn grok_config(helper_path: &str) -> String {
    let escaped = helper_path.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "[mcp_servers.owltype]\ncommand = \"{}\"\ntool_timeout_sec = {}",
        escaped, TOOL_TIMEOUT_SECONDS
    )
}

pub fn outcome_title<'a>(outcome: &'a str) -> &'a str {
    match outcome {
        "ok" => "完成",
        "delivered" => "已写入",
        "cancelled" => "已取消",
        "target_changed" => "目标已变",
        "expired" => "已过期",
        "agent_access_disabled" => "已关闭",
        "template_not_found" => "无此模板",
        "delivery_busy" => "正忙",
        _ => outcome,
    }
}

pub fn listed_templates<'a>(library: &'a Library) -> Vec<&'a Entry> {
    library
        .entries
        .iter()
        .filter(|e| e.review_state.is_none())
        .collect()
}

pub fn set_template_exposed(library: &mut Library, id: &str, exposed: bool) -> bool {
    if let Some(entry) = library.entries.iter_mut().find(|e| e.id.eq_ignore_ascii_case(id)) {
        entry.exposed_to_agents = Some(exposed);
        true
    } else {
        false
    }
}

// ============================================================================
// FFI Rule Dispatch
// ============================================================================

pub fn rule(rule: &str, args: Value) -> Result<Value, String> {
    match rule {
        "status" => {
            let app_version = args["app_version"].as_str().unwrap_or("");
            let app_build = args["app_build"].as_str().unwrap_or("");
            let resource_generation = args["resource_generation"].as_str().unwrap_or("");
            let schema_id = args["schema_id"].as_str().unwrap_or("");
            let schema_name = args["schema_name"].as_str();
            let ascii_mode = args["ascii_mode"].as_bool().unwrap_or(false);
            let exposed_template_count = args["exposed_template_count"].as_u64().unwrap_or(0) as u32;

            let status = assemble_status(
                app_version,
                app_build,
                resource_generation,
                schema_id,
                schema_name,
                ascii_mode,
                exposed_template_count,
            );
            serde_json::to_value(&status).map_err(|e| e.to_string())
        }

        "templates_filter_exposed" => {
            let entries = args["entries"]
                .as_array()
                .ok_or_else(|| "missing entries array".to_string())?;

            let mut exposed_ids = Vec::new();
            for raw in entries {
                let id = raw["id"].as_str().unwrap_or("");
                let is_exposed = raw["is_exposed"].as_bool().unwrap_or(false);
                let is_pending = raw["is_pending_review"].as_bool().unwrap_or(false);
                let has_issue = !raw["execution_issue"].is_null();

                if is_exposed && !is_pending && !has_issue {
                    exposed_ids.push(id.to_string());
                }
            }
            Ok(json!(exposed_ids))
        }

        "template_summary" => {
            let id = args["id"].as_str().unwrap_or("");
            let title = args["title"].as_str().unwrap_or("");
            let body = args["body"].as_str().unwrap_or("");
            let parsed = template::parse(body, false, false, false, vec![]);
            let summary = TemplateSummary {
                id: id.to_uppercase(),
                title: title.to_string(),
                parameters: parse_entry_parameters(&parsed),
                requirements: parse_entry_requirements(&parsed),
            };
            serde_json::to_value(&summary).map_err(|e| e.to_string())
        }

        "template_detail" => {
            let id = args["id"].as_str().unwrap_or("");
            let title = args["title"].as_str().unwrap_or("");
            let body = args["body"].as_str().unwrap_or("");
            let parsed = template::parse(body, false, false, false, vec![]);
            let template = Template {
                id: id.to_uppercase(),
                title: title.to_string(),
                body: body.to_string(),
                parameters: parse_entry_parameters(&parsed),
                requirements: parse_entry_requirements(&parsed),
            };
            serde_json::to_value(&template).map_err(|e| e.to_string())
        }

        "template_render" => {
            let entry_val = &args["entry"];
            let id = entry_val["id"].as_str().unwrap_or("");
            let title = entry_val["title"].as_str().unwrap_or("");
            let body = entry_val["body"].as_str().unwrap_or("");

            let mut entry = Entry::new(id.to_string(), title.to_string(), body.to_string());
            entry.body_type = crate::template_library::BodyType::Template;

            let arguments: Option<BTreeMap<String, String>> = args
                .get("arguments")
                .and_then(|v| serde_json::from_value(v.clone()).ok());

            let temporal_facts: Option<BTreeMap<String, TemporalFact>> = args
                .get("temporal")
                .and_then(|v| serde_json::from_value(v.clone()).ok());

            match render_template(&entry, arguments.as_ref(), temporal_facts.as_ref()) {
                Ok(render) => serde_json::to_value(&render).map_err(|e| e.to_string()),
                Err(err) => {
                    if err.code == ErrorCode::InvalidParams {
                        if let Some(msg) = err.message.strip_prefix("Unknown template argument ") {
                            return Err(format!("unknown_argument:{msg}"));
                        }
                    }
                    Err(err.message)
                }
            }
        }

        "delivery_validate_params" => {
            let request_id = args["request_id"].as_str().unwrap_or("");
            let text = args["text"].as_str().unwrap_or("");
            let timeout_ms = args["timeout_ms"].as_u64();

            let result = validate_deliver_params(request_id, text, timeout_ms);
            let effective_ms = timeout_ms.unwrap_or(DEFAULT_DELIVER_TIMEOUT_MS);
            match result {
                Ok(()) => Ok(json!({
                    "valid": true,
                    "invalid_field": Value::Null,
                    "effective_timeout_ms": effective_ms
                })),
                Err(field) => Ok(json!({
                    "valid": false,
                    "invalid_field": field,
                    "effective_timeout_ms": effective_ms
                })),
            }
        }

        "delivery_status_from_outcome" => {
            let outcome = args["outcome"].as_str().unwrap_or("");
            let target_quit = args["target_quit"].as_bool().unwrap_or(false);
            let status = map_outcome_code(outcome, target_quit);

            let status_json = match status {
                DeliverStatus::Delivered { verified } => json!({
                    "name": "delivered",
                    "verified": verified,
                    "reason": Value::Null
                }),
                DeliverStatus::Cancelled => json!({
                    "name": "cancelled",
                    "verified": Value::Null,
                    "reason": Value::Null
                }),
                DeliverStatus::TargetChanged { reason } => json!({
                    "name": "target_changed",
                    "verified": Value::Null,
                    "reason": reason
                }),
                DeliverStatus::Expired => json!({
                    "name": "expired",
                    "verified": Value::Null,
                    "reason": Value::Null
                }),
            };
            Ok(status_json)
        }

        "call_log_record" => {
            let client_name = args["client_name"].as_str().unwrap_or("");
            let client_version = args["client_version"].as_str().unwrap_or("");
            let method = args["method"].as_str().unwrap_or("");
            let reply_status = args["reply_status"].as_str();
            let reply_error_code = args["reply_error_code"].as_str();
            let at_iso8601 = args["at_iso8601"].as_str().unwrap_or("");

            let outcome = classify_call_outcome(reply_status, reply_error_code);
            let client = format!("{client_name} {client_version}");

            Ok(json!({
                "at": at_iso8601,
                "client": client,
                "method": method,
                "outcome": outcome
            }))
        }

        "cli_config" => {
            let helper_path = args["helper_path"].as_str().unwrap_or("");
            Ok(json!({
                "agy_command": agy_command(helper_path),
                "grok_command": grok_command(helper_path),
                "grok_config": grok_config(helper_path)
            }))
        }

        "outcome_title" => {
            let outcome = args["outcome"].as_str().unwrap_or("");
            Ok(json!({
                "title": outcome_title(outcome)
            }))
        }

        "check_access" => {
            let enabled = args["enabled"].as_bool().unwrap_or(false);
            match check_access(enabled) {
                Ok(()) => Ok(json!({ "allowed": true })),
                Err(err) => Err(err.message),
            }
        }

        _ => Err(format!("unknown_agent_rule:{rule}")),
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_access_disabled_guard() {
        assert_eq!(check_access(true), Ok(()));
        let err = check_access(false).unwrap_err();
        assert_eq!(err.code, ErrorCode::AgentAccessDisabled);
        assert_eq!(err.message, "Agent access is turned off in Owltype settings");
    }

    #[test]
    fn test_status_assembly_and_schema_resolution() {
        let status_cn = assemble_status(
            "1.0.0",
            "100",
            "gen-42",
            "rime_ice",
            None,
            false,
            5,
        );
        assert_eq!(status_cn.app_version, "1.0.0");
        assert_eq!(status_cn.input_mode, InputMode::Chinese);
        assert_eq!(status_cn.exposed_template_count, 5);
        assert_eq!(status_cn.input_schema.name, "雾凇拼音");

        let status_en = assemble_status(
            "1.0.0",
            "100",
            "gen-42",
            "unknown_schema",
            None,
            true,
            0,
        );
        assert_eq!(status_en.input_mode, InputMode::English);
        assert_eq!(status_en.input_schema.name, "unknown_schema");

        let serialized = serde_json::to_string(&status_cn).unwrap();
        assert!(serialized.contains("\"appVersion\":\"1.0.0\""));
        assert!(serialized.contains("\"inputMode\":\"chinese\""));
        assert!(serialized.contains("\"exposedTemplateCount\":5"));
    }

    #[test]
    fn test_exposure_filtering() {
        let mut ready = Entry::new(
            "11111111-1111-1111-1111-111111111111".to_string(),
            "Ready".to_string(),
            "Body".to_string(),
        );
        ready.exposed_to_agents = Some(true);

        let mut unexposed = Entry::new(
            "22222222-2222-2222-2222-222222222222".to_string(),
            "Unexposed".to_string(),
            "Body".to_string(),
        );
        unexposed.exposed_to_agents = Some(false);

        let mut pending = Entry::new(
            "33333333-3333-3333-3333-333333333333".to_string(),
            "Pending".to_string(),
            "Body".to_string(),
        );
        pending.exposed_to_agents = Some(true);
        pending.review_state = Some(crate::template_library::Review::Pending);

        let mut broken = Entry::new(
            "44444444-4444-4444-4444-444444444444".to_string(),
            "Broken".to_string(),
            "{argument name=}".to_string(),
        );
        broken.body_type = crate::template_library::BodyType::Template;
        broken.exposed_to_agents = Some(true);

        assert!(is_template_exposed(&ready));
        assert!(!is_template_exposed(&unexposed));
        assert!(!is_template_exposed(&pending));
        assert!(!is_template_exposed(&broken));

        let lib = Library {
            format_version: 1,
            entries: vec![ready, unexposed, pending, broken],
        };

        let exposed = exposed_templates(&lib);
        assert_eq!(exposed.len(), 1);
        assert_eq!(exposed[0].title, "Ready");
    }

    #[test]
    fn test_find_and_get_template() {
        let mut entry = Entry::new(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".to_string(),
            "Test".to_string(),
            "Hello {argument name=name}".to_string(),
        );
        entry.body_type = crate::template_library::BodyType::Template;
        entry.exposed_to_agents = Some(true);

        let lib = Library {
            format_version: 1,
            entries: vec![entry],
        };

        let found = find_exposed_template(&lib, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");
        assert!(found.is_some());
        assert_eq!(found.unwrap().title, "Test");

        assert!(find_exposed_template(&lib, "not-a-uuid").is_none());
        assert!(find_exposed_template(&lib, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").is_none());

        let detail = get_template(&lib, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap();
        assert_eq!(detail.template.title, "Test");
        assert_eq!(detail.template.parameters.len(), 1);
        assert_eq!(detail.template.parameters[0].name, "name");
    }

    #[test]
    fn test_render_arguments_and_missing_keys() {
        let mut entry = Entry::new(
            "11111111-1111-1111-1111-111111111111".to_string(),
            "Meeting".to_string(),
            "会议：{argument name=议题}，语气：{argument name=语气 default=正式}{cursor}".to_string(),
        );
        entry.body_type = crate::template_library::BodyType::Template;

        let mut args = BTreeMap::new();
        args.insert("n:议题".to_string(), "发版".to_string());

        let render = render_template(&entry, Some(&args), None).unwrap();
        assert_eq!(render.preview_text, "会议：发版，语气：正式");
        assert_eq!(render.cursor_offset, Some("会议：发版，语气：正式".encode_utf16().count() as u32));
        assert_eq!(render.missing_keys, Vec::<String>::new());

        // Missing argument
        let missing_render = render_template(&entry, None, None).unwrap();
        assert_eq!(missing_render.missing_keys, vec!["n:议题"]);

        // Unknown argument rejection
        let mut bad_args = BTreeMap::new();
        bad_args.insert("n:主题".to_string(), "x".to_string());
        let err = render_template(&entry, Some(&bad_args), None).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
        assert_eq!(err.message, "Unknown template argument n:主题");
        assert_eq!(err.data.and_then(|d| d.field), Some("arguments".to_string()));
    }

    #[test]
    fn test_render_clipboard_safety() {
        let mut entry = Entry::new(
            "11111111-1111-1111-1111-111111111111".to_string(),
            "Quote".to_string(),
            "引用：{clipboard}".to_string(),
        );
        entry.body_type = crate::template_library::BodyType::Template;

        let render = render_template(&entry, None, None).unwrap();
        assert_eq!(render.preview_text, "引用：");
        assert!(render.diagnostics.iter().any(|d| d.severity == Severity::Warning && d.message.contains("剪贴板")));
    }

    #[test]
    fn test_deliver_params_validation() {
        assert_eq!(validate_deliver_params("req-123", "hello", Some(10_000)), Ok(()));
        assert_eq!(validate_deliver_params("", "hello", None), Err("requestId"));
        assert_eq!(validate_deliver_params("bad spaces", "hello", None), Err("requestId"));
        assert_eq!(validate_deliver_params("req-1", "", None), Err("text"));
        assert_eq!(validate_deliver_params("req-1", "a".repeat(20_001).as_str(), None), Err("text"));
        assert_eq!(validate_deliver_params("req-1", "ok", Some(4_999)), Err("timeoutMs"));
        assert_eq!(validate_deliver_params("req-1", "ok", Some(600_001)), Err("timeoutMs"));
    }

    #[test]
    fn test_outcome_cache_ttl_and_trim() {
        let mut cache = OutcomeCache::new(600, 2);
        cache.store("r1".to_string(), DeliverStatus::Delivered { verified: true }, 100);
        cache.store("r2".to_string(), DeliverStatus::Cancelled, 200);

        assert_eq!(
            cache.get("r1", 300),
            Some(DeliverStatus::Delivered { verified: true })
        );

        // Expired after 600s
        assert_eq!(cache.get("r1", 800), None);

        // Trim capacity
        cache.store("r3".to_string(), DeliverStatus::Expired, 300);
        assert_eq!(cache.outcomes.len(), 2);
        assert!(!cache.outcomes.contains_key("r1"));
        assert!(cache.outcomes.contains_key("r2"));
        assert!(cache.outcomes.contains_key("r3"));
    }

    #[test]
    fn test_delivery_coordinator_state_machine() {
        let mut coord = DeliveryCoordinatorCore::new();

        // 1. Submit request
        let mut ancestors = BTreeSet::new();
        ancestors.insert(10);

        let actions = coord.handle_event(
            DeliveryEvent::SubmitRequest {
                request_id: "req-1".to_string(),
                text: "Text to write".to_string(),
                timeout_ms: Some(60_000),
                client_pid: 10,
                ancestors: ancestors.clone(),
                frontmost_pid: Some(20),
                is_secure_input: false,
                initial_bind: Ok(TargetInfo {
                    process_id: 20,
                    application_name: "Notes".to_string(),
                    is_terminated: false,
                }),
                waiter_id: 1,
            },
            100,
        );

        assert!(actions.contains(&DeliveryAction::ScheduleTimeout {
            timeout_seconds: 60.0
        }));
        assert!(actions.contains(&DeliveryAction::ShowTarget {
            name: Some("Notes".to_string())
        }));

        // 2. Second request while busy
        let busy_actions = coord.handle_event(
            DeliveryEvent::SubmitRequest {
                request_id: "req-2".to_string(),
                text: "Other".to_string(),
                timeout_ms: None,
                client_pid: 10,
                ancestors: ancestors.clone(),
                frontmost_pid: Some(20),
                is_secure_input: false,
                initial_bind: Ok(TargetInfo {
                    process_id: 20,
                    application_name: "Notes".to_string(),
                    is_terminated: false,
                }),
                waiter_id: 2,
            },
            105,
        );
        assert_eq!(busy_actions.len(), 1);
        match &busy_actions[0] {
            DeliveryAction::RejectWaiter { waiter_id, error } => {
                assert_eq!(*waiter_id, 2);
                assert_eq!(error.code, ErrorCode::DeliveryBusy);
            }
            other => panic!("expected reject, got {other:?}"),
        }

        // 3. User confirms -> writes
        let write_actions = coord.handle_event(
            DeliveryEvent::UserDecision {
                confirmed: true,
                frontmost_pid: Some(20),
                is_secure_input: false,
                rebind_if_needed: Ok(TargetInfo {
                    process_id: 20,
                    application_name: "Notes".to_string(),
                    is_terminated: false,
                }),
            },
            110,
        );
        assert!(write_actions.contains(&DeliveryAction::DismissPreview));
        assert!(write_actions.contains(&DeliveryAction::PerformWrite {
            text: "Text to write".to_string(),
            target_pid: 20,
        }));

        // 4. Host write completed -> delivers
        let complete_actions = coord.handle_event(
            DeliveryEvent::HostWriteCompleted {
                outcome: TemplateHostDeliveryOutcome::Confirmed,
                target_terminated: false,
            },
            112,
        );
        assert!(complete_actions.contains(&DeliveryAction::DismissPreview));
        assert!(complete_actions.contains(&DeliveryAction::CompleteWaiters {
            waiters: vec![1],
            result: DeliverResult::Delivered {
                request_id: "req-1".to_string(),
                verified: true,
                replayed: false,
            },
        }));

        // 5. Idempotent replay of req-1
        let replay_actions = coord.handle_event(
            DeliveryEvent::SubmitRequest {
                request_id: "req-1".to_string(),
                text: "Text to write".to_string(),
                timeout_ms: None,
                client_pid: 10,
                ancestors,
                frontmost_pid: Some(20),
                is_secure_input: false,
                initial_bind: Ok(TargetInfo {
                    process_id: 20,
                    application_name: "Notes".to_string(),
                    is_terminated: false,
                }),
                waiter_id: 3,
            },
            115,
        );
        assert_eq!(
            replay_actions,
            vec![DeliveryAction::CompleteWaiters {
                waiters: vec![3],
                result: DeliverResult::Delivered {
                    request_id: "req-1".to_string(),
                    verified: true,
                    replayed: true,
                },
            }]
        );
    }

    #[test]
    fn test_call_log_capacity_and_trim() {
        let mut log = CallLogCore::new(3);
        for i in 1..=5 {
            log.record(CallRecord {
                at: format!("2026-10-30T10:0{i}:00Z"),
                client: "owltype-mcp 0.1.0".to_string(),
                method: "owltype_status".to_string(),
                outcome: "ok".to_string(),
            });
        }
        assert_eq!(log.records.len(), 3);
        assert_eq!(log.records[0].at, "2026-10-30T10:05:00Z");
        assert_eq!(log.records[2].at, "2026-10-30T10:03:00Z");
    }

    #[test]
    fn test_cli_commands_and_toml() {
        let path = "/Applications/Owltype.app/Contents/Helpers/owltype-mcp";
        assert_eq!(
            agy_command(path),
            "agy mcp add owltype '/Applications/Owltype.app/Contents/Helpers/owltype-mcp'"
        );
        assert_eq!(
            grok_command(path),
            "grok mcp add owltype '/Applications/Owltype.app/Contents/Helpers/owltype-mcp'"
        );
        assert_eq!(
            grok_config(path),
            "[mcp_servers.owltype]\ncommand = \"/Applications/Owltype.app/Contents/Helpers/owltype-mcp\"\ntool_timeout_sec = 610"
        );
        assert_eq!(shell_quoted("it's a test"), "'it'\\''s a test'");
    }

    #[test]
    fn test_outcome_titles() {
        assert_eq!(outcome_title("ok"), "完成");
        assert_eq!(outcome_title("delivered"), "已写入");
        assert_eq!(outcome_title("cancelled"), "已取消");
        assert_eq!(outcome_title("target_changed"), "目标已变");
        assert_eq!(outcome_title("expired"), "已过期");
        assert_eq!(outcome_title("agent_access_disabled"), "已关闭");
        assert_eq!(outcome_title("template_not_found"), "无此模板");
        assert_eq!(outcome_title("delivery_busy"), "正忙");
        assert_eq!(outcome_title("custom"), "custom");
    }

    #[test]
    fn test_rule_dispatcher() {
        // status
        let res = rule(
            "status",
            json!({
                "app_version": "1.0",
                "app_build": "1",
                "resource_generation": "gen-1",
                "schema_id": "rime_ice",
                "schema_name": "雾凇",
                "ascii_mode": true,
                "exposed_template_count": 3
            }),
        )
        .unwrap();
        assert_eq!(res["inputMode"], "english");
        assert_eq!(res["exposedTemplateCount"], 3);

        // cli_config
        let cfg = rule(
            "cli_config",
            json!({
                "helper_path": "/tmp/helper"
            }),
        )
        .unwrap();
        assert_eq!(cfg["agy_command"], "agy mcp add owltype '/tmp/helper'");

        // outcome_title
        let title = rule("outcome_title", json!({"outcome": "delivered"})).unwrap();
        assert_eq!(title["title"], "已写入");
    }
}
