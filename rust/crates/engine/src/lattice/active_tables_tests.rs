use crate::assets::{BIGRAM_TABLE, TRIGRAM_TABLE};
use crate::ime::personal_rerank::allocations::count;
use crate::paths::RuntimePaths;
use crate::quanpin::fixture::Fixture;
use crate::types::WordItem;

use super::ngram::{fnv1a_words, tests::write_table, NgramTable};

pub(crate) fn fixture(bigram: bool, trigram: bool) -> Fixture {
    let fixture = Fixture::new();
    for (key, word) in [("ni", "甲"), ("hao", "乙"), ("ma", "丙")] {
        fixture.insert(key, word, 100);
    }
    for (enabled, name, key) in [
        (bigram, BIGRAM_TABLE, fnv1a_words(&["甲", "乙"])),
        (trigram, TRIGRAM_TABLE, fnv1a_words(&["甲", "乙", "丙"])),
    ] {
        if enabled {
            write_table(&fixture.paths.dictionary(name), &[(key, 3.0)], b"MSNG", 1);
        }
    }
    fixture
}

pub(crate) fn evict_shared(paths: &RuntimePaths) {
    // 不访问被测词典的键；超过八槽后，它的二元/三元条目必定被淘汰。
    for index in 0..16 {
        assert!(NgramTable::shared(&paths.dictionaries.join(format!("missing-{index}"))).is_none());
    }
}

#[test]
fn active_ngram_options_clone_without_allocating_and_release_with_the_owner() {
    use super::decode::{make_sentence_lattice_options, SentenceNgramTables};
    use std::sync::Arc;

    for bigram in [false, true] {
        for trigram in [false, true] {
            let fixture = fixture(bigram, trigram);
            let tables = SentenceNgramTables::load(&fixture.paths);
            let captured = tables.options(true);
            let (old, old_count) = count(|| make_sentence_lattice_options(&fixture.paths, true));
            assert!(old_count >= 2);
            println!("二元={bigram}/三元={trigram}：配置申请 {old_count}→0");
            for alternatives in [false, true] {
                let (options, allocations) = count(|| tables.options(alternatives));
                assert_eq!(allocations, 0);
                assert_eq!(
                    (options.nbest, options.emit),
                    (6, usize::from(!alternatives))
                );
                assert_eq!(options.beam, old.beam);
                assert_eq!(options.bigram_weight, old.bigram_weight);
                assert_eq!(options.trigram_weight, old.trigram_weight);
                assert_eq!(options.phrase_length_bonus, old.phrase_length_bonus);
                assert_eq!(options.typo_lead_margin, old.typo_lead_margin);
                assert_eq!(options.include_lattice_best, old.include_lattice_best);
                assert_eq!(options.show_next_on_duplicate, old.show_next_on_duplicate);
                for (held, expected) in [
                    (&options.bigram, &old.bigram),
                    (&options.trigram, &old.trigram),
                ] {
                    assert_eq!(held.is_some(), expected.is_some());
                    if let (Some(held), Some(expected)) = (held, expected) {
                        assert_eq!(held.bigram("甲", "乙"), expected.bigram("甲", "乙"));
                        assert_eq!(
                            held.trigram("甲", "乙", "丙"),
                            expected.trigram("甲", "乙", "丙")
                        );
                    }
                }
                for (cloned, held) in [
                    (&options.bigram, &captured.bigram),
                    (&options.trigram, &captured.trigram),
                ] {
                    if let (Some(cloned), Some(held)) = (cloned, held) {
                        assert!(Arc::ptr_eq(cloned, held));
                    }
                }
            }
            let weak_bigram = captured.bigram.as_ref().map(Arc::downgrade);
            let weak_trigram = captured.trigram.as_ref().map(Arc::downgrade);
            drop(old);
            drop(captured);
            evict_shared(&fixture.paths);
            for weak in [&weak_bigram, &weak_trigram].into_iter().flatten() {
                assert!(weak.upgrade().is_some());
            }
            drop(tables);
            for weak in [&weak_bigram, &weak_trigram].into_iter().flatten() {
                assert!(weak.upgrade().is_none(), "共享淘汰后的闲置表没有释放");
            }
        }
    }
}

#[test]
fn new_generation_captures_its_own_tables_and_missing_tables_stay_missing() {
    use super::decode::SentenceNgramTables;

    let missing = fixture(false, false);
    let old = SentenceNgramTables::load(&missing.paths);
    // 捕获缺失之后才出现的文件不属于活动词典原来的资源快照。
    write_table(
        &missing.paths.dictionary(BIGRAM_TABLE),
        &[(fnv1a_words(&["甲", "乙"]), 9.0)],
        b"MSNG",
        1,
    );
    evict_shared(&missing.paths);
    assert!(old.options(false).bigram.is_none());
    let next = fixture(true, true);
    let new = SentenceNgramTables::load(&next.paths).options(false);
    assert_eq!(new.bigram.unwrap().bigram("甲", "乙"), 3.0);
    assert_eq!(new.trigram.unwrap().trigram("甲", "乙", "丙"), 3.0);
}

pub(crate) fn assert_query_stable(paths: &RuntimePaths, mut query: impl FnMut() -> Vec<WordItem>) {
    drop(query());
    let (expected, warm_count) = count(&mut query);
    assert_eq!(expected.len(), 1);
    assert_eq!(expected[0].word, "甲乙丙");
    evict_shared(paths);
    let (actual, evicted_count) = count(&mut query);
    println!("整句热查询/共享淘汰后申请：{warm_count}/{evicted_count}");
    assert_eq!(actual, expected);
    assert_eq!(actual.capacity(), expected.capacity());
    assert_eq!(
        evicted_count, warm_count,
        "共享淘汰后整句查询重新申请表资源"
    );

    // unlink 不改变已映射 inode 的内容；活动词典继续使用构造时捕获的表。
    for name in [BIGRAM_TABLE, TRIGRAM_TABLE] {
        let path = paths.dictionary(name);
        if path.is_file() {
            std::fs::remove_file(path).unwrap();
        }
    }
    evict_shared(paths);
    let (retained, retained_count) = count(&mut query);
    assert_eq!(retained, expected, "活动词典丢失了已预热表的分数");
    assert_eq!(retained.capacity(), expected.capacity());
    assert_eq!(retained_count, warm_count);
}
