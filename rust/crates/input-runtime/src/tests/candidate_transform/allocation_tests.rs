use super::*;

use crate::tests::allocations;

fn large_engine(count: usize) -> TransformEngine {
    TransformEngine {
        words: (0..count).map(|index| format!("合成候选{index}")).collect(),
        ..TransformEngine::default()
    }
}

#[test]
fn unchanged_plugin_refresh_without_recorded_ops_needs_no_identity_allocations() {
    let mut harness = Harness::new(large_engine(1024), vec![CandidateOps::default()]);
    harness.key(b'a');
    let calls = harness.calls();

    let (changed, allocations) = allocations::count(|| harness.runtime.transform_candidates());

    assert!(!changed);
    assert_eq!(harness.calls(), calls);
    assert_eq!(allocations, 0, "未记录操作的旁路刷新不应创建候选身份");
}

#[test]
fn replay_of_one_annotation_has_a_bounded_identity_allocation_budget() {
    let mut measurements = Vec::new();
    for count in [32, 1024, 4096] {
        let mut harness =
            Harness::new(large_engine(count), vec![ops(&[], &[], &[(1, "合成注释")])]);
        harness.key(b'a');
        let calls = harness.calls();

        let (changed, allocations) = allocations::count(|| harness.runtime.transform_candidates());

        eprintln!("rows={count}: identity replay allocations={allocations}");
        assert!(!changed);
        assert_eq!(harness.calls(), calls);
        assert_eq!(
            harness.runtime.script_annotation(1).as_deref(),
            Some("合成注释")
        );
        measurements.push((count, allocations));
    }
    assert!(
        measurements
            .iter()
            .all(|(_, allocations)| *allocations == 0),
        "身份重放不应重复申请工作区: {measurements:?}"
    );
}

#[test]
fn repeated_plugin_replays_reuse_arrangement_buffers() {
    let mut harness = Harness::new(
        large_engine(128),
        vec![ops(&[127, 2, 64], &[3, 65], &[(1, "合成注释")])],
    );
    harness.key(b'a');

    let (_, first_allocations) = allocations::count(|| harness.runtime.transform_candidates());
    let (_, second_allocations) = allocations::count(|| harness.runtime.transform_candidates());

    eprintln!(
        "repeated plugin replay allocations: first={first_allocations}, second={second_allocations}"
    );
    assert_eq!(
        first_allocations, 0,
        "候选变换重放仍在首次旁路调用申请排列工作区：{first_allocations}"
    );
    assert_eq!(
        second_allocations, 0,
        "候选变换重放仍在后续旁路调用申请排列工作区：{second_allocations}"
    );
}

#[test]
fn duplicate_identity_follows_engine_order_across_the_plugin_window() {
    let mut engine = large_engine(40);
    engine.words[1] = "重复候选".into();
    engine.words[35] = "重复候选".into();
    let mut harness = Harness::new(engine, vec![ops(&[], &[], &[(1, "第一条重复")])]);
    harness.key(b'a');

    // 模拟内置重排：第二条重复进入首屏，已被注释的第一条移到插件窗口之外。
    let mut order = vec![35];
    order.extend((0..40).filter(|seat| *seat != 1 && *seat != 35));
    order.push(1);
    harness.runtime.apply_candidate_order(&order);
    harness.runtime.transform_candidates();
    assert_eq!(harness.runtime.script_annotation(0), None);
    assert_eq!(
        harness.runtime.script_annotation(39).as_deref(),
        Some("第一条重复")
    );

    // 重取快照并插入不同文本，记录仍跟随引擎的第一条重复，不运行插件。
    harness.runtime.engine.words.insert(1, "插入候选".into());
    harness.runtime.refresh_online_candidates().unwrap();
    assert_eq!(
        harness.runtime.script_annotation(2).as_deref(),
        Some("第一条重复")
    );
    assert_eq!(harness.runtime.script_annotation(36), None);
    assert_eq!(harness.calls(), 1);
}
