use super::*;

// 冻结缓冲改动前的路径物化，用来证明热调用确实省掉最终路径存储分配。
fn frozen_split_paths(
    table: &SpellingTable,
    digits: &str,
    splits: &[usize],
    prior: &SyllablePrior,
    output_limit: usize,
) -> Vec<Path> {
    let length = digits.len();
    let mut suffix: Vec<Vec<SpellingPath<'_>>> = vec![Vec::new(); length + 1];
    suffix[length].push(SpellingPath {
        score: 0.0,
        complete: false,
        piece: "",
        next: (length, 0),
        length: 0,
    });
    for offset in (0..length).rev() {
        let mut result = Vec::new();
        for end in offset + 1..=length.min(offset + table.longest_code) {
            if splits.iter().any(|&split| offset < split && split < end) {
                break;
            }
            let Some(pieces) = table.by_code.get(&digits[offset..end]) else {
                continue;
            };
            let must_complete = end != length || splits.contains(&end);
            for (piece, complete) in pieces {
                if must_complete && !complete {
                    continue;
                }
                let score = prior.score(piece);
                for (row, tail) in suffix[end].iter().enumerate() {
                    if result.is_empty() {
                        result.reserve_exact(PATH_LIMIT);
                    }
                    result.push(SpellingPath {
                        score: score + tail.score,
                        complete: if tail.length == 0 {
                            *complete
                        } else {
                            tail.complete
                        },
                        piece,
                        next: (end, row),
                        length: tail.length + 1,
                    });
                }
            }
        }
        let compare = |a: &SpellingPath<'_>, b: &SpellingPath<'_>| {
            a.length
                .cmp(&b.length)
                .then_with(|| b.complete.cmp(&a.complete))
                .then_with(|| b.score.total_cmp(&a.score))
                .then_with(|| a.pieces(&suffix).cmp(b.pieces(&suffix)))
        };
        let keep = if offset == 0 {
            output_limit.min(PATH_LIMIT)
        } else {
            PATH_LIMIT
        };
        if keep < PATH_LIMIT && result.len() > keep {
            result.select_nth_unstable_by(keep, compare);
            result.truncate(keep);
        }
        result.sort_by(compare);
        result.truncate(keep);
        suffix[offset] = result;
    }
    std::mem::take(&mut suffix[0])
        .into_iter()
        .take(output_limit)
        .map(|root| {
            let mut path = Vec::with_capacity(root.length);
            path.extend(root.pieces(&suffix).map(str::to_owned));
            path
        })
        .collect()
}

#[test]
fn split_paths_into_reduces_warm_path_allocations() {
    let table = SpellingTable::build(KeyGrid::NineKey, &["ni", "mi", "o", "ma", "hao", "gao"]);
    let prior = SyllablePrior::default();
    let (expected, old_allocations) = crate::ime::personal_rerank::allocations::count(|| {
        frozen_split_paths(&table, "64426", &[], &prior, PATH_LIMIT)
    });
    let mut destination = Vec::new();
    table.split_paths_into("64426", &[], &prior, PATH_LIMIT, &mut destination);
    let ((), allocations) = crate::ime::personal_rerank::allocations::count(|| {
        table.split_paths_into("64426", &[], &prior, PATH_LIMIT, &mut destination);
    });
    assert_eq!(destination, expected);
    eprintln!("热路径分配：{old_allocations} → {allocations}");
    assert!(
        allocations < old_allocations,
        "{allocations} >= {old_allocations}"
    );
}

#[test]
fn split_paths_into_reuses_existing_path_strings() {
    let table = SpellingTable::build(KeyGrid::NineKey, &["ni", "mi", "o", "ma", "hao", "gao"]);
    let mut destination = Vec::new();
    table.split_paths_into(
        "64426",
        &[],
        &SyllablePrior::default(),
        PATH_LIMIT,
        &mut destination,
    );
    let pointer = destination[0][0].as_ptr();
    let capacity = destination[0][0].capacity();
    let (_, allocations) = crate::ime::personal_rerank::allocations::count(|| {
        table.split_paths_into(
            "64426",
            &[],
            &SyllablePrior::default(),
            PATH_LIMIT,
            &mut destination,
        );
    });
    assert!(allocations <= 5, "warm path allocations: {allocations}");
    assert_eq!(destination[0][0].as_ptr(), pointer);
    assert_eq!(destination[0][0].capacity(), capacity);
}

fn grids() -> [KeyGrid; 3] {
    let profile =
        crate::nine_key_shuangpin::builtin_table(crate::types::NineKeyShuangpinKind::Migala2)
            .unwrap();
    [
        KeyGrid::NineKey,
        KeyGrid::FourteenKey,
        KeyGrid::NineKeyShuangpin(crate::nine_key_shuangpin::nine_key_shuangpin(&profile).unwrap()),
    ]
}

#[test]
fn changing_paths_match_frozen_order_limits_and_owned_text() {
    for grid in grids() {
        let table = grid.spelling_table();
        let weights = table
            .syllables
            .iter()
            .enumerate()
            .map(|(index, (syllable, _))| (syllable.clone(), (index * 137 % 1021 + 1) as i64))
            .collect();
        for prior in [
            SyllablePrior::default(),
            SyllablePrior::from_weights(&table.syllables, &weights),
        ] {
            let mut destination = Vec::new();
            for reading in [
                "ni'hao",
                "o",
                "",
                "yi'dian'yi'dian",
                "shi'jie",
                "ni",
                "ma",
                "wo'jin'tian'qu'shang'ban",
                "ni'hao",
            ] {
                let digits = grid.encode(reading);
                for splits in [
                    vec![],
                    vec![digits.len() / 2],
                    vec![digits.len()],
                    (1..digits.len()).collect(),
                ] {
                    for limit in [PATH_LIMIT, 3, 1, 0, PATH_LIMIT + 1] {
                        let expected = frozen_split_paths(table, &digits, &splits, &prior, limit);
                        for _ in 0..2 {
                            table.split_paths_into(
                                &digits,
                                &splits,
                                &prior,
                                limit,
                                &mut destination,
                            );
                            assert_eq!(
                                destination, expected,
                                "{grid:?}/{reading}/{splits:?}/{limit}"
                            );
                        }
                    }
                }
            }
            for digits in ["!".repeat(32), "6!".to_owned()] {
                table.split_paths_into(&digits, &[], &prior, PATH_LIMIT, &mut destination);
                assert_eq!(
                    destination,
                    frozen_split_paths(table, &digits, &[], &prior, PATH_LIMIT)
                );
            }
        }
    }
}

#[test]
fn cold_paths_keep_frozen_allocation_budget() {
    for grid in grids() {
        let table = grid.spelling_table();
        let prior = SyllablePrior::default();
        for reading in ["", "o", "ni", "ni'hao", "yi'dian'yi'dian"] {
            let digits = grid.encode(reading);
            for limit in [0, 1, 3, PATH_LIMIT] {
                let (expected, old) = crate::ime::personal_rerank::allocations::count(|| {
                    frozen_split_paths(table, &digits, &[], &prior, limit)
                });
                let (actual, new) = crate::ime::personal_rerank::allocations::count(|| {
                    let mut destination = Vec::new();
                    table.split_paths_into(&digits, &[], &prior, limit, &mut destination);
                    destination
                });
                assert_eq!(actual, expected);
                assert_eq!(actual.capacity(), expected.capacity());
                assert_eq!(new, old, "{grid:?}/{reading}/{limit}");
            }
        }
    }
}
