use super::block_buffer_tests::favouring_model;
use super::*;
use crate::ime::personal_rerank::allocations::count;
use crate::lattice::decode::tests::{lookup, row, syllables, table};
use std::sync::Arc;

#[test]
fn neural_merge_eliminates_path_copies_without_changing_candidates_or_typo() {
    let keys = syllables("a'ba'ca");
    assert!(has_only_complete_pinyin_segments(&keys));
    let mut cases = 0;
    for n in [0, 1, 2, 6, 12, 13, 65, 129] {
        let characters: Vec<_> = (0..n)
            .map(|index| char::from_u32(0x4e00 + index as u32).unwrap())
            .collect();
        let mut rows = table(&[("ba", &[("吧", 1000)]), ("ca", &[("嚓", 1000)])]);
        rows.insert(
            "a".into(),
            characters
                .iter()
                .enumerate()
                .map(|(index, value)| row("a", &value.to_string(), 100_000 - index as i64))
                .collect(),
        );
        let vocabulary: Vec<_> = characters
            .iter()
            .copied()
            .chain(['吧', '嚓', '叭', '合', '成', '😀'])
            .collect();
        let first = Arc::new(favouring_model(
            &vocabulary,
            characters.last().map(std::slice::from_ref).unwrap_or(&[]),
        ));
        let last = Arc::new(favouring_model(
            &vocabulary,
            characters
                .get(n / 2)
                .map(std::slice::from_ref)
                .unwrap_or(&[]),
        ));
        for filler_count in [0, 64] {
            for duplicates in [0, 12, n] {
                for include_lattice_best in [false, true] {
                    for show_next_on_duplicate in [false, true] {
                        let options = LatticeOptions {
                            nbest: n,
                            beam: n.max(32),
                            span_limit: n.max(32),
                            include_lattice_best,
                            show_next_on_duplicate,
                            ..LatticeOptions::default()
                        };
                        let graph = build_graph(&keys, &mut lookup(&rows), &options);
                        let decoded = decode_graph(&graph, &options, None);
                        assert_eq!(decoded.len(), n);
                        let (_, clone_count) = count(|| decoded.clone());
                        let mut input: Vec<_> = decoded
                            .iter()
                            .take(duplicates)
                            .map(|path| {
                                WordItem::new(
                                    "abaca",
                                    &path.sentence,
                                    123,
                                    CandidateSource::Database,
                                    "a'ba'ca",
                                )
                            })
                            .collect();
                        input.extend((0..filler_count).map(|index| {
                            WordItem::new(
                                "abaca",
                                format!("占位{index}"),
                                456,
                                CandidateSource::CloudSuggestion,
                                "",
                            )
                        }));
                        for mode in 0..5 {
                            for warm in [false, true] {
                                // 大尾部只保留实际需要验证的前缀全重复、双模型及混合来源用例。
                                if n > 13
                                    && (filler_count != 0
                                        || duplicates != 12
                                        || !include_lattice_best
                                        || !show_next_on_duplicate
                                        || mode < 2
                                        || !warm)
                                {
                                    continue;
                                }
                                let make_rerankers = || match mode {
                                    0 => vec![],
                                    1 => vec![NeuralReranker::new(
                                        CandidateSource::Generated,
                                        first.clone(),
                                    )],
                                    2 => vec![NeuralReranker::new(
                                        CandidateSource::NeuralKeyboard,
                                        first.clone(),
                                    )],
                                    3 => vec![
                                        NeuralReranker::new(
                                            CandidateSource::NeuralKeyboard,
                                            first.clone(),
                                        ),
                                        NeuralReranker::new(
                                            CandidateSource::NeuralKeyboard,
                                            last.clone(),
                                        ),
                                    ],
                                    _ => vec![
                                        NeuralReranker::new(
                                            CandidateSource::NeuralKeyboard,
                                            first.clone(),
                                        ),
                                        NeuralReranker::new(
                                            CandidateSource::Generated,
                                            first.clone(),
                                        ),
                                        NeuralReranker::new(
                                            CandidateSource::NeuralKeyboard,
                                            last.clone(),
                                        ),
                                    ],
                                };
                                let mut before = make_rerankers();
                                let mut after = make_rerankers();
                                let keyboard_count = before
                                    .iter()
                                    .filter(|model| model.source == CandidateSource::NeuralKeyboard)
                                    .count();
                                let context = if warm { "合成😀上下文" } else { "" };
                                let run = |legacy: bool, rerankers: &mut [NeuralReranker]| {
                                    let mut candidates = input.clone();
                                    let mut literal = None;
                                    let mut typo_source = |path: &SentencePath| {
                                        literal = Some(path.clone());
                                        vec![super::super::decode::TypoEdge {
                                            start: 1,
                                            end: 3,
                                            key: "ba'ca".into(),
                                            value: "叭嚓".into(),
                                            weight: 900_000,
                                            penalty: 0.5,
                                        }]
                                    };
                                    let merge = if legacy {
                                        legacy_merge_lattice_candidates
                                    } else {
                                        merge_lattice_candidates
                                    };
                                    let typo = merge(
                                        &mut candidates,
                                        &keys,
                                        &mut lookup(&rows),
                                        "abaca",
                                        &options,
                                        Some(&mut typo_source),
                                        rerankers,
                                        context,
                                    );
                                    (candidates, typo, literal)
                                };
                                if warm {
                                    assert_eq!(run(true, &mut before), run(false, &mut after));
                                }
                                cases += 1;
                                let (old, old_count) = count(|| run(true, &mut before));
                                let (new, new_count) = count(|| run(false, &mut after));
                                assert_eq!(new, old, "路径={n}/来源模式={mode}/重复={duplicates}/占位={filler_count}/缓存热={warm}");
                                assert_eq!(new.0.capacity(), old.0.capacity());
                                if n > 0 {
                                    assert!(new.2.is_some());
                                }
                                if n > 13 {
                                    let generated_tail = new
                                        .0
                                        .iter()
                                        .find(|item| item.source == CandidateSource::Generated)
                                        .expect("字面来源在评分前缀全重复后选中首条尾部");
                                    assert_eq!(generated_tail.word, decoded[12].sentence);
                                    let tail_pick = new
                                        .0
                                        .iter()
                                        .find(|item| item.source == CandidateSource::NeuralKeyboard)
                                        .expect("评分前缀全重复后确实选中尾部");
                                    assert_eq!(tail_pick.word, decoded[13].sentence);
                                }
                                if filler_count == 0
                                    && duplicates == 0
                                    && include_lattice_best
                                    && !show_next_on_duplicate
                                    && mode == 2
                                    && !warm
                                {
                                    eprintln!("合成模型合并 路径={n} 分配 {old_count}→{new_count} 路径克隆={clone_count}");
                                }
                                let transferred_count: usize = new
                                    .0
                                    .iter()
                                    .filter(|item| {
                                        matches!(
                                            item.source,
                                            CandidateSource::Generated
                                                | CandidateSource::NeuralKeyboard
                                        )
                                    })
                                    .map(|item| {
                                        let path = decoded
                                            .iter()
                                            .find(|path| path.sentence == item.word)
                                            .unwrap();
                                        count(|| path.clone()).1
                                    })
                                    .sum();
                                let unused_dedup_count = usize::from(
                                    n > 0
                                        && mode > 0
                                        && !include_lattice_best
                                        && (mode == 1 || n < 2)
                                        && input.len() + n > SMALL_SENTENCE_MERGE,
                                );
                                // 无来源已经省去集合时不重复归因；其它单路径另计一次集合申请。
                                let paths = if mode == 0 && options.emit > 0 {
                                    n.min(options.emit)
                                } else {
                                    n
                                };
                                let single_path_count = usize::from(
                                    paths == 1
                                        && input.len() + paths > SMALL_SENTENCE_MERGE
                                        && unused_dedup_count == 0,
                                );
                                assert_eq!(new_count + clone_count * keyboard_count + transferred_count + unused_dedup_count + single_path_count, old_count, "路径={n}/来源模式={mode}/重复={duplicates}/占位={filler_count}/缓存热={warm}");
                            }
                        }
                    }
                }
            }
        }
    }
    assert_eq!(cases, 1446);
}

// 冻结 50541fef8bf577ba544bb5353e689a462cdcf028 的合并及助手，仅改名、可见性和移除注释。
#[allow(clippy::too_many_arguments)]
fn legacy_merge_lattice_candidates(
    candidates: &mut Vec<WordItem>,
    syllables: &[String],
    lookup: &mut LatticeLookup<'_>,
    typed_pinyin: &str,
    options: &LatticeOptions<'_>,
    typo_source: Option<&mut TypoEdgeSource<'_>>,
    rerankers: &mut [NeuralReranker],
    rescoring_context: &str,
) -> Option<TypoSentence> {
    if syllables.len() < 2 || !has_only_complete_pinyin_segments(syllables) {
        return None;
    }
    let graph = build_graph(syllables, lookup, options);
    let mut paths = decode_graph(&graph, options, None);
    if paths.is_empty() {
        return None;
    }
    let typo = match typo_source {
        Some(source) if syllables.len() >= 3 => {
            let edges = source(&paths[0]);
            if edges.is_empty() {
                None
            } else {
                decode_typo_on_graph(&graph, options, &paths[0], &edges)
            }
        }
        _ => None,
    };

    if rerankers.is_empty() && options.emit > 0 {
        paths.truncate(options.emit);
    }
    let dedup_size = candidates.len().saturating_add(paths.len());
    let mut already =
        (dedup_size > SMALL_SENTENCE_MERGE).then(|| HashSet::with_capacity(dedup_size));
    if let Some(already) = already.as_mut() {
        already.extend(candidates.iter().map(|item| item.word.as_str()));
    }
    let block = if rerankers.is_empty() {
        if let Some(already) = already.as_mut() {
            let mut block = Vec::new();
            for path in &paths {
                if !already.insert(path.sentence.as_str()) {
                    continue;
                }
                if block.is_empty() {
                    block = Vec::with_capacity(paths.len());
                }
                block.push(legacy_sentence_row(
                    typed_pinyin,
                    path,
                    CandidateSource::Generated,
                ));
            }
            block
        } else {
            legacy_generated_block_linear(candidates, &paths, typed_pinyin)
        }
    } else {
        let mut keyboard = None;
        for reranker in rerankers
            .iter_mut()
            .filter(|reranker| reranker.source == CandidateSource::NeuralKeyboard)
        {
            let mut reranked = paths.clone();
            if reranker.rerank(&mut reranked, rescoring_context) {
                keyboard = Some(reranked);
            }
        }
        if let Some(already) = already.as_mut() {
            legacy_reranked_block(&paths, keyboard.as_deref(), options, typed_pinyin, already)
        } else {
            legacy_reranked_block_linear(
                candidates,
                &paths,
                keyboard.as_deref(),
                options,
                typed_pinyin,
            )
        }
    };
    if !block.is_empty() {
        let at = whole_sentence_insert_position(candidates, syllables);
        candidates.splice(at..at, block);
    }
    typo
}

fn legacy_sentence_row(
    typed_pinyin: &str,
    path: &SentencePath,
    source: CandidateSource,
) -> WordItem {
    let mut item = WordItem::new(
        typed_pinyin,
        path.sentence.clone(),
        (path.log_prob * 1000.0) as i64,
        source,
        path.key.clone(),
    );
    item.sentence_association = true;
    item.sentence_words = path.words.clone();
    item
}

fn legacy_sentence_seen_linear(
    candidates: &[WordItem],
    block: &[WordItem],
    sentence: &str,
) -> bool {
    candidates
        .iter()
        .chain(block)
        .any(|item| item.word == sentence)
}

fn legacy_generated_block_linear(
    candidates: &[WordItem],
    paths: &[SentencePath],
    typed_pinyin: &str,
) -> Vec<WordItem> {
    let mut block = Vec::new();
    for path in paths {
        if legacy_sentence_seen_linear(candidates, &block, &path.sentence) {
            continue;
        }
        if block.is_empty() {
            block = Vec::with_capacity(paths.len());
        }
        block.push(legacy_sentence_row(
            typed_pinyin,
            path,
            CandidateSource::Generated,
        ));
    }
    block
}

fn legacy_take_linear_sentence(
    candidates: &[WordItem],
    block: &[WordItem],
    ranked: &[SentencePath],
    source: CandidateSource,
    options: &LatticeOptions<'_>,
    typed_pinyin: &str,
) -> Option<WordItem> {
    for path in ranked {
        if !legacy_sentence_seen_linear(candidates, block, &path.sentence) {
            return Some(legacy_sentence_row(typed_pinyin, path, source));
        }
        if !options.show_next_on_duplicate {
            return None;
        }
    }
    None
}

fn legacy_reranked_block_linear(
    candidates: &[WordItem],
    paths: &[SentencePath],
    keyboard: Option<&[SentencePath]>,
    options: &LatticeOptions<'_>,
    typed_pinyin: &str,
) -> Vec<WordItem> {
    let mut block = Vec::new();
    if options.include_lattice_best {
        if let Some(row) = legacy_take_linear_sentence(
            candidates,
            &block,
            paths,
            CandidateSource::Generated,
            options,
            typed_pinyin,
        ) {
            block = Vec::with_capacity(2);
            block.push(row);
        }
    }
    if let Some(keyboard) = keyboard {
        if let Some(row) = legacy_take_linear_sentence(
            candidates,
            &block,
            keyboard,
            CandidateSource::NeuralKeyboard,
            options,
            typed_pinyin,
        ) {
            if block.is_empty() {
                block = Vec::with_capacity(2);
            }
            block.push(row);
        }
    }
    block
}

fn legacy_reranked_block<'a>(
    paths: &'a [SentencePath],
    keyboard: Option<&'a [SentencePath]>,
    options: &LatticeOptions<'_>,
    typed_pinyin: &str,
    already: &mut HashSet<&'a str>,
) -> Vec<WordItem> {
    let first_distinct =
        |ranked: &'a [SentencePath], already: &HashSet<&'a str>| -> Option<usize> {
            for (index, path) in ranked.iter().enumerate() {
                if !already.contains(path.sentence.as_str()) {
                    return Some(index);
                }
                if !options.show_next_on_duplicate {
                    return None;
                }
            }
            None
        };
    let take =
        |ranked: &'a [SentencePath], source: CandidateSource, already: &mut HashSet<&'a str>| {
            let path = &ranked[first_distinct(ranked, already)?];
            already.insert(path.sentence.as_str());
            Some(legacy_sentence_row(typed_pinyin, path, source))
        };

    let lattice = if options.include_lattice_best {
        take(paths, CandidateSource::Generated, already)
    } else {
        None
    };
    let pick =
        keyboard.and_then(|keyboard| take(keyboard, CandidateSource::NeuralKeyboard, already));
    let mut block = if lattice.is_some() || pick.is_some() {
        Vec::with_capacity(2)
    } else {
        Vec::new()
    };
    if let Some(row) = lattice {
        block.push(row);
    }
    if let Some(row) = pick {
        block.push(row);
    }
    block
}
