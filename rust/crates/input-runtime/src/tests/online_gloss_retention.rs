use super::allocations;
use super::*;

fn large_runtime(rows: usize) -> Runtime<Fixture> {
    Runtime::new(
        Fixture {
            words: (0..rows).map(|index| format!("合成候选{index}")).collect(),
            codes: vec![String::new(); rows],
            text: "a".into(),
            ..Fixture::default()
        },
        5,
    )
    .unwrap()
}

#[test]
fn sparse_online_gloss_retention_needs_no_extra_allocations() {
    let mut measurements = Vec::new();
    for rows in [32, 1024, 4096] {
        let mut baseline = large_runtime(rows);
        let (_, baseline_allocations, baseline_bytes) =
            allocations::count_bytes(|| baseline.refresh().unwrap());
        for glosses in [0, 1, 8] {
            let mut runtime = large_runtime(rows);
            for index in (rows - glosses)..rows {
                runtime
                    .translations
                    .insert(format!("合成候选{index}"), "合成释义".into());
            }
            let generation = runtime.generation;
            let (_, actual_allocations, actual_bytes) =
                allocations::count_bytes(|| runtime.refresh_online_candidates().unwrap());
            assert_eq!(runtime.translations.len(), glosses);
            assert_eq!(runtime.generation, generation);
            eprintln!(
                "rows={rows} glosses={glosses}: retention extra allocations={} requested_bytes={}",
                actual_allocations.saturating_sub(baseline_allocations),
                actual_bytes.saturating_sub(baseline_bytes)
            );
            measurements.push((
                rows,
                glosses,
                actual_allocations,
                baseline_allocations,
                actual_bytes,
                baseline_bytes,
            ));
        }
    }
    assert!(
        measurements
            .iter()
            .all(
                |(_, _, actual, baseline, bytes, baseline_bytes)| actual <= baseline
                    && bytes <= baseline_bytes
            ),
        "无释义或稀疏释义的保留不应为全列表创建临时哈希集合: {measurements:?}"
    );
}

#[test]
fn online_gloss_retention_keeps_only_the_before_and_after_intersection() {
    for glosses in [1, 7, 8, 9, 64] {
        let mut runtime = large_runtime(80);
        for index in 0..glosses {
            runtime
                .translations
                .insert(format!("合成候选{index}"), format!("合成释义{index}"));
        }
        // 直接注入尚未出现在旧列表的条目，检查刷新后新增同文候选也不能继承它。
        runtime
            .translations
            .insert("合成新增".into(), "不得继承".into());
        runtime.engine.words[0] = "合成新增".into();
        runtime.engine.words.push("合成候选1".into());
        runtime.engine.codes.push(String::new());
        runtime.refresh_online_candidates().unwrap();
        assert_eq!(runtime.translations.len(), glosses - 1);
        assert!(!runtime.translations.contains_key("合成候选0"));
        assert!(!runtime.translations.contains_key("合成新增"));
        for index in 1..glosses {
            assert_eq!(
                runtime.translations.get(&format!("合成候选{index}")),
                Some(&format!("合成释义{index}"))
            );
        }
    }
}

#[test]
fn dense_glosses_shrink_to_a_small_or_empty_candidate_list() {
    for remaining in [0, 1, 8, 9] {
        let mut runtime = large_runtime(32);
        for index in 0..32 {
            runtime
                .translations
                .insert(format!("合成候选{index}"), format!("合成释义{index}"));
        }
        runtime.engine.words.truncate(remaining);
        runtime.engine.codes.truncate(remaining);
        runtime.refresh_online_candidates().unwrap();
        assert_eq!(runtime.translations.len(), remaining);
        for index in 0..remaining {
            assert_eq!(
                runtime.translations.get(&format!("合成候选{index}")),
                Some(&format!("合成释义{index}"))
            );
        }
    }
}
