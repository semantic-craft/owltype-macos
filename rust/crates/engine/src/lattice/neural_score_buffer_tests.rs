use super::*;
use crate::ime::personal_rerank::allocations::count;

#[test]
fn bounded_rerank_order_writes_into_a_stack_buffer_without_allocating() {
    let neural = [-3.0, -2.0, -4.0];
    let statik = [-1.0, -1.2, -1.4];
    let mut order = [usize::MAX; MAX_RERANK_PATHS];
    let (counted, allocations) = count(|| rerank_order_into(&neural, &statik, &mut order));
    assert_eq!(counted, Some(3));
    assert_eq!(&order[..3], &[1, 0, 2]);
    assert_eq!(allocations, 0);
}

#[test]
fn capped_score_storage_saves_one_allocation_without_changing_full_order() {
    let values = [
        0.0,
        -0.0,
        -3.0,
        7.0,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::from_bits(0x7ff8_0000_0000_0001),
        f64::from_bits(0xfff8_0000_0000_0002),
    ];
    for n in [0, 1, 2, 3, 6, 11, 12, 13, 15, 64, 128, 129, 4096] {
        for shift in 0..values.len() {
            let statik: Vec<_> = (0..n).map(|i| values[(i + shift) % values.len()]).collect();
            for len in [0, 1, n.min(MAX_RERANK_PATHS), n, n + 1] {
                let neural: Vec<_> = (0..len)
                    .map(|i| values[(i * 3 + shift) % values.len()])
                    .collect();
                let (expected, old_count) = count(|| legacy_order(&neural, &statik));
                let (actual, new_count) = count(|| rerank_order(&neural, &statik));
                assert_eq!(actual, expected, "路径={n}/神经分={len}/偏移={shift}");
                if let (Some(actual), Some(expected)) = (&actual, &expected) {
                    assert_eq!(actual.capacity(), expected.capacity());
                    assert_eq!(
                        &actual[n.min(MAX_RERANK_PATHS)..],
                        &expected[n.min(MAX_RERANK_PATHS)..]
                    );
                    assert_eq!(new_count, 1, "有界混合分仍创建临时堆向量");
                    assert_eq!(new_count + 1, old_count);
                } else {
                    assert_eq!((new_count, old_count), (0, 0));
                }
            }
        }
    }
}

fn paths(n: usize) -> Vec<SentencePath> {
    let texts = [
        "输入发",
        "输入法",
        "甲乙丙",
        "合成文本😀",
        "",
        "abc",
        "你好",
        "拟号",
    ];
    (0..n)
        .map(|index| SentencePath {
            sentence: texts[index % texts.len()].to_owned(),
            key: format!("ni'hao/{index}"),
            log_prob: -(index as f64) / 10.0,
            words: vec!["合成".to_owned(), format!("字段{index}")],
            typo_edges: index % 3,
        })
        .collect()
}

fn assert_paths(actual: &[SentencePath], expected: &[SentencePath]) {
    assert_eq!(actual.len(), expected.len());
    for (actual, expected) in actual.iter().zip(expected) {
        assert_eq!(actual.sentence, expected.sentence);
        assert_eq!(actual.key, expected.key);
        assert_eq!(actual.log_prob.to_bits(), expected.log_prob.to_bits());
        assert_eq!(actual.words, expected.words);
        assert_eq!(actual.typo_edges, expected.typo_edges);
        assert_eq!(actual.sentence.capacity(), expected.sentence.capacity());
        assert_eq!(actual.key.capacity(), expected.key.capacity());
        assert_eq!(actual.words.capacity(), expected.words.capacity());
    }
}

#[derive(Debug, PartialEq)]
struct PathStorage {
    sentence: (*const u8, usize),
    key: (*const u8, usize),
    words: (*const String, usize),
    word_strings: Vec<(*const u8, usize)>,
}

fn storage(path: &SentencePath) -> PathStorage {
    PathStorage {
        sentence: (path.sentence.as_ptr(), path.sentence.capacity()),
        key: (path.key.as_ptr(), path.key.capacity()),
        words: (path.words.as_ptr(), path.words.capacity()),
        word_strings: path
            .words
            .iter()
            .map(|word| (word.as_ptr(), word.capacity()))
            .collect(),
    }
}

#[test]
fn real_model_reranking_removes_five_temporary_buffers_and_keeps_the_tail_owned() {
    let path = match test_model_path(crate::assets::NEURAL_MODEL_KEYBOARD) {
        Ok(path) => path,
        Err(reason) => {
            eprintln!("跳过真实模型评分缓冲对照：{reason}");
            return;
        }
    };
    let model = shared_sentence_model(&path).expect("锁定键盘模型能加载");
    let long_context = "合成😀上下文".repeat(20);
    for context in ["", "合成😀", long_context.as_str()] {
        for n in [0, 1, 2, 3, 6, 11, 12, 13, 15, 64, 128, 129, 257] {
            for warm in [false, true] {
                let mut before =
                    NeuralReranker::new(CandidateSource::NeuralKeyboard, model.clone());
                let mut after = NeuralReranker::new(CandidateSource::NeuralKeyboard, model.clone());
                let input = paths(n);
                let mut expected = input.clone();
                let mut actual = input.clone();
                if warm {
                    let mut old_warm = input.clone();
                    let mut new_warm = input.clone();
                    assert_eq!(
                        before.legacy_rerank(&mut old_warm, context),
                        after.rerank(&mut new_warm, context)
                    );
                    assert_paths(&new_warm, &old_warm);
                }
                let pointer = actual.as_ptr();
                let capacity = actual.capacity();
                let original_storage: Vec<_> = actual.iter().map(storage).collect();
                let (old_ran, old_count) = count(|| before.legacy_rerank(&mut expected, context));
                let (new_ran, new_count) = count(|| after.rerank(&mut actual, context));
                assert_eq!(new_ran, old_ran);
                assert_paths(&actual, &expected);
                assert_eq!(actual.as_ptr(), pointer);
                assert_eq!(actual.capacity(), capacity);
                for (position, path) in actual.iter().enumerate() {
                    let original_index = input
                        .iter()
                        .position(|original| original.key == path.key)
                        .unwrap();
                    assert_eq!(storage(path), original_storage[original_index]);
                    if position >= MAX_RERANK_PATHS {
                        assert_eq!(original_index, position, "未评分尾部发生移动");
                    }
                }
                let moved = expected.iter().zip(&input).any(|(a, b)| a.key != b.key);
                let saved = if n < 2 {
                    0
                } else {
                    5 + usize::from(n > 128 && moved)
                };
                assert_eq!(
                    new_count + saved,
                    old_count,
                    "路径={n}/模型热={warm}/上下文字数={}",
                    context.chars().count()
                );
            }
        }
    }
}

// 固定 7384a93f0eceea679aa61219cfa6d0e827117a25 的完整排序与模型入口，仅改名、转接冻结排序及移除注释。
fn legacy_order(neural: &[f64], static_nats: &[f64]) -> Option<Vec<usize>> {
    let n = static_nats.len();
    let scored = n.min(MAX_RERANK_PATHS);
    if n < 2 || (neural.len() != n && neural.len() != scored) {
        return None;
    }
    let combined: Vec<f64> = (0..scored)
        .map(|index| {
            let statik = static_nats[index];
            statik + RERANK_LAMBDA * (neural[index] - statik)
        })
        .collect();
    let mut order: Vec<usize> = (0..n).collect();
    order[..scored].sort_by(|&a, &b| combined[b].total_cmp(&combined[a]));
    Some(order)
}
impl NeuralReranker {
    fn legacy_rerank(&mut self, paths: &mut [SentencePath], context: &str) -> bool {
        if paths.len() < 2 {
            return false;
        }
        let scored = paths.len().min(MAX_RERANK_PATHS);
        let texts: Vec<&str> = paths[..scored]
            .iter()
            .map(|path| path.sentence.as_str())
            .collect();
        let means = self
            .reranker
            .log_probabilities(last_characters(context, CONTEXT_CHARACTERS), &texts);
        if means.len() != scored {
            return false;
        }
        let neural: Vec<f64> = means
            .iter()
            .zip(&texts)
            .map(|(mean, text)| f64::from(*mean) * text.chars().count() as f64)
            .collect();
        let statik: Vec<f64> = paths.iter().map(|path| path.log_prob).collect();
        let Some(order) = legacy_order(&neural, &statik) else {
            return false;
        };
        apply_order(paths, &order);
        true
    }
}
