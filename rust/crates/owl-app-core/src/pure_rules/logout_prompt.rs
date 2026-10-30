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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SafeVerdict {
    pub is_safe: bool,
    pub stale_composition_override: bool,
    pub reason: String,
}

pub fn evaluate_safe_verdict(
    snapshot_id: Option<u64>,
    idle_seconds: Option<f64>,
    is_login_window: bool,
    blocked_ticks: usize,
) -> SafeVerdict {
    if is_login_window {
        return SafeVerdict {
            is_safe: false,
            stale_composition_override: false,
            reason: "login window active".into(),
        };
    }
    if let Some(_id) = snapshot_id {
        if blocked_ticks >= 120 {
            return SafeVerdict {
                is_safe: true,
                stale_composition_override: true,
                reason: format!("stale composition override after {blocked_ticks} ticks"),
            };
        } else {
            return SafeVerdict {
                is_safe: false,
                stale_composition_override: false,
                reason: format!("composing (tick {blocked_ticks}/120)"),
            };
        }
    }
    if let Some(idle) = idle_seconds {
        if idle < 2.0 {
            return SafeVerdict {
                is_safe: false,
                stale_composition_override: false,
                reason: format!("input busy (idle {idle:.1}s < 2.0s)"),
            };
        }
    }
    SafeVerdict {
        is_safe: true,
        stale_composition_override: false,
        reason: "safe".into(),
    }
}

pub fn classify_logout_error(error_number: Option<i32>) -> &'static str {
    match error_number {
        Some(-1743) => "automationDenied",
        Some(-1712) => "timeout",
        _ => "other",
    }
}
