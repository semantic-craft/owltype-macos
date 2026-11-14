use serde::{Deserialize, Serialize};

pub fn should_suggest(failed_version: Option<&str>, current: &str) -> bool {
    !current.is_empty() && failed_version == Some(current)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecheckDecision {
    Recovered,
    Present,
}

pub fn recheck_decision(unmet: Option<&[String]>, error: Option<&str>) -> RecheckDecision {
    if error.is_none() && unmet.map_or(false, |u| u.is_empty()) {
        RecheckDecision::Recovered
    } else {
        RecheckDecision::Present
    }
}

pub fn classify_logout_error(error_number: Option<i32>) -> &'static str {
    match error_number {
        Some(-1743) => "automationDenied",
        Some(-1712) => "timeout",
        _ => "other",
    }
}
