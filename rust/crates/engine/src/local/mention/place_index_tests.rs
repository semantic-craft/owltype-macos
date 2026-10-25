use super::*;
use std::hint::black_box;
use std::time::{Duration, Instant};

type Lookup =
    fn(&Places, &str, &[&str], usize) -> ([(&'static str, &'static str); RESULT_LIMIT], usize);

const BENCH_CODES: [&str; 7] = ["b", "bei", "bj", "zh", "shenzhen", "luanshi", "zzzz"];

#[test]
#[ignore = "局部 CPU 基准需手动在 release 模式运行，避免共享 CI 主机计时干扰"]
fn indexed_place_lookup_reduces_scan_cpu() {
    let table = places();
    let mut old_samples = [Duration::ZERO; 7];
    let mut new_samples = [Duration::ZERO; 7];
    let measure = |lookup: Lookup| {
        let start = Instant::now();
        for _ in 0..200 {
            for code in BENCH_CODES {
                black_box(lookup(black_box(table), black_box(code), &[], RESULT_LIMIT));
            }
        }
        start.elapsed()
    };
    for code in BENCH_CODES {
        assert_eq!(
            collect_place_matches(table, code, &[], RESULT_LIMIT),
            frozen_place_scan(table, code, &[], RESULT_LIMIT)
        );
    }
    for index in 0..old_samples.len() {
        if index % 2 == 0 {
            old_samples[index] = measure(frozen_place_scan);
            new_samples[index] = measure(collect_place_matches);
        } else {
            new_samples[index] = measure(collect_place_matches);
            old_samples[index] = measure(frozen_place_scan);
        }
    }
    old_samples.sort_unstable();
    new_samples.sort_unstable();
    let old = old_samples[old_samples.len() / 2];
    let new = new_samples[new_samples.len() / 2];
    eprintln!("地点匹配局部基准：全表扫描={old:?}，当前查询={new:?}，每批1400查询，七批中位数");
    assert!(
        new.as_nanos() * 2 < old.as_nanos(),
        "索引查询应至少减少一半局部扫描耗时：old={old:?}, new={new:?}"
    );
}

#[test]
fn indexed_output_matches_frozen_scan_for_complete_spellings() {
    let table = places();
    let mut queries = std::collections::BTreeSet::from(["", "zzzz", "BEI", "bei'", "北京", "é"]);
    for spelling in table.spellings.iter().flatten() {
        queries.insert(spelling.as_str());
        for (position, letter) in spelling.char_indices().take(2) {
            queries.insert(&spelling[..position + letter.len_utf8()]);
        }
    }
    for code in queries {
        assert_eq!(
            collect_place_matches(table, code, &[], RESULT_LIMIT),
            frozen_place_scan(table, code, &[], RESULT_LIMIT),
            "code={code:?}"
        );
    }
}

#[test]
#[ignore = "逐查询 CPU 基准需手动在 release 模式运行"]
fn indexed_lookup_reports_dense_and_early_exact_queries() {
    let table = places();
    for (code, limit) in ('a'..='z')
        .map(|letter| (letter.to_string(), RESULT_LIMIT))
        .chain([("bjs".to_owned(), 1), ("beijingshi".to_owned(), 1)])
    {
        let measure = |lookup: Lookup| {
            let start = Instant::now();
            for _ in 0..2000 {
                black_box(lookup(
                    black_box(table),
                    black_box(&code),
                    &[],
                    black_box(limit),
                ));
            }
            start.elapsed()
        };
        let mut old = [Duration::ZERO; 7];
        let mut new = [Duration::ZERO; 7];
        for index in 0..7 {
            if index % 2 == 0 {
                old[index] = measure(frozen_place_scan);
                new[index] = measure(collect_place_matches);
            } else {
                new[index] = measure(collect_place_matches);
                old[index] = measure(frozen_place_scan);
            }
        }
        old.sort_unstable();
        new.sort_unstable();
        eprintln!(
            "code={code}, limit={limit}, 原扫描={:?}, 索引={:?}，2000查询中位数",
            old[3], new[3]
        );
        if limit == 1 {
            assert!(
                new[3].as_nanos() < old[3].as_nanos() * 2,
                "首行精确命中不应退化超过计时容差：code={code}, old={:?}, new={:?}",
                old[3],
                new[3]
            );
        } else {
            assert!(new[3] < old[3], "单字符查询应减少扫描耗时：code={code}");
        }
    }
}

#[test]
fn indexed_output_preserves_limits_and_existing_name_filtering() {
    let table = places();
    for code in [
        "",
        "b",
        "bei",
        "bj",
        "bjs",
        "beijingshi",
        "shenzhen",
        "zzzz",
    ] {
        for limit in [0, 1, 2, 17, 18, 19] {
            for existing in [
                &[][..],
                &["北京市"][..],
                &["北京市", "深圳市", "北海市"][..],
            ] {
                assert_eq!(
                    collect_place_matches(table, code, existing, limit),
                    frozen_place_scan(table, code, existing, limit),
                    "code={code:?}, limit={limit}, existing={existing:?}"
                );
            }
        }
    }
}

// 冻结本轮优化前的全表扫描，沿用上一轮的固定结果数组，避免把分配收益重复归因。
fn frozen_place_scan(
    table: &Places,
    code: &str,
    existing_names: &[&str],
    limit: usize,
) -> ([(&'static str, &'static str); RESULT_LIMIT], usize) {
    let limit = limit.min(RESULT_LIMIT);
    let mut exact = [("", ""); RESULT_LIMIT];
    if limit == 0 {
        return (exact, 0);
    }
    let mut exact_len = 0;
    let mut prefix = [("", ""); RESULT_LIMIT];
    let mut prefix_len = 0;
    let mut matched_names = [None; PLACE_MATCH_CAPACITY];
    let mut matched_names_len = 0;
    for (place, spellings) in table.places.iter().zip(&table.spellings) {
        let Some(is_exact) = spelling_match(spellings, code) else {
            continue;
        };
        if existing_names.contains(&place.name)
            || matched_names[..matched_names_len]
                .iter()
                .flatten()
                .any(|name| *name == place.name)
        {
            continue;
        }
        if is_exact {
            if exact_len == limit {
                continue;
            }
            exact[exact_len] = (place.key, place.name);
            exact_len += 1;
        } else if prefix_len < limit {
            prefix[prefix_len] = (place.key, place.name);
            prefix_len += 1;
        } else {
            continue;
        }
        matched_names[matched_names_len] = Some(place.name);
        matched_names_len += 1;
        if exact_len == limit {
            break;
        }
    }
    let prefix_len = prefix_len.min(limit.saturating_sub(exact_len));
    exact[exact_len..exact_len + prefix_len].copy_from_slice(&prefix[..prefix_len]);
    (exact, exact_len + prefix_len)
}
