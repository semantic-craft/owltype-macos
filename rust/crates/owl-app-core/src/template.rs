//! Template semantics. Native services supply calendar arithmetic and formatted facts only.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use unicode_segmentation::UnicodeSegmentation;

type Map = BTreeMap<String, String>;
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(from = "[usize; 2]", into = "[usize; 2]")]
pub struct Range {
    pub location: usize,
    pub length: usize,
}
impl From<[usize; 2]> for Range {
    fn from(v: [usize; 2]) -> Self {
        Self {
            location: v[0],
            length: v[1],
        }
    }
}
impl From<Range> for [usize; 2] {
    fn from(v: Range) -> Self {
        [v.location, v.length]
    }
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Diagnostic {
    pub severity: String,
    pub range: Range,
    pub message: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum Kind {
    Literal,
    Parameter(String),
    Clipboard,
    Temporal(TemporalField),
    Cursor,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Token {
    pub raw: String,
    pub range: Range,
    pub kind: Kind,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Offset {
    pub component: String,
    pub value: i32,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct TemporalField {
    pub kind: String,
    pub format: Option<String>,
    pub offsets: Vec<Offset>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Parameter {
    pub key: String,
    pub name: String,
    pub is_required: bool,
    pub default_value: Option<String>,
    pub options: Vec<String>,
    #[serde(default)]
    pub legacy: bool,
    #[serde(default)]
    pub ranges: Vec<Range>,
}
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Parsed {
    pub tokens: Vec<Token>,
    pub parameters: Vec<Parameter>,
    pub diagnostics: Vec<Diagnostic>,
    pub context_requirements: BTreeSet<String>,
    #[serde(default)]
    pub initial_values: Map,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Evaluation {
    pub preview_text: String,
    pub diagnostics: Vec<Diagnostic>,
    pub missing_keys: Vec<String>,
    pub needs_empty_clipboard_decision: bool,
    pub cursor_offset: Option<usize>,
}
#[derive(Default, Deserialize)]
pub struct TemporalFact {
    pub text: Option<String>,
    pub error: Option<String>,
}
fn normalized(s: &str) -> String {
    icu_normalizer::ComposingNormalizer::new_nfc()
        .normalize(s)
        .into_owned()
}
fn equal(a: &str, b: &str) -> bool {
    a == b || normalized(a) == normalized(b)
}
fn same_options(a: &[String], b: &[String]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(a, b)| equal(a, b))
}
fn contains(options: &[String], value: &str) -> bool {
    options.iter().any(|s| equal(s, value))
}
fn lookup<'a>(values: &'a Map, key: &str) -> Option<&'a String> {
    values
        .get(key)
        .or_else(|| values.iter().find(|(k, _)| equal(k, key)).map(|(_, v)| v))
}
fn trim(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
}
fn issue(p: &mut Parsed, range: &Range, message: &str, warning: bool) {
    p.diagnostics.push(Diagnostic {
        severity: if warning { "warning" } else { "error" }.into(),
        range: range.clone(),
        message: message.into(),
    });
}
fn token(p: &mut Parsed, source: &str, offsets: &[usize], a: usize, b: usize, kind: Kind) {
    if a < b {
        p.tokens.push(Token {
            raw: source[a..b].into(),
            range: Range {
                location: offsets[a],
                length: offsets[b] - offsets[a],
            },
            kind,
        });
    }
}
fn parameter(
    p: &mut Parsed,
    name: Option<&str>,
    attrs: &Map,
    range: &Range,
    legacy: bool,
    anonymous: &mut usize,
) -> Kind {
    let (mut key, display) = if let Some(n) = name {
        (format!("n:{n}"), n.to_string())
    } else {
        *anonymous += 1;
        (format!("a:{anonymous}"), format!("参数 {anonymous}"))
    };
    let options: Vec<String> = attrs
        .get("options")
        .map(|s| s.split(',').map(|s| trim(s).to_string()).collect())
        .unwrap_or_default();
    if options.iter().any(String::is_empty) {
        issue(p, range, "选项不能包含空项。", false);
    }
    let mut seen = BTreeSet::new();
    let options: Vec<String> = options
        .into_iter()
        .filter(|s| seen.insert(normalized(s)))
        .collect();
    let value = attrs.get("default").cloned();
    if let Some(i) = p.parameters.iter().position(|p| equal(&p.key, &key)) {
        let mut old = p.parameters[i].clone();
        key = old.key.clone();
        if let Some(value) = value {
            if old
                .default_value
                .as_ref()
                .is_some_and(|v| !equal(v, &value))
            {
                issue(p, range, "同名参数的默认值不一致。", false);
            } else {
                old.default_value = Some(value);
            }
        }
        if !options.is_empty() {
            if !old.options.is_empty() && !same_options(&old.options, &options) {
                issue(p, range, "同名参数的选项不一致。", false);
            } else {
                old.options = options;
            }
        }
        if !legacy {
            old.legacy = false;
            old.is_required = true;
        }
        old.ranges.push(range.clone());
        p.parameters[i] = old;
    } else {
        p.parameters.push(Parameter {
            key: key.clone(),
            name: display,
            is_required: !legacy,
            default_value: value,
            options,
            legacy,
            ranges: vec![range.clone()],
        });
    }
    Kind::Parameter(key)
}
// Swift Character predicates operate on extended graphemes, not individual scalars.
fn letter(s: &str) -> bool {
    s.chars().next().is_some_and(char::is_alphabetic)
}
fn whitespace(s: &str) -> bool {
    s.chars().next().is_some_and(char::is_whitespace)
}
fn attributes(text: &str) -> Result<Map, &'static str> {
    let mut rest = text;
    let mut attrs = Map::new();
    while !rest.is_empty() {
        if !rest.graphemes(true).next().is_some_and(whitespace) {
            return Err("字段属性之间需要空格。");
        }
        let n: usize = rest
            .graphemes(true)
            .take_while(|g| whitespace(g))
            .map(str::len)
            .sum();
        rest = &rest[n..];
        if rest.is_empty() {
            break;
        }
        let n: usize = rest
            .graphemes(true)
            .take_while(|g| letter(g))
            .map(str::len)
            .sum();
        if n == 0 {
            return Err("字段属性格式无效。");
        }
        let key = rest[..n].to_string();
        rest = &rest[n..];
        if rest.graphemes(true).next() != Some("=") {
            return Err("字段属性缺少等号。");
        }
        rest = &rest[1..];
        let mut value = String::new();
        if rest.graphemes(true).next() == Some("\"") {
            rest = &rest[1..];
            let mut closed = false;
            while let Some(c) = rest.graphemes(true).next() {
                rest = &rest[c.len()..];
                if c == "\"" {
                    closed = true;
                    break;
                }
                if c == "\\" {
                    let e = rest.graphemes(true).next().ok_or("不支持的字段转义。")?;
                    if e != "\\" && e != "\"" {
                        return Err("不支持的字段转义。");
                    }
                    value.push_str(e);
                    rest = &rest[e.len()..];
                } else {
                    value.push_str(c);
                }
            }
            if !closed {
                return Err("字段引号未闭合。");
            }
        } else {
            let n: usize = rest
                .graphemes(true)
                .take_while(|g| !whitespace(g))
                .map(str::len)
                .sum();
            value = rest[..n].into();
            rest = &rest[n..];
            if value.is_empty()
                || value
                    .graphemes(true)
                    .any(|g| ["{", "}", "\"", "\\", "|"].contains(&g))
            {
                return Err("字段属性值无效。");
            }
        }
        if attrs.insert(key, value).is_some() {
            return Err("字段属性重复。");
        }
    }
    Ok(attrs)
}
fn temporal(kind: &str, attrs: &Map) -> Result<TemporalField, &'static str> {
    if let Some(f) = attrs.get("format") {
        pattern_parts(f)?;
    }
    let mut offsets = vec![];
    if let Some(source) = attrs.get("offset") {
        let mut parts = Vec::new();
        let mut start = 0;
        for (index, g) in source.grapheme_indices(true) {
            if whitespace(g) {
                if start < index {
                    parts.push(&source[start..index]);
                }
                start = index + g.len();
            }
        }
        if start < source.len() {
            parts.push(&source[start..]);
        }
        if parts.is_empty() {
            return Err("日期偏移不能为空；无偏移请移除 offset。");
        }
        for part in parts {
            let unit = part.graphemes(true).next_back().unwrap();
            let number = &part[..part.len() - unit.len()];
            let valid = number.len() > 1
                && matches!(number.as_bytes()[0], b'+' | b'-')
                && number.as_bytes()[1..].iter().all(u8::is_ascii_digit);
            let value = if valid {
                number.parse::<i64>().ok()
            } else {
                None
            }
            .ok_or("日期偏移需使用 +2d 或 -30m，组合项之间用空格分隔。")?;
            let value = i32::try_from(value).map_err(|_| "日期偏移数值超出支持范围。")?;
            let component = match unit {
                "m" => "minute",
                "h" => "hour",
                "d" => "day",
                "M" => "month",
                "y" => "year",
                _ => return Err("日期偏移单位仅支持 m、h、d、M、y；m 是分钟，M 是月。"),
            };
            offsets.push(Offset {
                component: component.into(),
                value,
            });
        }
    }
    Ok(TemporalField {
        kind: kind.into(),
        format: attrs.get("format").cloned(),
        offsets,
    })
}
fn known(
    p: &mut Parsed,
    head: &str,
    inside: &str,
    range: &Range,
    anonymous: &mut usize,
) -> Result<Kind, &'static str> {
    let attrs = attributes(&inside[head.len()..])?;
    let allowed: &[&str] = match head {
        "argument" => &["name", "default", "options"],
        "clipboard" | "cursor" => &[],
        _ => &["format", "offset"],
    };
    if attrs.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err("该字段含不支持的参数或修饰器。");
    }
    Ok(match head {
        "argument" => {
            let name = attrs.get("name").map(|s| trim(s));
            if name == Some("") {
                return Err("参数名称不能为空；匿名参数请省略 name。");
            }
            parameter(p, name, &attrs, range, false, anonymous)
        }
        "cursor" => {
            if p.tokens.iter().any(|t| matches!(t.kind, Kind::Cursor)) {
                issue(p, range, "每条模板最多一个光标字段。", false);
            }
            Kind::Cursor
        }
        "clipboard" => {
            p.context_requirements.insert("clipboard".into());
            Kind::Clipboard
        }
        _ => {
            let field = temporal(head, &attrs)?;
            p.context_requirements.insert("temporal".into());
            Kind::Temporal(field)
        }
    })
}
pub fn parse(
    body: &str,
    plain: bool,
    legacy: bool,
    pending: bool,
    definitions: Vec<Parameter>,
) -> Parsed {
    // Convert byte boundaries once. Recounting every prefix makes many small fields quadratic.
    let mut offsets = vec![0; body.len() + 1];
    let mut units = 0;
    for (byte, c) in body.char_indices() {
        offsets[byte] = units;
        units += c.len_utf16();
    }
    offsets[body.len()] = units;
    let mut p = Parsed::default();
    if pending {
        let range = Range {
            location: 0,
            length: body.encode_utf16().count(),
        };
        p.tokens.push(Token {
            raw: body.into(),
            range: range.clone(),
            kind: Kind::Literal,
        });
        issue(
            &mut p,
            &range,
            "导入条目待处理；请在设置中修正并启用，或明确转为普通文本。",
            false,
        );
        return p;
    }
    if plain {
        token(&mut p, body, &offsets, 0, body.len(), Kind::Literal);
        return p;
    }
    // ICU dot excludes all line terminators, not just LF.
    let re = regex::Regex::new(r"\{\{([^\n\r\x0B\x0C\u{85}\u{2028}\u{2029}]*?)\}\}").unwrap();
    let matches: BTreeMap<usize, (usize, &str)> = re
        .captures_iter(body)
        .map(|c| {
            let m = c.get(0).unwrap();
            (m.start(), (m.end(), c.get(1).unwrap().as_str()))
        })
        .collect();
    let mut i = 0;
    let mut literal_start = 0;
    let mut anonymous = 0;
    while i < body.len() {
        if let Some(&(end, name)) = matches.get(&i) {
            token(&mut p, body, &offsets, literal_start, i, Kind::Literal);
            let range = Range {
                location: offsets[i],
                length: offsets[end] - offsets[i],
            };
            let name = trim(name);
            let kind = if name.is_empty() {
                Kind::Literal
            } else {
                parameter(
                    &mut p,
                    Some(name),
                    &Map::new(),
                    &range,
                    true,
                    &mut anonymous,
                )
            };
            token(&mut p, body, &offsets, i, end, kind);
            i = end;
            literal_start = i;
            continue;
        }
        if legacy || body.as_bytes()[i] != b'{' {
            i += body[i..].chars().next().unwrap().len_utf8();
            continue;
        }
        token(&mut p, body, &offsets, literal_start, i, Kind::Literal);
        let mut quoted = false;
        let mut escaped = false;
        let mut close = None;
        for (pos, c) in body[i + 1..].char_indices() {
            if escaped {
                escaped = false;
            } else if c == '\\' && quoted {
                escaped = true;
            } else if c == '"' {
                quoted = !quoted;
            } else if c == '}' && !quoted {
                close = Some(i + 1 + pos);
                break;
            }
        }
        let end = close.map(|j| j + 1).unwrap_or(body.len());
        let inside = &body[i + 1..close.unwrap_or(body.len())];
        let n: usize = inside
            .graphemes(true)
            .take_while(|g| letter(g) || *g == "-")
            .map(str::len)
            .sum();
        let head = &inside[..n];
        let range = Range {
            location: offsets[i],
            length: offsets[end] - offsets[i],
        };
        let kind = if [
            "argument",
            "clipboard",
            "date",
            "time",
            "datetime",
            "cursor",
        ]
        .contains(&head)
        {
            let result = if close.is_none() {
                Err("字段缺少闭合花括号或引号。")
            } else {
                known(&mut p, head, inside, &range, &mut anonymous)
            };
            match result {
                Ok(k) => k,
                Err(m) => {
                    issue(&mut p, &range, m, false);
                    Kind::Literal
                }
            }
        } else {
            if !head.is_empty() {
                issue(&mut p, &range, "未支持的字段将原样插入。", true);
            }
            Kind::Literal
        };
        token(&mut p, body, &offsets, i, end, kind);
        i = end;
        literal_start = i;
    }
    token(
        &mut p,
        body,
        &offsets,
        literal_start,
        body.len(),
        Kind::Literal,
    );
    let mut defined = BTreeSet::new();
    for d in definitions {
        if !defined.insert(normalized(&d.key)) {
            issue(&mut p, &Range::default(), "参数定义重复。", false);
            continue;
        }
        let Some(i) = p.parameters.iter().position(|p| equal(&p.key, &d.key)) else {
            issue(
                &mut p,
                &Range::default(),
                "参数定义没有对应的正文位置，请删除过期设置。",
                true,
            );
            continue;
        };
        let mut v = p.parameters[i].clone();
        let range = v.ranges[0].clone();
        v.is_required = d.is_required;
        if let Some(value) = d.default_value {
            if v.default_value.as_ref().is_some_and(|x| !equal(x, &value)) {
                issue(&mut p, &range, "正文与参数设置的默认值不一致。", false);
            }
            v.default_value = Some(value);
        }
        if !d.options.is_empty() {
            if !v.options.is_empty() && !same_options(&v.options, &d.options) {
                issue(&mut p, &range, "正文与参数设置的选项不一致。", false);
            }
            v.options = d.options;
        }
        p.parameters[i] = v;
    }
    for v in p.parameters.clone() {
        if v.options.iter().any(String::is_empty) {
            issue(&mut p, &v.ranges[0], "选项不能包含空项。", false);
        }
        if let Some(value) = &v.default_value {
            if !v.options.is_empty()
                && !contains(&v.options, value)
                && !(value.is_empty() && !v.is_required)
            {
                issue(&mut p, &v.ranges[0], "默认值必须属于预设选项。", false);
            }
            p.initial_values.insert(v.key.clone(), value.clone());
        } else if v.legacy {
            p.initial_values.insert(v.key.clone(), String::new());
        }
    }
    if p.context_requirements.is_empty()
        && p.parameters.is_empty()
        && p.tokens.iter().any(|t| matches!(t.kind, Kind::Cursor))
        && !has_errors(&p.diagnostics)
    {
        p.diagnostics = render(
            &p,
            &Map::new(),
            "notRequested",
            None,
            false,
            &BTreeMap::new(),
        )
        .diagnostics;
    }
    p
}
fn has_errors(d: &[Diagnostic]) -> bool {
    d.iter().any(|d| d.severity == "error")
}
pub fn render(
    p: &Parsed,
    values: &Map,
    clipboard: &str,
    clipboard_text: Option<&str>,
    allow_empty: bool,
    temporal: &BTreeMap<String, TemporalFact>,
) -> Evaluation {
    let mut diagnostics = p.diagnostics.clone();
    let mut missing = vec![];
    for v in &p.parameters {
        let Some(value) = lookup(values, &v.key) else {
            missing.push(v.key.clone());
            continue;
        };
        if v.is_required && trim(value).is_empty() {
            missing.push(v.key.clone());
        } else if !v.options.is_empty()
            && !contains(&v.options, value)
            && !(value.is_empty() && !v.is_required)
        {
            missing.push(v.key.clone());
            diagnostics.push(Diagnostic {
                severity: "error".into(),
                range: v.ranges.first().cloned().unwrap_or_default(),
                message: "请选择有效的预设选项。".into(),
            });
        }
    }
    let mut text = String::new();
    let mut cursor = None;
    let mut cursor_range = Range::default();
    let mut needs = false;
    for (index, t) in p.tokens.iter().enumerate() {
        let mut error = None;
        match &t.kind {
            Kind::Literal => text.push_str(&t.raw),
            Kind::Parameter(k) => text.push_str(if missing.contains(k) {
                &t.raw
            } else {
                lookup(values, k).unwrap_or(&t.raw)
            }),
            Kind::Cursor => {
                if cursor.is_none() {
                    cursor = Some(text.encode_utf16().count());
                    cursor_range = t.range.clone();
                }
            }
            Kind::Clipboard => match clipboard {
                "text" if clipboard_text.is_some_and(|s| !s.is_empty()) => {
                    text.push_str(clipboard_text.unwrap())
                }
                "notRequested" => {
                    text.push_str(&t.raw);
                    error = Some("尚未采集本次剪贴板文本，请重新调用模板。".to_string());
                }
                _ => {
                    if !allow_empty {
                        text.push_str(&t.raw);
                        needs = true;
                    }
                }
            },
            Kind::Temporal(_) => {
                match temporal.get(&index.to_string()) {
                    None => error = Some("尚未采集本次时间，请重新调用模板。".into()),
                    Some(f) => {
                        if let Some(e) = &f.error {
                            error = Some(e.clone());
                        } else if let Some(s) = &f.text {
                            if s.is_empty() {
                                error = Some("日期格式没有产生文本，请调整 format。".into());
                            } else {
                                text.push_str(s);
                            }
                        } else {
                            error = Some("日期字段无法展开。".into());
                        }
                    }
                }
                if error.is_some() {
                    text.push_str(&t.raw);
                }
            }
        }
        if let Some(message) = error {
            diagnostics.push(Diagnostic {
                severity: "error".into(),
                range: t.range.clone(),
                message,
            });
        }
    }
    if let Some(offset) = cursor {
        if missing.is_empty() && !needs && !has_errors(&diagnostics) {
            let mut units = 0;
            let mut boundary = offset == 0;
            for g in text.graphemes(true) {
                units += g.encode_utf16().count();
                boundary |= units == offset;
            }
            if text.is_empty() || !boundary {
                diagnostics.push(Diagnostic {
                    severity: "error".into(),
                    range: cursor_range,
                    message: if text.is_empty() {
                        "展开结果为空，未插入；请在光标字段旁添加正文。"
                    } else {
                        "光标字段不能位于组合字符或换行序列内部，请调整位置。"
                    }
                    .into(),
                });
            }
        }
    }
    Evaluation {
        preview_text: text,
        diagnostics,
        missing_keys: missing,
        needs_empty_clipboard_decision: needs,
        cursor_offset: cursor,
    }
}
#[derive(Clone, Deserialize, Serialize)]
pub struct PatternPart {
    pub literal: Option<String>,
    pub symbol: Option<char>,
    pub count: usize,
}
fn pattern_parts(pattern: &str) -> Result<Vec<PatternPart>, &'static str> {
    if pattern.is_empty() {
        return Err("日期格式不能为空；默认格式请移除 format。");
    }
    let chars: Vec<_> = pattern.chars().collect();
    let mut i = 0;
    let mut quoted = false;
    let mut literal = String::new();
    let mut parts = vec![];
    while i < chars.len() {
        let c = chars[i];
        if c == '\'' {
            if chars.get(i + 1) == Some(&'\'') {
                literal.push('\'');
                i += 2;
                continue;
            }
            quoted = !quoted;
            i += 1;
            continue;
        }
        if quoted || !c.is_ascii_alphabetic() {
            literal.push(c);
            i += 1;
            continue;
        }
        if !literal.is_empty() {
            parts.push(PatternPart {
                literal: Some(std::mem::take(&mut literal)),
                symbol: None,
                count: 0,
            });
        }
        let mut end = i + 1;
        while chars.get(end) == Some(&c) {
            end += 1;
        }
        let count = end - i;
        let valid = match c {
            'y' | 'Y' | 'u' | 'r' | 'g' | 'S' | 'A' => true,
            'G' | 'U' | 'Q' | 'q' | 'M' | 'L' | 'a' | 'b' | 'B' | 'Z' | 'X' | 'x' => count <= 5,
            'E' | 'e' | 'c' => count <= 6,
            'w' | 'd' | 'h' | 'H' | 'K' | 'k' | 'm' | 's' => count <= 2,
            'D' => count <= 3,
            'F' | 'W' | 'l' => count == 1,
            'z' | 'V' => count <= 4,
            'O' | 'v' => count == 1 || count == 4,
            'j' | 'J' | 'C' => {
                return Err("format 需要具体日期格式；j、J、C 是本地化格式骨架符号。")
            }
            _ => return Err("日期格式含未定义字母；字面英文请放在单引号内。"),
        };
        if !valid {
            return Err("日期格式字段的重复长度不受 Unicode 日期格式支持。");
        }
        parts.push(PatternPart {
            literal: None,
            symbol: Some(c),
            count,
        });
        i = end;
    }
    if quoted {
        return Err("日期格式中的单引号未闭合。");
    }
    if !literal.is_empty() {
        parts.push(PatternPart {
            literal: Some(literal),
            symbol: None,
            count: 0,
        });
    }
    Ok(parts)
}
fn week(p: &PatternPart) -> bool {
    matches!(p.symbol, Some('Y' | 'w' | 'W'))
        || (matches!(p.symbol, Some('e' | 'c')) && p.count <= 2)
}
#[derive(Serialize)]
pub struct DatePlan {
    pub error: Option<String>,
    pub pattern: Option<String>,
    pub parts: Vec<PatternPart>,
}
fn date_error(message: &str) -> DatePlan {
    DatePlan {
        error: Some(message.into()),
        pattern: None,
        parts: vec![],
    }
}
fn valid_date(date: Option<f64>) -> bool {
    date.is_some_and(|d| (-211845067200.0..=15927175497600.0).contains(&d))
}
pub fn date_plan(
    field: &TemporalField,
    default_pattern: Option<&str>,
    date: Option<f64>,
) -> DatePlan {
    if !valid_date(date) {
        return date_error("本次日期无效，请重新调用模板。");
    }
    let Some(pattern) = field
        .format
        .as_deref()
        .or(default_pattern)
        .filter(|p| !p.is_empty())
    else {
        return date_error("本次日期格式不可用，请指定 format 或重新调用模板。");
    };
    match pattern_parts(pattern) {
        Ok(parts) => DatePlan {
            error: None,
            pattern: Some(pattern.into()),
            parts: parts.into_iter().filter(week).collect(),
        },
        Err(e) => date_error(e),
    }
}
pub fn date_offset(current: Option<f64>, next: Option<f64>, value: i32) -> Option<String> {
    if !valid_date(current)
        || !valid_date(next)
        || !current
            .zip(next)
            .is_some_and(|(a, b)| value == 0 || if value > 0 { b > a } else { b < a })
    {
        Some("日期偏移无法计算，请调整 offset。".into())
    } else {
        None
    }
}
pub fn date_pattern(pattern: &str, values: &[String]) -> DatePlan {
    let parts = match pattern_parts(pattern) {
        Ok(p) => p,
        Err(e) => return date_error(e),
    };
    if !parts.iter().any(week) {
        return DatePlan {
            error: None,
            pattern: Some(pattern.into()),
            parts: vec![],
        };
    }
    let mut result = String::new();
    let mut literal = String::new();
    let mut index = 0;
    fn flush(out: &mut String, literal: &mut String) {
        if literal.is_empty() {
            return;
        }
        let escaped = literal.replace('\'', "''");
        if literal.chars().any(|c| c.is_ascii_alphabetic()) {
            out.push('\'');
            out.push_str(&escaped);
            out.push('\'');
        } else {
            out.push_str(&escaped);
        }
        literal.clear();
    }
    for p in parts {
        if let Some(s) = &p.literal {
            literal.push_str(s);
        } else if week(&p) {
            let Some(s) = values.get(index).filter(|s| !s.is_empty()) else {
                return date_error("本次日历周字段无法展开。");
            };
            literal.push_str(s);
            index += 1;
        } else {
            flush(&mut result, &mut literal);
            result.push_str(&p.symbol.unwrap().to_string().repeat(p.count));
        }
    }
    flush(&mut result, &mut literal);
    DatePlan {
        error: None,
        pattern: Some(result),
        parts: vec![],
    }
}
pub fn quoted(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Diagnostic display uses line feeds and extended-grapheme columns, like the native UI.
pub fn location(body: &str, location: usize) -> String {
    let units: Vec<u16> = body.encode_utf16().take(location).collect();
    let prefix = String::from_utf16_lossy(&units);
    let lines: Vec<_> = prefix.split('\n').collect();
    format!(
        "第 {} 行、第 {} 列",
        lines.len(),
        lines.last().unwrap_or(&"").graphemes(true).count() + 1
    )
}

pub fn ready(severities: &[String], missing_count: usize, needs_empty: bool) -> bool {
    !needs_empty && missing_count == 0 && !severities.iter().any(|s| s == "error")
}
