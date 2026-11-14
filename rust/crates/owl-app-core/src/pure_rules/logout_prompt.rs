use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

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

pub fn safe_verdict(
    snapshot_id: Option<u64>,
    idle_seconds: Option<f64>,
    is_login_window: bool,
    blocked_ticks: usize,
    stale_composition_ticks: usize,
    idle_threshold: f64,
) -> Value {
    if is_login_window {
        return json!({
            "kind": "blocked",
            "block_reason": "login_window"
        });
    }
    if let Some(id) = snapshot_id {
        if blocked_ticks < stale_composition_ticks {
            return json!({
                "kind": "blocked",
                "block_reason": "composing",
                "snapshot_id": id,
                "blocked_ticks": blocked_ticks
            });
        }
    }
    if let Some(idle) = idle_seconds {
        if idle < idle_threshold {
            return json!({
                "kind": "blocked",
                "block_reason": "input_busy",
                "idle_seconds": idle
            });
        }
    }
    json!({
        "kind": "safe",
        "stale_composition_override": snapshot_id.is_some()
    })
}

pub fn activation_verdict(
    is_active: bool,
    awaiting_ticks: usize,
    activation_confirm_ticks: usize,
) -> Value {
    if is_active {
        json!({
            "kind": "present",
            "forced_without_active_confirm": false
        })
    } else if awaiting_ticks >= activation_confirm_ticks {
        json!({
            "kind": "present",
            "forced_without_active_confirm": true
        })
    } else {
        json!({
            "kind": "waitNextTick"
        })
    }
}

pub fn classify_logout_error(error_number: Option<i32>) -> &'static str {
    match error_number {
        Some(-1743) => "automationDenied",
        Some(-1712) => "timeout",
        _ => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_safe_and_activation_verdicts() {
        assert_eq!(
            safe_verdict(Some(9), Some(5.0), true, 0, 120, 2.0),
            json!({"kind": "blocked", "block_reason": "login_window"})
        );
        assert_eq!(
            safe_verdict(Some(9), Some(5.0), false, 3, 120, 2.0),
            json!({
                "kind": "blocked",
                "block_reason": "composing",
                "snapshot_id": 9,
                "blocked_ticks": 3
            })
        );
        assert_eq!(
            safe_verdict(Some(9), Some(0.5), false, 120, 120, 2.0),
            json!({
                "kind": "blocked",
                "block_reason": "input_busy",
                "idle_seconds": 0.5
            })
        );
        assert_eq!(
            safe_verdict(Some(9), Some(2.0), false, 120, 120, 2.0),
            json!({"kind": "safe", "stale_composition_override": true})
        );
        assert_eq!(
            safe_verdict(None, None, false, 0, 120, 2.0),
            json!({"kind": "safe", "stale_composition_override": false})
        );

        assert_eq!(
            activation_verdict(true, 0, 60),
            json!({"kind": "present", "forced_without_active_confirm": false})
        );
        assert_eq!(
            activation_verdict(false, 60, 60),
            json!({"kind": "present", "forced_without_active_confirm": true})
        );
        assert_eq!(
            activation_verdict(false, 59, 60),
            json!({"kind": "waitNextTick"})
        );
    }

    #[test]
    fn test_suggest_recheck_and_error_classification() {
        assert!(should_suggest(Some("2.5.3"), "2.5.3"));
        assert!(!should_suggest(Some("2.5.2"), "2.5.3"));
        assert!(!should_suggest(Some(""), ""));

        assert_eq!(
            recheck_decision(Some(&[]), None),
            RecheckDecision::Recovered
        );
        assert_eq!(
            recheck_decision(Some(&["inputSource".into()]), None),
            RecheckDecision::Present
        );
        assert_eq!(recheck_decision(None, Some("err")), RecheckDecision::Present);

        assert_eq!(classify_logout_error(Some(-1743)), "automationDenied");
        assert_eq!(classify_logout_error(Some(-1712)), "timeout");
        assert_eq!(classify_logout_error(None), "other");
    }
}
