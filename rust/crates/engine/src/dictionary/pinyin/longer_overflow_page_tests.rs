use super::*;
use crate::ime::personal_rerank::allocations::{count, measure};

// 固定 e35a30f5cf5a38557f5790321916a5e16c64c927 的完整旧查询，只改方法名并移除注释。
impl PinyinDatabase {
    fn legacy_query_longer_phrases(
        &self,
        segments: &[String],
        extra_syllables: usize,
        limit: usize,
    ) -> Vec<DictRow> {
        if self.connection.is_none()
            || segments.len() < 2
            || extra_syllables == 0
            || limit == 0
            || !has_only_complete_pinyin_segments(segments)
        {
            return Vec::new();
        }
        let prefix = longer_phrase_prefix(segments);
        let upper_bound = key_prefix_upper_bound(&prefix);
        let initial = segments[0].as_bytes()[0];
        let mut rows = Vec::new();
        for extra in 1..=extra_syllables {
            let Some(table) = quanpin_table(segments.len() + extra, initial) else {
                continue;
            };
            let page = self.rows(
                &range_sql(&table, sql_limit(limit)),
                [prefix.as_str(), upper_bound.as_str()],
                query_capacity(limit),
            );
            if !page.is_empty() {
                if rows.is_empty() && page.len() == limit {
                    rows = page;
                    continue;
                }
                let remaining_pages = extra_syllables - extra + 1;
                let planned = if page.len() == limit {
                    remaining_pages.saturating_mul(limit)
                } else {
                    page.len()
                };
                let required = rows
                    .len()
                    .saturating_add(planned)
                    .saturating_sub(rows.capacity());
                if required != 0 {
                    rows.reserve_exact(required);
                }
            }
            rows.extend(page);
        }
        deduplicate_by_value(&mut rows);
        rows.sort_by_key(|row| std::cmp::Reverse(row.weight));
        rows.truncate(limit);
        rows
    }
}

fn fixture(per_length: usize) -> PinyinDatabase {
    let connection = Connection::open_in_memory().unwrap();
    connection.set_prepared_statement_cache_capacity(STATEMENT_CACHE_CAPACITY);
    for syllables in 3..=10 {
        let table = quanpin_table(syllables, b'p').unwrap();
        connection
            .execute_batch(&format!(
                "CREATE TABLE IF NOT EXISTS {table}(key TEXT, value TEXT, weight INTEGER);"
            ))
            .unwrap();
        let key = format!("ping'guo{}", "'a".repeat(syllables - 2));
        for index in 0..per_length {
            let value = if index == 0 && (syllables == 7 || syllables == 8) {
                "合成跨表同值".to_owned()
            } else {
                format!("合成{syllables:02}/{index:02}😀")
            };
            let weight = match index {
                0 if syllables == 8 => i64::MAX,
                0 | 1 => 100,
                2 => -7,
                _ => 0,
            };
            connection
                .execute(
                    &format!("INSERT INTO {table}(key,value,weight) VALUES(?1,?2,?3)"),
                    (&key, &value, weight),
                )
                .unwrap();
        }
    }
    PinyinDatabase {
        connection: Some(connection),
        data_version: None,
    }
}

fn segments(syllables: usize) -> Vec<String> {
    let mut result = vec!["ping".to_owned(), "guo".to_owned()];
    result.extend((2..syllables).map(|_| "a".to_owned()));
    result
}

#[test]
fn overflow_extra_pages_do_not_repeat_query_allocations() {
    for per_length in [0, 4, 32] {
        let database = fixture(per_length);
        for syllables in [7, 8, 9] {
            let key = segments(syllables);
            for limit in [1, 12, 100, usize::MAX] {
                drop(database.query_longer_phrases(&key, 1, limit));
                drop(database.query_longer_phrases(&key, 3, limit));
                let (single, once) = count(|| database.query_longer_phrases(&key, 1, limit));
                let (repeated, actual) = count(|| database.query_longer_phrases(&key, 3, limit));
                assert_eq!(repeated, single);
                assert_eq!(repeated.capacity(), single.capacity());
                assert_eq!(
                    actual, once,
                    "{per_length}/{syllables}/{limit}：溢出桶仍重复查询"
                );
            }
        }
    }
}

#[test]
fn collapsed_overflow_keeps_legacy_fields_order_and_limits() {
    let database = fixture(4);
    for syllables in 2..=9 {
        let key = segments(syllables);
        for extra in [0, 1, 2, 3, 8] {
            for limit in [0, 1, 2, 8, 32, 100, usize::MAX] {
                let expected = database.legacy_query_longer_phrases(&key, extra, limit);
                let actual = database.query_longer_phrases(&key, extra, limit);
                assert_eq!(actual, expected, "{syllables}/{extra}/{limit}");
                assert!(actual.capacity() <= expected.capacity());
            }
        }
    }
    let key = segments(6);
    let rows = database.query_longer_phrases(&key, 3, 100);
    let first = rows.iter().find(|row| row.value == "合成跨表同值").unwrap();
    assert_eq!(first.key, "ping'guo'a'a'a'a'a");
    assert_eq!(
        first.weight, 100,
        "仍保留较早的七音节表行，而非溢出表的高权行"
    );
    let key = segments(7);
    assert!(database
        .query_longer_phrases(&key, 1, 100)
        .iter()
        .any(|row| row.key.split('\'').count() == 10));
}

#[test]
fn collapsed_overflow_reduces_warm_heap_and_retained_rows() {
    let database = fixture(32);
    let key = segments(7);
    for limit in [12, 100, usize::MAX] {
        drop(database.legacy_query_longer_phrases(&key, 3, limit));
        drop(database.query_longer_phrases(&key, 3, limit));
        let (expected, before) = measure(|| database.legacy_query_longer_phrases(&key, 3, limit));
        let (actual, after) = measure(|| database.query_longer_phrases(&key, 3, limit));
        assert_eq!(actual, expected);
        assert_eq!(before.minimum_bytes, 0);
        assert_eq!(after.minimum_bytes, 0);
        println!(
            "溢出页 limit={limit}，{} 行：申请 {}→{}，峰值 {}→{}，返回 {}→{}，容量 {}→{}",
            actual.len(),
            before.allocations,
            after.allocations,
            before.peak_bytes,
            after.peak_bytes,
            before.remaining_bytes,
            after.remaining_bytes,
            expected.capacity(),
            actual.capacity()
        );
        assert!(after.allocations < before.allocations);
        assert!(after.peak_bytes < before.peak_bytes);
        assert!(after.remaining_bytes < before.remaining_bytes);
    }
}

#[test]
fn numbered_pages_keep_the_original_allocation_budget() {
    for per_length in [0, 4, 32] {
        let database = fixture(per_length);
        let key = segments(2);
        for limit in [1, 12, 100, usize::MAX] {
            drop(database.legacy_query_longer_phrases(&key, 3, limit));
            drop(database.query_longer_phrases(&key, 3, limit));
            let (expected, before) = count(|| database.legacy_query_longer_phrases(&key, 3, limit));
            let (actual, after) = count(|| database.query_longer_phrases(&key, 3, limit));
            assert_eq!(actual, expected);
            assert_eq!(actual.capacity(), expected.capacity());
            assert_eq!(after, before);
        }
    }
}

#[test]
fn huge_extra_count_only_queries_distinct_tables() {
    let database = fixture(4);
    let key = segments(6);
    let expected = database.legacy_query_longer_phrases(&key, 2, 1);
    assert_eq!(database.query_longer_phrases(&key, usize::MAX, 1), expected);
}
