use super::*;
use crate::ime::personal_rerank::allocations;

// 保留优化前的完整排序、全列表去重和截断，作为排名及回溯字段的对照。
fn reference_finalize(list: &mut Vec<Hypothesis>, k: usize) {
    if list.len() < 2 {
        return;
    }
    list.sort_by_key(|hypothesis| (hypothesis.edge_count, hypothesis.weight, hypothesis.arrival));
    if list.len() <= 36 {
        let mut write = 0;
        for read in 0..list.len() {
            if list[..write]
                .iter()
                .any(|hypothesis| hypothesis.sequence == list[read].sequence)
            {
                continue;
            }
            if write != read {
                list.swap(write, read);
            }
            write += 1;
        }
        list.truncate(write);
        list.truncate(k);
        return;
    }
    let mut seen = HashSet::with_capacity(list.len());
    list.retain(|hypothesis| seen.insert(hypothesis.sequence));
    list.truncate(k);
}

fn hypotheses(count: usize, unique: usize) -> Vec<Hypothesis> {
    (0..count)
        .map(|arrival| Hypothesis {
            edge_count: arrival % 4,
            prev_index: arrival % 9,
            arrival,
            weight: ((arrival * 17) % 39) as i32,
            raw_length: 1 + arrival % 6,
            syllable: if arrival % 2 == 0 { "shi" } else { "ni" },
            corrected: arrival % 4 != 0,
            sequence: arrival % unique,
        })
        .collect()
}

fn assert_same(actual: &[Hypothesis], expected: &[Hypothesis]) {
    assert_eq!(actual.len(), expected.len());
    for (actual, expected) in actual.iter().zip(expected) {
        assert_eq!(actual.edge_count, expected.edge_count);
        assert_eq!(actual.prev_index, expected.prev_index);
        assert_eq!(actual.arrival, expected.arrival);
        assert_eq!(actual.weight, expected.weight);
        assert_eq!(actual.raw_length, expected.raw_length);
        assert_eq!(actual.syllable, expected.syllable);
        assert_eq!(actual.corrected, expected.corrected);
        assert_eq!(actual.sequence, expected.sequence);
    }
}

#[test]
fn finalize_matches_full_dedup_across_beam_and_output_boundaries() {
    for count in [0, 1, 2, 9, 35, 36, 37, 128, 512] {
        for unique in [1, 2, 8, 9, 35, 36, 37, 128, 512] {
            for k in [1, 2, 9, 35, 36, 37, 128, 513] {
                let rows = hypotheses(count, unique);
                let mut expected = rows.clone();
                reference_finalize(&mut expected, k);
                let mut search = Search::new(1, k);
                search.best[1] = rows;
                search.finalize(1);
                assert_same(&search.best[1], &expected);
            }
        }
    }
}

#[test]
fn finalize_large_beams_with_small_output_needs_no_temporary_allocations() {
    for k in [1, 9, 36] {
        for unique in [1, 9, 37, 512] {
            let rows = hypotheses(512, unique);
            let mut expected = rows.clone();
            reference_finalize(&mut expected, k);
            let mut search = Search::new(1, k);
            search.best[1] = rows;
            let ((), allocations) = allocations::count(|| search.finalize(1));
            assert_same(&search.best[1], &expected);
            assert_eq!(allocations, 0, "k={k}, unique={unique}");
        }
    }
}

#[test]
#[ignore = "手动运行 release 性能对照；不以机器相关耗时作为单测门禁"]
fn benchmark_bounded_finalize_against_full_dedup() {
    use std::hint::black_box;
    use std::time::{Duration, Instant};

    fn measure(rows: &[Hypothesis], k: usize, optimized: bool) -> Duration {
        let mut search = Search::new(1, k);
        search.best[1].reserve(rows.len());
        let mut elapsed = Duration::ZERO;
        for _ in 0..20_000 {
            search.best[1].clear();
            search.best[1].extend_from_slice(rows);
            let start = Instant::now();
            if optimized {
                search.finalize(1);
            } else {
                reference_finalize(&mut search.best[1], k);
            }
            elapsed += start.elapsed();
            black_box(&search.best[1]);
        }
        elapsed
    }

    for (count, unique, k) in [
        (36, 18, 9),
        (128, 64, 9),
        (512, 256, 9),
        (512, 256, 1),
        (512, 256, 128),
    ] {
        let rows = hypotheses(count, unique);
        let baseline = measure(&rows, k, false);
        let optimized = measure(&rows, k, true);
        eprintln!("count={count}, unique={unique}, k={k}: baseline={baseline:?}, optimized={optimized:?}, ratio={:.3}", optimized.as_secs_f64() / baseline.as_secs_f64());
    }
}
