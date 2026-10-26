//! Punctuation styles and host-context policy extracted from pinned msime-client-core.
//! Snapshot serde derives support the Owl host JSON transport; policy functions are unchanged.

use crate::preferences::{BracketStyle, PunctuationLock};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuoteMarks {
    #[default]
    Curly,
    Corner,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct PunctuationMarks {
    pub quotes: QuoteMarks,
    pub brackets: BracketStyle,
    pub enumeration_comma_backslash: bool,
    pub enumeration_comma_slash: bool,
}

impl Default for PunctuationMarks {
    fn default() -> Self {
        Self {
            quotes: QuoteMarks::Curly,
            brackets: BracketStyle::Solid,
            enumeration_comma_backslash: true,
            enumeration_comma_slash: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PunctuationRoute {
    Engine,
    Ascii,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PunctuationContext {
    pub character: u8,
    pub preceding: Option<char>,
    pub host_context_available: bool,
    pub has_composition: bool,
    pub chinese_punctuation: bool,
    pub smart_punctuation: bool,
    /// 数字后、字母后的 `,` `.` `:` 保留 ASCII。拆成两个开关，是因为版本号和英文句子要的答案可能不同；两者都跟着智能标点默认开，用户可以单独关掉一半，宿主不能无视它们。
    pub direct_digit: bool,
    pub direct_letter: bool,
    pub lock: PunctuationLock,
    /// 大写锁定打开、且用户打开了 `caps_lock_ascii_punctuation`。为真时没有组字的标点和英文模式一样走 ASCII，`lock` 为 `Chinese` 时仍归 Engine。
    pub caps_lock_ascii: bool,
}

/// 只在宿主能安全按文档上下文决定时才选显式 ASCII 路线。组字中、本地/日文/英文模式、韩文（标点总是半角 ASCII），以及共享智能标点约定和大写锁定开关都不管的标点，仍由 Engine 决定。
pub fn route(context: PunctuationContext) -> PunctuationRoute {
    if context.has_composition || !context.host_context_available {
        return PunctuationRoute::Engine;
    }
    match context.lock {
        PunctuationLock::Chinese => return PunctuationRoute::Engine,
        PunctuationLock::English => return PunctuationRoute::Ascii,
        PunctuationLock::Follow => {}
    }
    if context.caps_lock_ascii {
        return PunctuationRoute::Ascii;
    }
    let direct = context.preceding.is_some_and(|value| {
        (value.is_ascii_digit() && context.direct_digit)
            || (value.is_ascii_alphabetic() && context.direct_letter)
    });
    if context.chinese_punctuation
        && context.smart_punctuation
        && matches!(context.character, b',' | b'.' | b':')
        && direct
    {
        PunctuationRoute::Ascii
    } else {
        PunctuationRoute::Engine
    }
}

/// The Chinese mark an ASCII one converts to, for the three the repeat gesture covers.
fn chinese_mark(ascii: u8) -> Option<char> {
    match ascii {
        b',' => Some('，'),
        b'.' => Some('。'),
        b':' => Some('：'),
        _ => None,
    }
}

/// The full-width twin of an ASCII mark, for hosts that commit one instead.
fn full_width_mark(ascii: u8) -> char {
    match ascii {
        b',' => '\u{ff0c}',
        b'.' => '\u{ff0e}',
        b':' => '\u{ff1a}',
        _ => ascii as char,
    }
}

/// What the previous press of a smart-punctuation key left behind.
///
/// Armed only when the press actually committed the ASCII mark that was asked for - or its
/// full-width twin, which is what a full-width host commits. `editor_generation` is the host's
/// own counter for "the caret is still where it was and the document is still the same one".
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RepeatSnapshot {
    pub ascii: u8,
    /// The scalar the first press committed.
    pub committed: char,
    pub timestamp_ms: u64,
    pub editor_generation: u64,
}

/// Arm the repeat gesture after a commit, or decline to.
pub fn arm_repeat(
    ascii: u8,
    commit: &str,
    timestamp_ms: u64,
    editor_generation: u64,
) -> Option<RepeatSnapshot> {
    chinese_mark(ascii)?;
    let committed = commit.chars().next_back()?;
    if committed != ascii as char && committed != full_width_mark(ascii) {
        return None;
    }
    Some(RepeatSnapshot {
        ascii,
        committed,
        timestamp_ms,
        editor_generation,
    })
}

/// How long after the first press the second one still counts as a correction.
pub const REPEAT_WINDOW_MS: u64 = 2000;

/// What the host knows when the same punctuation key is pressed again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RepeatContext {
    pub ascii: u8,
    pub preceding: Option<char>,
    pub timestamp_ms: u64,
    pub editor_generation: u64,
    pub smart_punctuation: bool,
    pub repeat_enabled: bool,
    pub has_composition: bool,
    pub candidate_count: usize,
}

/// Pressing the same mark again within the window replaces the ASCII one with Chinese.
///
/// The user asked for ASCII by context and is now saying they meant the Chinese mark after all,
/// so this only fires when the document still holds exactly what the first press committed: a
/// composition, any candidate on screen, a moved caret or a different editor all mean the gesture
/// is about something else.
pub fn should_replace_repeat(
    snapshot: Option<RepeatSnapshot>,
    context: RepeatContext,
) -> Option<char> {
    if !context.smart_punctuation
        || !context.repeat_enabled
        || context.has_composition
        || context.candidate_count != 0
    {
        return None;
    }
    let snapshot = snapshot?;
    if snapshot.ascii != context.ascii
        || snapshot.editor_generation != context.editor_generation
        || context.preceding != Some(snapshot.committed)
    {
        return None;
    }
    if context.timestamp_ms.checked_sub(snapshot.timestamp_ms)? > REPEAT_WINDOW_MS {
        return None;
    }
    chinese_mark(context.ascii)
}

/// `、` 的 ASCII 孪生按当前开着的顿号键判（契约 `enumerationComma` 段）：`source` 是产生它的键，开着时原样转回；不是顿号键（候选上屏）时按契约序取开着的那个——`\` 优先、`/` 其次；两个都关按归一的 `\`。
pub fn enumeration_comma_ascii(source: u8, marks: &PunctuationMarks) -> u8 {
    match source {
        b'\\' if marks.enumeration_comma_backslash => b'\\',
        b'/' if marks.enumeration_comma_slash => b'/',
        _ if marks.enumeration_comma_backslash => b'\\',
        _ if marks.enumeration_comma_slash => b'/',
        _ => b'\\',
    }
}

/// The ASCII twin of a Chinese punctuation mark, or `None` where there is none.
///
/// Both quote directions map to the same ASCII quote: a straight quote has no handedness. 直角引号和空心方头括号是同一个键的另一组字（`quote_style`、`bracket_style`），同样转回那个键。顿号按 `source`（产生它的键，没有时传 0）和 `marks` 里开着的顿号键定。
pub fn ascii_for_chinese_mark(chinese: char, source: u8, marks: &PunctuationMarks) -> Option<u8> {
    Some(match chinese {
        '。' => b'.',
        '\u{ff0c}' => b',',
        '！' => b'!',
        '？' => b'?',
        '；' => b';',
        '\u{ff1a}' => b':',
        '、' => enumeration_comma_ascii(source, marks),
        '\u{201c}' | '\u{201d}' => b'"',
        '\u{2018}' | '\u{2019}' => b'\'',
        '『' | '』' => b'"',
        '「' | '」' => b'\'',
        '【' | '〖' => b'[',
        '】' | '〗' => b']',
        '《' => b'<',
        '》' => b'>',
        '（' => b'(',
        '）' => b')',
        _ => return None,
    })
}

/// A Chinese mark that a following space would rewrite as ASCII.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SpaceConvertSnapshot {
    pub chinese: char,
    /// Resolved when arming, so the conversion cannot disagree with what armed it.
    pub ascii: u8,
    pub editor_generation: u64,
}

/// Arm the space conversion after a commit, or decline to.
///
/// An auto-closed pair is refused: the caret sits between the two marks, so the character before
/// it is the opening one and rewriting that would break the pair. A commit of more than one scalar
/// is refused too - the mark has to be the last thing typed for the space to be about it.
pub fn arm_space_convert(
    committed: &str,
    auto_closed_pair: bool,
    smart_punctuation: bool,
    space_convert: bool,
    editor_generation: u64,
    source: u8,
    marks: &PunctuationMarks,
) -> Option<SpaceConvertSnapshot> {
    if !smart_punctuation || !space_convert || auto_closed_pair {
        return None;
    }
    let mut characters = committed.chars();
    let chinese = characters.next()?;
    if characters.next().is_some() {
        return None;
    }
    Some(SpaceConvertSnapshot {
        chinese,
        ascii: ascii_for_chinese_mark(chinese, source, marks)?,
        editor_generation,
    })
}

/// A space right after a committed Chinese mark rewrites it as ASCII and is swallowed.
///
/// Swallowing the space is the whole gesture: the user is correcting the mark they just typed,
/// not typing a mark and then a space. Nothing here is time-limited - the arming survives as long
/// as the caret has not moved and the editor has not changed - because the decision re-reads what
/// is actually before the caret and declines when it disagrees.
pub fn decide_space_convert(
    snapshot: Option<SpaceConvertSnapshot>,
    character: u8,
    preceding: Option<char>,
    has_composition: bool,
    editor_generation: u64,
) -> Option<u8> {
    let snapshot = snapshot?;
    if character != b' ' || has_composition || snapshot.editor_generation != editor_generation {
        return None;
    }
    if preceding != Some(snapshot.chinese) {
        return None;
    }
    Some(snapshot.ascii)
}
