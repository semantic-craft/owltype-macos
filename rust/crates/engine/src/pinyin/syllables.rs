//! The 421-syllable intact list and the sets and aliases derived from it (quanpin.md §2).

use std::collections::HashSet;
use std::sync::OnceLock;

/// The longest intact syllable (`zhuang`, `chuang`, `shuang`); segmenters never try a longer piece.
pub const MAX_SYLLABLE_LENGTH: usize = 6;

#[rustfmt::skip]
static INTACT_PINYIN: [&str; 421] = [
    "a",     "ai",     "an",    "ang",   "ao",    "ba",    "bai",   "ban",   "bang",  "bao",    "bei",   "ben",
    "beng",  "bi",     "bian",  "biang", "biao",  "bie",   "bin",   "bing",  "bo",    "bu",     "ca",    "cai",
    "can",   "cang",   "cao",   "ce",    "cen",   "ceng",  "cha",   "chai",  "chan",  "chang",  "chao",  "che",
    "chen",  "cheng",  "chi",   "chong", "chou",  "chu",   "chua",  "chuai", "chuan", "chuang", "chui",  "chun",
    "chuo",  "ci",     "cong",  "cou",   "cu",    "cuan",  "cui",   "cun",   "cuo",   "da",     "dai",   "dan",
    "dang",  "dao",    "de",    "dei",   "den",   "deng",  "di",    "dia",   "dian",  "diao",   "die",   "ding",
    "diu",   "dong",   "dou",   "du",    "duan",  "dui",   "dun",   "duo",   "e",     "ei",     "en",    "er",
    "fa",    "fan",    "fang",  "fei",   "fen",   "feng",  "fiao",  "fo",    "fou",   "fu",     "ga",    "gai",
    "gan",   "gang",   "gao",   "ge",    "gei",   "gen",   "geng",  "gong",  "gou",   "gu",     "gua",   "guai",
    "guan",  "guang",  "gui",   "gun",   "guo",   "ha",    "hai",   "han",   "hang",  "hao",    "he",    "hei",
    "hen",   "heng",   "hong",  "hou",   "hu",    "hua",   "huai",  "huan",  "huang", "hui",    "hun",   "huo",
    "ji",    "jia",    "jian",  "jiang", "jiao",  "jie",   "jin",   "jing",  "jiong", "jiu",    "ju",    "juan",
    "jue",   "jun",    "jv",    "jve",   "ka",    "kai",   "kan",   "kang",  "kao",   "ke",     "kei",   "ken",
    "keng",  "kong",   "kou",   "ku",    "kua",   "kuai",  "kuan",  "kuang", "kui",   "kun",    "kuo",   "la",
    "lai",   "lan",    "lang",  "lao",   "le",    "lei",   "leng",  "li",    "lia",   "lian",   "liang", "liao",
    "lie",   "lin",    "ling",  "liu",   "lo",    "long",  "lou",   "lu",    "luan",  "lue",    "lun",   "luo",
    "lv",    "lve",    "ma",    "mai",   "man",   "mang",  "mao",   "me",    "mei",   "men",    "meng",  "mi",
    "mian",  "miao",   "mie",   "min",   "ming",  "miu",   "mo",    "mou",   "mu",    "na",     "nai",   "nan",
    "nang",  "nao",    "ne",    "nei",   "nen",   "neng",  "ni",    "nian",  "niang", "niao",   "nie",   "nin",
    "ning",  "niu",    "nong",  "nou",   "nu",    "nuan",  "nue",   "nun",   "nuo",   "nv",     "nve",   "o",
    "ou",    "pa",     "pai",   "pan",   "pang",  "pao",   "pei",   "pen",   "peng",  "pi",     "pian",  "piao",
    "pie",   "pin",    "ping",  "po",    "pou",   "pu",    "qi",    "qia",   "qian",  "qiang",  "qiao",  "qie",
    "qin",   "qing",   "qiong", "qiu",   "qu",    "quan",  "que",   "qun",   "qv",    "qve",    "ran",   "rang",
    "rao",   "re",     "ren",   "reng",  "ri",    "rong",  "rou",   "ru",    "ruan",  "rui",    "run",   "ruo",
    "sa",    "sai",    "san",   "sang",  "sao",   "se",    "sen",   "seng",  "sha",   "shai",   "shan",  "shang",
    "shao",  "she",    "shei",  "shen",  "sheng", "shi",   "shou",  "shu",   "shua",  "shuai",  "shuan", "shuang",
    "shui",  "shun",   "shuo",  "si",    "song",  "sou",   "su",    "suan",  "sui",   "sun",    "suo",   "ta",
    "tai",   "tan",    "tang",  "tao",   "te",    "teng",  "ti",    "tian",  "tiao",  "tie",    "ting",  "tong",
    "tou",   "tu",     "tuan",  "tui",   "tun",   "tuo",   "wa",    "wai",   "wan",   "wang",   "wei",   "wen",
    "weng",  "wo",     "wu",    "xi",    "xia",   "xian",  "xiang", "xiao",  "xie",   "xin",    "xing",  "xiong",
    "xiu",   "xu",     "xuan",  "xue",   "xun",   "xv",    "xve",   "ya",    "yan",   "yang",   "yao",   "ye",
    "yi",    "yin",    "ying",  "yo",    "yong",  "you",   "yu",    "yuan",  "yue",   "yun",    "yv",    "yve",
    "za",    "zai",    "zan",   "zang",  "zao",   "ze",    "zei",   "zen",   "zeng",  "zha",    "zhai",  "zhan",
    "zhang", "zhao",   "zhe",   "zhei",  "zhen",  "zheng", "zhi",   "zhong", "zhou",  "zhu",    "zhua",  "zhuai",
    "zhuan", "zhuang", "zhui",  "zhun",  "zhuo",  "zi",    "zong",  "zou",   "zu",    "zuan",   "zui",   "zun",
    "zuo",
];

/// The authoritative syllable list, in the reference order (QU:77-117). The order matters: the autocorrect generator's syllable index and the correction alias insertion order both follow it.
pub fn intact_pinyin_list() -> &'static [&'static str] {
    &INTACT_PINYIN
}

pub fn intact_pinyin_set() -> &'static HashSet<&'static str> {
    static SET: OnceLock<HashSet<&'static str>> = OnceLock::new();
    SET.get_or_init(|| INTACT_PINYIN.iter().copied().collect())
}

/// Every non-empty prefix of every intact syllable (QU:125-139).
pub fn prefix_pinyin_set() -> &'static HashSet<String> {
    static SET: OnceLock<HashSet<String>> = OnceLock::new();
    SET.get_or_init(|| {
        INTACT_PINYIN
            .iter()
            .flat_map(|syllable| (1..=syllable.len()).map(|end| syllable[..end].to_owned()))
            .collect()
    })
}

pub fn is_intact(syllable: &str) -> bool {
    intact_pinyin_set().contains(syllable)
}

pub fn is_prefix(piece: &str) -> bool {
    prefix_pinyin_set().contains(piece)
}

/// The interned intact syllable equal to `bytes`, if any. Segmenters index by byte like the C++; a piece that is not valid UTF-8 (a split multi-byte character) cannot be a syllable, so it simply does not match.
pub(crate) fn intact_piece(bytes: &[u8]) -> Option<&'static str> {
    let piece = std::str::from_utf8(bytes).ok()?;
    intact_pinyin_set().get(piece).copied()
}

/// Whether `bytes` is a prefix of some intact syllable (see `intact_piece` for the byte handling).
pub(crate) fn is_prefix_piece(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).is_ok_and(is_prefix)
}

/// Non-empty and every segment intact (QU:141-151).
pub fn has_only_complete_pinyin_segments(segments: &[String]) -> bool {
    !segments.is_empty() && segments.iter().all(|segment| is_intact(segment))
}

/// `nue`/`lue` to `nve`/`lve`, and `jv`/`qv`/`xv`/`yv` (and their `e` forms) to `u` spellings, in place (QU:158-185). The dictionary stores only those spellings.
pub fn normalize_umlaut_aliases(segments: &mut [String]) {
    for segment in segments.iter_mut() {
        let bytes = segment.as_bytes();
        // n/l keep the umlaut and the dictionary writes it `v`; `nu`/`lu` are real syllables, so only the exact three-letter `nue`/`lue` is rewritten.
        if bytes.len() == 3
            && bytes[1] == b'u'
            && bytes[2] == b'e'
            && matches!(bytes[0], b'n' | b'l')
        {
            segment.replace_range(1..2, "v");
        } else if bytes.len() >= 2
            && bytes[1] == b'v'
            && matches!(bytes[0], b'j' | b'q' | b'x' | b'y')
        {
            // j/q/x/y have no syllable that keeps the umlaut, so `v` is always an alias of `u`.
            segment.replace_range(1..2, "u");
        }
    }
}

/// The umlaut-normalised spelling of one syllable.
pub(crate) fn normalized_syllable(syllable: &str) -> String {
    let mut segments = [syllable.to_owned()];
    normalize_umlaut_aliases(&mut segments);
    let [normalized] = segments;
    normalized
}

/// The fixed per-syllable map applied to every lattice span before lookup (QQ:1345-1354).
pub fn canonical_lattice_syllable(syllable: &str) -> &str {
    match syllable {
        "jv" => "ju",
        "qv" => "qu",
        "xv" => "xu",
        "yv" => "yu",
        "jve" => "jue",
        "qve" => "que",
        "xve" => "xue",
        "yve" => "yue",
        "lue" => "lve",
        "nue" => "nve",
        other => other,
    }
}

/// The reverse spelling map, per `'`-chunk with separators kept (QU:447-469). Only the outgoing cloud query text uses it.
pub fn to_google_spelling(segmentation: &str) -> String {
    let mut result = String::with_capacity(segmentation.len());
    for (index, chunk) in segmentation.split('\'').enumerate() {
        if index > 0 {
            result.push('\'');
        }
        result.push_str(match chunk {
            "jv" => "ju",
            "qv" => "qu",
            "xv" => "xu",
            "yv" => "yu",
            "jve" => "jue",
            "qve" => "que",
            "xve" => "xue",
            "yve" => "yue",
            "lve" => "lue",
            "nve" => "nue",
            other => other,
        });
    }
    result
}

/// Alternative readings queried when a quanpin result is sparse (fewer than 8 rows) and its first segment is one of the listed spellings (QU:64-73, QU:510-536). Each returned segmentation is queried in order and appended uniquely by word.
pub fn sparse_pinyin_fallback_segments(segments: &[String]) -> Vec<Vec<String>> {
    /// A replacement head and whether the remaining segments follow it.
    type Replacement = (&'static [&'static str], bool);
    const RULES: [(&str, &[Replacement]); 4] = [
        ("dia", &[(&["di", "a"], true), (&["di"], false)]),
        ("biang", &[(&["bi", "ang"], true), (&["bi"], false)]),
        ("gei", &[(&["ge"], false)]),
        ("yo", &[(&["y"], false)]),
    ];
    let Some(first) = segments.first() else {
        return Vec::new();
    };
    let Some((_, replacements)) = RULES.iter().find(|(full, _)| first == full) else {
        return Vec::new();
    };
    replacements
        .iter()
        .map(|(head, append_rest)| {
            let mut fallback: Vec<String> = head.iter().map(|part| (*part).to_owned()).collect();
            if *append_rest {
                fallback.extend(segments[1..].iter().cloned());
            }
            fallback
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segments(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|part| (*part).to_owned()).collect()
    }

    #[test]
    fn the_list_has_the_reference_shape() {
        assert_eq!(intact_pinyin_list().len(), 421);
        assert_eq!(intact_pinyin_set().len(), 421);
        assert_eq!(
            intact_pinyin_list().iter().map(|s| s.len()).max(),
            Some(MAX_SYLLABLE_LENGTH)
        );
        for rare in [
            "biang", "den", "dia", "fiao", "kei", "lo", "nou", "nun", "shei", "zhei", "yo", "jv",
            "jve", "lue", "nue", "er",
        ] {
            assert!(is_intact(rare), "{rare}");
        }
        for absent in ["eng", "m", "n", "ng", "hm", "wanr", "ger"] {
            assert!(!is_intact(absent), "{absent}");
        }
    }

    #[test]
    fn the_prefix_set_holds_every_syllable_prefix() {
        assert!(is_prefix("z") && is_prefix("zh") && is_prefix("zhua") && is_prefix("zhuang"));
        for absent in ["i", "u", "v", "eng", "zhuangg"] {
            assert!(!is_prefix(absent), "{absent}");
        }
    }

    #[test]
    fn complete_segments_need_every_segment_intact() {
        assert!(has_only_complete_pinyin_segments(&segments(&["ni", "hao"])));
        assert!(!has_only_complete_pinyin_segments(&segments(&["ni", "h"])));
        assert!(!has_only_complete_pinyin_segments(&[]));
    }

    #[test]
    fn umlaut_aliases_normalise_to_the_dictionary_spelling() {
        let mut typed = segments(&[
            "nue", "lue", "jv", "qve", "xv", "yve", "nv", "lv", "nu", "lu", "nve", "jue",
        ]);
        normalize_umlaut_aliases(&mut typed);
        assert_eq!(
            typed,
            segments(&[
                "nve", "lve", "ju", "que", "xu", "yue", "nv", "lv", "nu", "lu", "nve", "jue"
            ])
        );
        assert_eq!(normalized_syllable("lue"), "lve");
    }

    #[test]
    fn lattice_spelling_matches_the_alias_rule_per_syllable() {
        for syllable in intact_pinyin_list() {
            assert_eq!(
                canonical_lattice_syllable(syllable),
                normalized_syllable(syllable),
                "{syllable}"
            );
        }
    }

    #[test]
    fn google_spelling_rewrites_whole_chunks_only() {
        assert_eq!(to_google_spelling("nve'dai'dong'wu"), "nue'dai'dong'wu");
        assert_eq!(to_google_spelling("wo'men'lve'de"), "wo'men'lue'de");
        assert_eq!(to_google_spelling("jv'qve'xve'yv"), "ju'que'xue'yu");
        assert_eq!(to_google_spelling("nv'er"), "nv'er");
        assert_eq!(to_google_spelling("nvedaidongwu"), "nvedaidongwu");
        assert_eq!(to_google_spelling("ni'"), "ni'");
        assert_eq!(to_google_spelling(""), "");
    }

    #[test]
    fn sparse_fallbacks_follow_the_rule_table() {
        assert_eq!(
            sparse_pinyin_fallback_segments(&segments(&["dia", "hao"])),
            vec![segments(&["di", "a", "hao"]), segments(&["di"])]
        );
        assert_eq!(
            sparse_pinyin_fallback_segments(&segments(&["biang"])),
            vec![segments(&["bi", "ang"]), segments(&["bi"])]
        );
        assert_eq!(
            sparse_pinyin_fallback_segments(&segments(&["gei", "ni"])),
            vec![segments(&["ge"])]
        );
        assert_eq!(
            sparse_pinyin_fallback_segments(&segments(&["yo"])),
            vec![segments(&["y"])]
        );
        assert!(sparse_pinyin_fallback_segments(&segments(&["ni"])).is_empty());
        assert!(sparse_pinyin_fallback_segments(&[]).is_empty());
    }
}
