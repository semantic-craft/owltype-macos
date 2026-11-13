use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct PracticeProof {
    pub has_owl_commit: bool,
    pub has_other_source: bool,
}

impl PracticeProof {
    pub const TARGET: &'static str = "你好，法墨";

    pub fn inserted(&mut self, from_owl: bool, had_composition: bool) {
        self.has_other_source = self.has_other_source || !from_owl;
        self.has_owl_commit = self.has_owl_commit || (from_owl && had_composition);
    }

    pub fn is_complete(&self, text: &str, has_marked_text: bool) -> bool {
        text == Self::TARGET && self.has_owl_commit && !self.has_other_source && !has_marked_text
    }

    pub fn hint(&self) -> Option<&'static str> {
        if self.has_other_source {
            Some("包含其他输入法的内容，请清空后用法墨重新输入。")
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_practice_proof_completion() {
        let mut proof = PracticeProof::default();
        assert!(!proof.is_complete("你好，法墨", false));

        proof.inserted(true, true);
        assert!(proof.is_complete("你好，法墨", false));
        assert!(!proof.is_complete("你好，法墨", true));
        assert_eq!(proof.hint(), None);

        proof.inserted(false, false);
        assert!(!proof.is_complete("你好，法墨", false));
        assert_eq!(
            proof.hint(),
            Some("包含其他输入法的内容，请清空后用法墨重新输入。")
        );
    }
}
