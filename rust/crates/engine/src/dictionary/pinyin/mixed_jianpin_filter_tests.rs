use super::*;
use crate::dictionary::fixtures::pinyin_db;
use crate::ime::personal_rerank::allocations::{count, measure};

fn segments(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|part| (*part).to_owned()).collect()
}

fn legacy_query_single_cut_keyed(
    database: &PinyinDatabase,
    segments: &[String],
    limit: usize,
    source: QuerySource,
) -> Vec<DictRow> {
    let Some(table) = build_table_name(segments) else {
        return Vec::new();
    };
    let key = join_segments(segments);
    let jp = segments_to_jianpin(segments);
    let bound = sql_limit(limit);
    if can_match_exact_key(segments) {
        let rows = database.rows(
            &exact_sql(&table, bound),
            [key.as_str()],
            query_capacity(limit),
        );
        if !rows.is_empty() {
            return rows;
        }
    }
    let pattern = build_key_like_pattern(segments);
    let prefix = &pattern[..pattern.len() - 1];
    let upper_bound = key_prefix_upper_bound(prefix);
    let rows = database.rows(
        &range_sql(&table, bound),
        [prefix, upper_bound.as_str()],
        query_capacity(limit),
    );
    if !rows.is_empty() {
        return rows;
    }
    if needs_mixed_jianpin_query(segments, source) {
        let scan_limit_value = build_mixed_jianpin_scan_limit(limit);
        let scan_limit = sql_limit(scan_limit_value);
        let mut rows = Vec::with_capacity(limit.min(128));
        rows.extend(
            database
                .rows(
                    &jianpin_sql(&table, scan_limit),
                    [jp.as_str()],
                    query_capacity(scan_limit_value),
                )
                .into_iter()
                .filter(|row| matches_mixed_segments(&row.key, segments, source))
                .take(limit),
        );
        if !rows.is_empty() {
            return rows;
        }
    }
    if !is_pure_jianpin(segments) {
        return Vec::new();
    }
    database.rows(
        &jianpin_sql(&table, bound),
        [jp.as_str()],
        query_capacity(limit),
    )
}

fn mixed_fixture(directory: &std::path::Path, matching: bool) -> std::path::PathBuf {
    let rows: Vec<_> = (0..160)
        .map(|index| {
            let key = if matching && index == 0 {
                "ni'hao"
            } else {
                "ni'hai"
            };
            let weight = if matching && index == 0 {
                1_000
            } else {
                index as i64
            };
            ("tbl_2_n", key, "合成", weight)
        })
        .collect();
    let borrowed: Vec<_> = rows
        .iter()
        .map(|(table, key, value, weight)| (*table, *key, *value, *weight))
        .collect();
    pinyin_db(directory, &borrowed)
}

#[test]
fn mixed_filter_preserves_output_capacity_and_order() {
    let directory = tempfile::tempdir().unwrap();
    let path = mixed_fixture(directory.path(), true);
    let database = PinyinDatabase::open(&path);
    let input = segments(&["n", "hao"]);
    for limit in [1, 2, 64, 128, usize::MAX] {
        let legacy = legacy_query_single_cut_keyed(&database, &input, limit, QuerySource::Quanpin);
        let actual = database.query_single_cut_keyed(&input, limit, QuerySource::Quanpin);
        assert_eq!(actual, legacy);
        assert_eq!(actual.capacity(), legacy.capacity());
        assert_eq!(actual.len(), 1);
        assert_eq!(actual[0].value, "合成");
    }
}

#[test]
fn mixed_filter_miss_keeps_zero_capacity_without_changing_cascade() {
    let directory = tempfile::tempdir().unwrap();
    let path = mixed_fixture(directory.path(), false);
    let database = PinyinDatabase::open(&path);
    let input = segments(&["n", "hao"]);
    let legacy = legacy_query_single_cut_keyed(&database, &input, 1, QuerySource::Quanpin);
    let actual = database.query_single_cut_keyed(&input, 1, QuerySource::Quanpin);
    assert_eq!(actual, legacy);
    assert!(actual.is_empty());
    assert_eq!(legacy.capacity(), 0);
    assert_eq!(actual.capacity(), legacy.capacity());
}

#[test]
fn mixed_filter_cold_query_has_no_extra_page_peak() {
    let directory = tempfile::tempdir().unwrap();
    let path = mixed_fixture(directory.path(), true);
    let input = segments(&["n", "hao"]);
    let _ = intact_pinyin_set();
    let run = |legacy: bool| {
        measure(|| {
            let database = PinyinDatabase::open(&path);
            let rows = if legacy {
                legacy_query_single_cut_keyed(&database, &input, 1, QuerySource::Quanpin)
            } else {
                database.query_single_cut_keyed(&input, 1, QuerySource::Quanpin)
            };
            drop(database);
            rows
        })
    };
    let (legacy, old) = run(true);
    let (actual, new) = run(false);
    assert_eq!(actual, legacy);
    assert_eq!(old.minimum_bytes, 0);
    assert_eq!(new.minimum_bytes, 0);
    assert_eq!(new.remaining_bytes, old.remaining_bytes);
    eprintln!("混合简拼冷查询：旧 {old:?}，新 {new:?}");
    assert!(new.allocations < old.allocations);
    assert!(new.peak_bytes < old.peak_bytes);
}

#[test]
fn mixed_filter_hot_query_has_the_same_allocation_budget() {
    let directory = tempfile::tempdir().unwrap();
    let path = mixed_fixture(directory.path(), true);
    let database = PinyinDatabase::open(&path);
    let input = segments(&["n", "hao"]);
    drop(legacy_query_single_cut_keyed(
        &database,
        &input,
        1,
        QuerySource::Quanpin,
    ));
    drop(database.query_single_cut_keyed(&input, 1, QuerySource::Quanpin));
    let (_, old) =
        count(|| legacy_query_single_cut_keyed(&database, &input, 1, QuerySource::Quanpin));
    let (_, new) = count(|| database.query_single_cut_keyed(&input, 1, QuerySource::Quanpin));
    eprintln!("混合简拼热查询分配：旧 {old}，新 {new}");
    assert!(new < old);
}

#[test]
fn mixed_filter_stops_after_limit_without_changing_dense_rows() {
    let directory = tempfile::tempdir().unwrap();
    let rows: Vec<_> = (0..160)
        .map(|index| ("tbl_2_n", "ni'hao", "合成", index as i64))
        .collect();
    let borrowed: Vec<_> = rows
        .iter()
        .map(|(table, key, value, weight)| (*table, *key, *value, *weight))
        .collect();
    let path = pinyin_db(directory.path(), &borrowed);
    let database = PinyinDatabase::open(&path);
    let input = segments(&["n", "hao"]);
    for limit in [1, 2, 64, 128] {
        let legacy = legacy_query_single_cut_keyed(&database, &input, limit, QuerySource::Quanpin);
        let actual = database.query_single_cut_keyed(&input, limit, QuerySource::Quanpin);
        assert_eq!(actual, legacy);
        assert_eq!(actual.capacity(), legacy.capacity());
    }
}

#[test]
fn mixed_filter_preserves_query_source_and_pure_fallback_semantics() {
    let directory = tempfile::tempdir().unwrap();
    let path = pinyin_db(
        directory.path(),
        &[
            ("tbl_2_s", "shi'jian", "时间", 10),
            ("tbl_2_s", "si'jian", "四件", 9),
            ("tbl_2_n", "ni'hao", "你好", 8),
        ],
    );
    let database = PinyinDatabase::open(&path);
    let shuangpin = segments(&["sh", "jian"]);
    let legacy = legacy_query_single_cut_keyed(&database, &shuangpin, 8, QuerySource::Shuangpin);
    let actual = database.query_single_cut_keyed(&shuangpin, 8, QuerySource::Shuangpin);
    assert_eq!(actual, legacy);
    assert_eq!(
        actual
            .iter()
            .map(|row| row.value.as_str())
            .collect::<Vec<_>>(),
        ["时间"]
    );

    let pure = segments(&["n", "h"]);
    let legacy = legacy_query_single_cut_keyed(&database, &pure, 8, QuerySource::Quanpin);
    let actual = database.query_single_cut_keyed(&pure, 8, QuerySource::Quanpin);
    assert_eq!(actual, legacy);
    assert_eq!(actual[0].value, "你好");
}

#[test]
fn mixed_filter_preserves_first_step_conversion_error_semantics() {
    let directory = tempfile::tempdir().unwrap();
    let path = pinyin_db(directory.path(), &[]);
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE VIEW tbl_2_n AS SELECT 'ni' || char(39) || 'hao' AS key, 'nh' AS jp, '合成甲' AS value, 2 AS weight UNION ALL SELECT 'ni' || char(39) || 'hao' AS key, 'nh' AS jp, '合成乙' AS value, abs(-9223372036854775808) AS weight UNION ALL SELECT 'ni' || char(39) || 'hao' AS key, 'nh' AS jp, '合成丙' AS value, 1 AS weight;",
        )
        .unwrap();
    drop(connection);
    let database = PinyinDatabase::open(&path);
    let input = segments(&["n", "hao"]);
    let legacy = legacy_query_single_cut_keyed(&database, &input, 8, QuerySource::Quanpin);
    let actual = database.query_single_cut_keyed(&input, 8, QuerySource::Quanpin);
    assert_eq!(actual, legacy);
    assert!(actual.is_empty());
}
