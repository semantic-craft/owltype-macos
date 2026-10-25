use super::*;
use crate::ime::personal_rerank::allocations::count;

// 固定 26e708877e301c7d8599c0d7b216505a593661c3 的完整拥有型 beam，只改名并移除注释；展开规则本片不变。
pub(crate) fn legacy_owned_segmentations<S: AsRef<str>>(
    segments: &[S],
    options: FuzzyPinyinOptions,
    limit: usize,
) -> Vec<Vec<String>> {
    if options.rules == 0 || segments.is_empty() || limit <= 1 {
        return Vec::new();
    }
    let mut paths: Vec<Vec<String>> = Vec::new();
    for (index, syllable) in segments.iter().enumerate() {
        let variants = fuzzy_syllables(syllable.as_ref(), options);
        let alternatives = variants.as_slice();
        if paths.is_empty() {
            if alternatives.len() == 1 {
                continue;
            }
            let mut prefix = Vec::new();
            for segment in &segments[..index] {
                prefix.push(segment.as_ref().to_owned());
            }
            paths = vec![prefix];
        }
        if let [alternative] = alternatives {
            for path in &mut paths {
                path.push((*alternative).to_owned());
            }
            continue;
        }
        let capacity = limit.min(paths.len().saturating_mul(alternatives.len()));
        let mut next = Vec::with_capacity(capacity);
        'beam: for mut path in paths {
            let take = (limit - next.len()).min(alternatives.len());
            for alternative in alternatives.iter().take(take.saturating_sub(1)) {
                let mut extended = Vec::with_capacity(path.len() + 1);
                extended.extend_from_slice(&path);
                extended.push((*alternative).to_owned());
                next.push(extended);
            }
            if take == 0 {
                break 'beam;
            }
            path.push(alternatives[take - 1].to_owned());
            next.push(path);
            if next.len() == limit {
                break 'beam;
            }
        }
        paths = next;
    }
    paths.retain(|path| {
        !path
            .iter()
            .map(String::as_str)
            .eq(segments.iter().map(AsRef::as_ref))
    });
    paths
}

// 按冻结变体数及非空前缀长度推导旧复制数，减去最终返回字段数；在主计量区外调用。
pub(crate) fn deferred_string_savings<S: AsRef<str>>(
    segments: &[S],
    options: FuzzyPinyinOptions,
    limit: usize,
) -> usize {
    if options.rules == 0 || segments.is_empty() || limit <= 1 {
        return 0;
    }
    let mut started = false;
    let mut parents = 1usize;
    let mut prefix_nonempty = 0usize;
    let mut copies = 0usize;
    for syllable in segments {
        let nonempty = usize::from(!syllable.as_ref().is_empty());
        let variants =
            super::variant_view_tests::legacy_syllables(syllable.as_ref(), options).len();
        if !started {
            if variants == 1 {
                prefix_nonempty += nonempty;
                continue;
            }
            started = true;
            copies += prefix_nonempty;
        }
        let capacity = limit.min(parents.saturating_mul(variants));
        if variants != 1 {
            let processed_parents = (capacity - 1) / variants + 1;
            copies += (capacity - processed_parents) * prefix_nonempty;
        }
        copies += capacity * nonempty;
        parents = capacity;
        prefix_nonempty += nonempty;
    }
    if started {
        copies - (parents - 1) * prefix_nonempty
    } else {
        0
    }
}

fn assert_deferred_matches<S: AsRef<str>>(
    segments: &[S],
    options: FuzzyPinyinOptions,
    limit: usize,
) {
    let saved = deferred_string_savings(segments, options, limit);
    let (expected, old_count) = count(|| legacy_owned_segmentations(segments, options, limit));
    let (actual, new_count) = count(|| fuzzy_segmentations(segments, options, limit));
    assert_eq!(actual, expected);
    assert_eq!(
        new_count + saved,
        old_count,
        "临时字符串仍被复制: rules={}, limit={limit}, saved={saved}",
        options.rules
    );
    assert_eq!(actual.capacity(), expected.capacity());
    for (actual, expected) in actual.iter().zip(&expected) {
        assert_eq!(actual.capacity(), expected.capacity());
        for (actual, expected) in actual.iter().zip(expected) {
            assert_eq!(actual.capacity(), expected.capacity());
        }
    }
}

#[test]
fn deferred_strings_own_only_returned_syllable_variants() {
    let _ = super::super::syllables::intact_pinyin_set();
    for syllable in super::super::syllables::intact_pinyin_list()
        .iter()
        .copied()
        .chain([
            "",
            "zh",
            "ZAN",
            "合成",
            "😀",
            "zan'hao",
            "nue",
            "长合成输入输入输入",
        ])
    {
        for rules in std::iter::once(0)
            .chain((0..11).map(|bit| 1 << bit))
            .chain(std::iter::once(fuzzy_rule::ALL))
        {
            for limit in [0, 1, 2, 64] {
                assert_deferred_matches(&[syllable], FuzzyPinyinOptions { rules }, limit);
            }
        }
    }
}

#[test]
fn deferred_strings_preserve_beam_prefixes_truncation_and_owned_output() {
    let _ = super::super::syllables::intact_pinyin_set();
    for count in [0, 1, 3, 4, 5, 8, 17, 40] {
        for prefix in ["guo", "", "合成"] {
            for suffix in [
                vec![],
                vec!["zan"],
                vec!["lan", "chuang"],
                vec!["zan", "guo", "fa"],
            ] {
                let mut input = vec![prefix; count];
                input.extend(suffix);
                let mut owned: Vec<String> =
                    input.iter().map(|value| (*value).to_owned()).collect();
                for rules in [0, fuzzy_rule::Z_ZH, fuzzy_rule::ALL] {
                    for limit in [0, 1, 2, 3, 5, 63, 64, 65, 128, usize::MAX] {
                        let options = FuzzyPinyinOptions { rules };
                        assert_deferred_matches(&input, options, limit);
                        assert_deferred_matches(&owned, options, limit);
                    }
                }
                let options = FuzzyPinyinOptions {
                    rules: fuzzy_rule::ALL,
                };
                let actual = fuzzy_segmentations(&owned, options, 64);
                let expected = legacy_owned_segmentations(&owned, options, 64);
                owned.clear();
                assert_eq!(actual, expected);
            }
        }
    }
    for input in [vec!["zan"; 8], vec!["lan"; 5], vec!["zan", "", "fa", "guo"]] {
        for limit in [0, 1, 2, 3, 5, 63, 64, 65, 128, usize::MAX] {
            assert_deferred_matches(
                &input,
                FuzzyPinyinOptions {
                    rules: fuzzy_rule::ALL,
                },
                limit,
            );
        }
    }
}
