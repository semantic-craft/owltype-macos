use super::allocations;
use super::*;
use std::collections::HashMap;

fn reply_runtime(rows: usize) -> Runtime<Fixture> {
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
fn sparse_replies_do_not_allocate_a_full_candidate_set() {
    let mut measurements = Vec::new();
    for rows in [32, 1024, 4096] {
        for glosses in [1, 7, 8] {
            let mut runtime = reply_runtime(rows);
            let reply: Vec<(String, String)> = (rows - glosses..rows)
                .map(|index| (format!("合成候选{index}"), "合成释义".into()))
                .collect();
            // 用已有同值释义隔离新增存储；输入的去重表仍允许分配。
            runtime.translations.extend(reply.iter().cloned());
            let baseline_reply = reply.clone();
            let (_, baseline_allocations, baseline_bytes) =
                allocations::count_bytes(|| baseline_reply.into_iter().collect::<HashMap<_, _>>());
            let epochs = (runtime.composition_epoch, runtime.candidates_epoch);
            let generation = runtime.generation;
            let (accepted, actual_allocations, actual_bytes) =
                allocations::count_bytes(|| runtime.apply_translations(generation, reply));
            assert!(accepted);
            assert_eq!(runtime.translations.len(), glosses);
            assert_eq!(
                (runtime.composition_epoch, runtime.candidates_epoch),
                epochs
            );
            for index in rows - glosses..rows {
                assert_eq!(
                    runtime.translations.get(&format!("合成候选{index}")),
                    Some(&"合成释义".to_owned())
                );
            }
            eprintln!(
                "rows={rows} glosses={glosses}: extra_allocations={} extra_requested_bytes={}",
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
        "稀疏回包过滤不应为全候选列表建集合: {measurements:?}"
    );
}

#[test]
fn reply_filter_preserves_merge_duplicates_and_empty_reply_semantics() {
    for rows in [0, 1, 8, 9, 32, 1024] {
        for glosses in [1, 8, 9, 32] {
            let mut runtime = reply_runtime(rows);
            let generation = runtime.generation;
            let mut expected = HashMap::new();
            if rows > 0 {
                expected.insert("合成候选0".to_owned(), "已有释义".to_owned());
                if rows > 1 {
                    expected.insert(format!("合成候选{}", rows - 1), "未回答释义".to_owned());
                }
                assert!(runtime.apply_translations(generation, expected.clone()));
            }
            let mut reply = Vec::new();
            for index in 0..glosses {
                let key = if index < rows {
                    format!("合成候选{index}")
                } else {
                    format!("范围外{index}")
                };
                reply.push((key.clone(), "较早释义".into()));
                reply.push((key.clone(), "最终释义".into()));
                if index < rows {
                    expected.insert(key, "最终释义".to_owned());
                }
            }
            let before = runtime.candidates_epoch;
            assert!(runtime.apply_translations(generation, reply.clone()));
            assert_eq!(runtime.translations, expected);
            assert_eq!(runtime.candidates_epoch != before, rows > 0);
            let before = runtime.candidates_epoch;
            assert!(runtime.apply_translations(generation, reply));
            assert_eq!(runtime.candidates_epoch, before);
            assert!(
                runtime.apply_translations(generation, [("不在候选中".into(), "不应用".into())])
            );
            assert_eq!(
                runtime.translations, expected,
                "非空回包过滤完为空不能清理已显示释义"
            );
            assert_eq!(runtime.candidates_epoch, before);
            assert!(runtime.apply_translations(generation, []));
            assert!(runtime.translations.is_empty());
            assert_eq!(runtime.candidates_epoch != before, !expected.is_empty());
            let before = runtime.candidates_epoch;
            assert!(runtime.apply_translations(generation, []));
            assert_eq!(runtime.candidates_epoch, before);
        }
    }
}

#[test]
fn stale_reply_is_rejected_before_consuming_the_iterator() {
    let mut runtime = reply_runtime(32);
    let generation = runtime.generation;
    let (_, count, bytes) = allocations::count_bytes(|| {
        assert!(!runtime.apply_translations(
            generation.wrapping_add(1),
            std::iter::from_fn(|| -> Option<(String, String)> {
                panic!("旧代次回包不应消费迭代器")
            }),
        ));
    });
    assert_eq!((count, bytes), (0, 0));
}

#[test]
fn dense_replies_on_small_candidate_lists_need_no_set_storage() {
    for rows in [0, 1, 8] {
        for glosses in [9, 32] {
            let mut runtime = reply_runtime(rows);
            let reply: Vec<(String, String)> = (0..glosses)
                .map(|index| (format!("合成候选{index}"), "合成释义".into()))
                .collect();
            runtime
                .translations
                .extend(reply.iter().take(rows).cloned());
            let baseline_reply = reply.clone();
            let (_, baseline_allocations, baseline_bytes) =
                allocations::count_bytes(|| baseline_reply.into_iter().collect::<HashMap<_, _>>());
            let epoch = runtime.candidates_epoch;
            let generation = runtime.generation;
            let (accepted, count, bytes) =
                allocations::count_bytes(|| runtime.apply_translations(generation, reply));
            assert!(accepted);
            assert_eq!(runtime.translations.len(), rows);
            assert_eq!(runtime.candidates_epoch, epoch);
            assert!(count <= baseline_allocations && bytes <= baseline_bytes,
                "小候选列表无需临时集合: rows={rows} glosses={glosses} allocations={count}/{baseline_allocations} bytes={bytes}/{baseline_bytes}");
        }
    }
}
