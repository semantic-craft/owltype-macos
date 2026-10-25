use super::*;
use crate::ime::personal_rerank::allocations::count;

// 冻结优化前的音节筛选和排序，独立对照输出及结果物化的分配。
impl SpellingTable {
    fn frozen_spellings_for_into(
        &self,
        remaining: &str,
        locked_length: usize,
        split: Option<usize>,
        prior: &SyllablePrior,
        destination: &mut Vec<String>,
        matches: &mut Vec<usize>,
    ) {
        destination.clear();
        matches.clear();
        if remaining.is_empty() {
            return;
        }
        matches.extend(
            self.syllables
                .iter()
                .enumerate()
                .filter_map(|(index, (_, code))| {
                    let matches = match split {
                        Some(split) => code.len() <= split && remaining.starts_with(code.as_str()),
                        None => {
                            locked_length + remaining.len().max(code.len()) <= DIGIT_LIMIT
                                && (remaining.starts_with(code.as_str())
                                    || code.starts_with(remaining))
                        }
                    };
                    matches.then_some(index)
                }),
        );
        let covered = |code: &str| code.len().min(remaining.len());
        matches.sort_by(|&a, &b| {
            let (a, a_code) = &self.syllables[a];
            let (b, b_code) = &self.syllables[b];
            covered(b_code)
                .cmp(&covered(a_code))
                .then_with(|| {
                    if remaining.len() > 1 {
                        a_code.len().cmp(&b_code.len())
                    } else {
                        Ordering::Equal
                    }
                })
                .then_with(|| prior.syllable_score(b).total_cmp(&prior.syllable_score(a)))
                .then_with(|| a.cmp(b))
        });
        destination.extend(matches.iter().map(|&index| self.syllables[index].0.clone()));
    }
}

fn grids() -> [KeyGrid; 3] {
    let table =
        crate::nine_key_shuangpin::builtin_table(crate::types::NineKeyShuangpinKind::Migala3)
            .unwrap();
    let table = crate::nine_key_shuangpin::nine_key_shuangpin(&table).unwrap();
    [
        KeyGrid::NineKey,
        KeyGrid::FourteenKey,
        KeyGrid::NineKeyShuangpin(table),
    ]
}

#[test]
fn spelling_strings_keep_their_storage_on_warm_queries() {
    for grid in grids() {
        let table = grid.spelling_table();
        let prior = SyllablePrior::default();
        let digits = grid.encode("ni");
        let mut actual = Vec::new();
        let mut actual_matches = Vec::new();
        table.spellings_for_into(&digits, 0, None, &prior, &mut actual, &mut actual_matches);
        assert!(!actual.is_empty());
        let pointers: Vec<_> = actual.iter().map(|value| value.as_ptr()).collect();
        let mut expected = actual.clone();
        let mut expected_matches = actual_matches.clone();
        let ((), old) = count(|| {
            table.frozen_spellings_for_into(
                &digits,
                0,
                None,
                &prior,
                &mut expected,
                &mut expected_matches,
            )
        });
        let ((), new) = count(|| {
            table.spellings_for_into(&digits, 0, None, &prior, &mut actual, &mut actual_matches)
        });
        assert_eq!(actual, expected);
        assert_eq!(actual_matches, expected_matches);
        eprintln!(
            "读音字符串 {grid:?}/{digits}: {old} → {new}，{} 行",
            actual.len()
        );
        assert_eq!(
            new + actual.len(),
            old,
            "应省去每个已有音节字符串的克隆分配"
        );
        assert_eq!(
            actual
                .iter()
                .map(|value| value.as_ptr())
                .collect::<Vec<_>>(),
            pointers
        );
    }
}

#[test]
fn reused_spelling_rows_match_frozen_queries_across_grids_and_lengths() {
    for grid in grids() {
        let table = grid.spelling_table();
        let weights = table
            .syllables
            .iter()
            .enumerate()
            .map(|(i, (s, _))| (s.clone(), (i % 7 + 1) as i64))
            .collect();
        let prior = SyllablePrior::from_weights(&table.syllables, &weights);
        let mut actual = vec!["过期合成读音".to_owned(); 3];
        let mut actual_matches = vec![usize::MAX];
        let mut expected = actual.clone();
        let mut expected_matches = actual_matches.clone();
        for reading in ["nihao", "ni", "", "hao", "bad", "n", "zhong", "nihao", ""] {
            let digits = grid.encode(reading);
            for locked in [0, DIGIT_LIMIT - 1] {
                for split in [None, Some(0), Some(1), Some(digits.len())] {
                    table.frozen_spellings_for_into(
                        &digits,
                        locked,
                        split,
                        &prior,
                        &mut expected,
                        &mut expected_matches,
                    );
                    table.spellings_for_into(
                        &digits,
                        locked,
                        split,
                        &prior,
                        &mut actual,
                        &mut actual_matches,
                    );
                    assert_eq!(actual, expected, "{grid:?}/{digits}/{locked}/{split:?}");
                    assert_eq!(actual_matches, expected_matches);
                }
            }
        }
        for digits in ["?", "你好", ""] {
            table.spellings_for_into(digits, 0, None, &prior, &mut actual, &mut actual_matches);
            assert!(actual.is_empty());
            assert!(actual_matches.is_empty());
        }
    }
}
