use super::*;
use crate::ime::personal_rerank::allocations;

// 冻结逐编辑创建向量的旧实现，独立对照编辑顺序和恢复原输入。
fn frozen_compute_typos(syllable: &str) -> Vec<SyllableTypo> {
    let typed = normalized_syllable(syllable);
    if typed.len() < 2 {
        return Vec::new();
    }
    let letters = syllable.as_bytes();
    let neighbor_capacity = letters
        .iter()
        .map(|&letter| {
            (b'a'..=b'z')
                .filter(|&key| keys_adjacent(key, letter))
                .count()
        })
        .sum::<usize>();
    let capacity = letters.len().saturating_sub(1)
        + neighbor_capacity
        + letters.len()
        + letters.len().saturating_add(1).saturating_mul(26);
    let mut variants = Vec::with_capacity(capacity);
    for i in 0..letters.len() - 1 {
        if letters[i] == letters[i + 1] {
            continue;
        }
        let mut swapped = letters.to_vec();
        swapped.swap(i, i + 1);
        add_variant(
            &mut variants,
            &typed,
            &swapped,
            SyllableTypoKind::Transposition,
        );
    }
    for i in 0..letters.len() {
        for key in b'a'..=b'z' {
            if key == letters[i] || !keys_adjacent(key, letters[i]) {
                continue;
            }
            let mut substituted = letters.to_vec();
            substituted[i] = key;
            add_variant(
                &mut variants,
                &typed,
                &substituted,
                SyllableTypoKind::Neighbor,
            );
        }
    }
    for i in 0..letters.len() {
        let mut shortened = letters.to_vec();
        shortened.remove(i);
        add_variant(
            &mut variants,
            &typed,
            &shortened,
            SyllableTypoKind::MissingOrExtra,
        );
    }
    for i in 0..=letters.len() {
        for key in b'a'..=b'z' {
            let mut lengthened = letters.to_vec();
            lengthened.insert(i, key);
            add_variant(
                &mut variants,
                &typed,
                &lengthened,
                SyllableTypoKind::MissingOrExtra,
            );
        }
    }
    variants.sort_by_key(|variant| variant.kind);
    variants
}

#[test]
fn typo_generation_reuses_edit_storage_and_preserves_the_frozen_table() {
    // 合法音节集合初始化在计量外；每次计量仅借用输入并返回独立拥有的结果。
    assert!(is_intact("ni"));
    let mut old_total = 0;
    let mut new_total = 0;
    let mut old_table = 0;
    let mut new_table = 0;
    for (index, &syllable) in intact_pinyin_list()
        .iter()
        .chain(
            [
                "",
                "a",
                "v",
                "NI",
                "ni'hao",
                "合成",
                "😀",
                "a\0b",
                "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
            ]
            .iter(),
        )
        .enumerate()
    {
        let (expected, old_allocations) = allocations::count(|| frozen_compute_typos(syllable));
        let (actual, new_allocations) = allocations::count(|| compute_typos(syllable));
        assert_eq!(actual, expected, "{syllable:?}");
        if index < intact_pinyin_list().len() {
            old_table += old_allocations;
            new_table += new_allocations;
        }
        old_total += old_allocations;
        new_total += new_allocations;
        if normalized_syllable(syllable).len() < 2 {
            assert_eq!(new_allocations, old_allocations);
        } else {
            assert!(
                new_allocations < old_allocations,
                "{syllable:?}: {old_allocations} → {new_allocations}"
            );
        }
    }
    eprintln!("421 个合法音节生成分配：{old_table} → {new_table}");
    eprintln!("合成输入与完整音节表生成分配：{old_total} → {new_total}");
    assert!(
        new_total < old_total,
        "编辑缓冲没有减少分配：{old_total} → {new_total}"
    );
}
