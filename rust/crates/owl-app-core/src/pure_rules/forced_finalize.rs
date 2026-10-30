use serde::{Deserialize, Serialize};

pub fn commit_text(preview: Option<&str>, input: &str) -> String {
    if let Some(p) = preview {
        if !p.is_empty() {
            return p.to_string();
        }
    }
    input.to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForcedFinalizePlan {
    pub commit_text: Option<String>,
    pub clear_composition: bool,
    pub emit_cleared: bool,
}

pub fn plan_forced_finalize(input: Option<&str>, preview: Option<&str>) -> ForcedFinalizePlan {
    let (commit_text_val, clear_composition) = match input {
        Some(inp) if !inp.is_empty() => {
            let text = commit_text(preview, inp);
            (Some(text), true)
        }
        _ => (None, false),
    };
    ForcedFinalizePlan {
        commit_text: commit_text_val,
        clear_composition,
        emit_cleared: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_forced_finalize_with_preview() {
        let plan = plan_forced_finalize(Some("nihao"), Some("你好"));
        assert_eq!(plan.commit_text, Some("你好".into()));
        assert!(plan.clear_composition);
        assert!(plan.emit_cleared);
    }

    #[test]
    fn test_forced_finalize_without_preview() {
        let plan = plan_forced_finalize(Some("nihao"), None);
        assert_eq!(plan.commit_text, Some("nihao".into()));
        assert!(plan.clear_composition);
        assert!(plan.emit_cleared);
    }

    #[test]
    fn test_forced_finalize_empty_input() {
        let plan = plan_forced_finalize(Some(""), None);
        assert_eq!(plan.commit_text, None);
        assert!(!plan.clear_composition);
        assert!(plan.emit_cleared);
    }
}
