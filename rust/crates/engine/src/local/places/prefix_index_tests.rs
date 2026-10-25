use super::*;
use crate::ime::personal_rerank::allocations;
use std::collections::BTreeSet;
use std::hint::black_box;
use std::time::{Duration, Instant};

#[test]
fn indexed_entries_match_source_order_for_full_and_initial_spellings() {
    let table = places();
    let mut queries = BTreeSet::from(["", "zzzz", "BEI", "bei'", "北京", "é"]);
    for spelling in table.spellings.iter().flatten() {
        queries.insert(spelling.as_str());
        for (position, letter) in spelling.char_indices().take(2) {
            queries.insert(&spelling[..position + letter.len_utf8()]);
        }
    }
    for code in queries {
        let expected: Vec<_> = table
            .places
            .iter()
            .zip(&table.spellings)
            .filter(|(_, spellings)| {
                spellings
                    .iter()
                    .any(|spelling| !spelling.is_empty() && spelling.starts_with(code))
            })
            .collect();
        let actual: Vec<_> = table.matching_entries(code).collect();
        assert_eq!(actual, expected, "code={code:?}");
    }
}

#[test]
fn sparse_and_missed_index_queries_use_no_temporary_heap() {
    let table = places();
    for code in ["bei", "bj", "shenzhen", "luanshi", "zzzz", "BEI", "北京"] {
        let (count, allocations) = allocations::count(|| table.matching_entries(code).count());
        let expected = table
            .spellings
            .iter()
            .filter(|spellings| {
                spellings
                    .iter()
                    .any(|spelling| !spelling.is_empty() && spelling.starts_with(code))
            })
            .count();
        assert_eq!(count, expected);
        assert!(count < table.places.len() / 10);
        assert_eq!(allocations, 0);
    }
}

#[test]
fn a_row_matching_both_spellings_occurs_once_and_empty_rows_are_skipped() {
    let table = Places::parse("重复\tb'j\t\n重复\tbei'jing\t\n空键\t\t\nmalformed\n");
    let matches: Vec<_> = table
        .matching_entries("b")
        .map(|(place, _)| place.key)
        .collect();
    assert_eq!(matches, ["b'j", "bei'jing"]);
    assert_eq!(table.matching_entries("").count(), 2);
    assert_eq!(table.matching_entries("bj").count(), 2);
    assert_eq!(table.matching_entries("beijing").count(), 1);
    let empty = Places::parse("");
    assert_eq!(empty.matching_entries("").count(), 0);
}

#[test]
fn index_initialization_adds_only_one_number_buffer() {
    places();
    let (expected, old) = allocations::measure(|| frozen_parse(TABLE));
    let (actual, new) = allocations::measure(|| Places::parse(TABLE));
    assert_eq!(actual.places, expected.places);
    assert_eq!(actual.spellings, expected.spellings);
    assert_eq!(actual.parents, expected.parents);
    assert_eq!(TABLE_LINE_COUNT, TABLE.lines().count());
    assert_eq!(actual.spelling_index.len(), actual.places.len() * 2);
    assert_eq!(
        actual.spelling_index.capacity(),
        actual.spelling_index.len()
    );
    let bytes = actual.spelling_index.len() * std::mem::size_of::<usize>();
    assert_eq!(new.allocations, old.allocations + 1);
    assert_eq!(new.remaining_bytes, old.remaining_bytes + bytes as i128);
    assert_eq!(new.minimum_bytes, 0);
    assert_eq!(old.minimum_bytes, 0);
}

#[test]
#[ignore = "局部冷初始化计时手动在 release 模式运行"]
fn index_initialization_cost() {
    places();
    let mut old_samples = [Duration::ZERO; 7];
    let mut new_samples = [Duration::ZERO; 7];
    for index in 0..old_samples.len() {
        let old = || {
            let start = Instant::now();
            let table = frozen_parse(black_box(TABLE));
            black_box(&table);
            start.elapsed()
        };
        let new = || {
            let start = Instant::now();
            let table = Places::parse(black_box(TABLE));
            black_box(&table);
            start.elapsed()
        };
        if index % 2 == 0 {
            old_samples[index] = old();
            new_samples[index] = new();
        } else {
            new_samples[index] = new();
            old_samples[index] = old();
        }
    }
    old_samples.sort_unstable();
    new_samples.sort_unstable();
    eprintln!(
        "地点表局部冷初始化：原实现={:?}，含前缀索引={:?}，七次中位数",
        old_samples[3], new_samples[3]
    );
}

struct FrozenPlaces {
    places: Vec<Place>,
    spellings: Vec<[String; 2]>,
    parents: HashMap<&'static str, &'static str>,
}

// 冻结已有表解析，不包含本轮新增的拼写编号索引，用于核对新增常驻存储和初始化代价。
fn frozen_parse(table: &'static str) -> FrozenPlaces {
    let mut places = Vec::with_capacity(table.lines().count());
    for line in table.lines() {
        let mut fields = line.split('\t');
        if let (Some(name), Some(key), Some(parent), None) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        {
            places.push(Place { name, key, parent });
        }
    }
    let spellings = places
        .iter()
        .map(|place| {
            [
                place.key.replace('\'', ""),
                place
                    .key
                    .split('\'')
                    .filter_map(|syllable| syllable.chars().next())
                    .collect(),
            ]
        })
        .collect();
    let parents = places
        .iter()
        .map(|place| (place.name, place.parent))
        .collect();
    FrozenPlaces {
        places,
        spellings,
        parents,
    }
}
