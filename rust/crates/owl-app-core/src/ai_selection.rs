//! Selection-toolbox rules and effect lifecycles; native adapters execute AX, paste and UI.
use crate::foundation_text::trim;
use regex::Regex;
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;
fn s<'a>(a: &'a Value, k: &str) -> &'a str {
    a[k].as_str().unwrap_or("")
}
fn cjk(c: &str) -> bool {
    c.chars()
        .any(|c| matches!(c as u32,0x4e00..=0x9fff|0x3400..=0x4dbf|0xf900..=0xfaff|0x3040..=0x30ff))
}
fn script(c: &str) -> bool {
    static PATTERN: std::sync::LazyLock<Regex> =
        std::sync::LazyLock::new(|| Regex::new(r"[\p{Han}\p{Hiragana}\p{Katakana}]").unwrap());
    PATTERN.is_match(c)
}
fn numbers(c: &str) -> bool {
    c.chars().any(char::is_numeric)
}
fn fingerprint(t: &str) -> String {
    t.graphemes(true)
        .filter(|c| c.chars().any(char::is_alphanumeric))
        .collect()
}
fn preclean(t: &str) -> String {
    let t = t.replace("\r\n", "\n").replace('\r', "\n");
    let line = Regex::new("[ \\t　]+$").unwrap();
    let t = t
        .split('\n')
        .map(|s| line.replace_all(s, ""))
        .collect::<Vec<_>>()
        .join("\n");
    Regex::new("\n{3,}")
        .unwrap()
        .replace_all(&t, "\n\n")
        .into_owned()
}
fn ellipsis(t: &str) -> String {
    let mut t = t.to_string();
    for (p, r) in [
        (r"\.{3,}", "……"),
        ("。{3,}", "……"),
        ("…+", "……"),
        ("-{2,}", "——"),
        ("—+", "——"),
    ] {
        t = Regex::new(p).unwrap().replace_all(&t, r).into_owned();
    }
    t
}
fn quotes(t: &str) -> String {
    let cs = t.graphemes(true).collect::<Vec<_>>();
    let mut out = String::new();
    let (mut dbl, mut single) = (true, true);
    for (i, c) in cs.iter().enumerate() {
        match *c {
            "\"" => {
                out += if dbl { "“" } else { "”" };
                dbl = !dbl;
            }
            "「" => out += "“",
            "」" => out += "”",
            "『" => out += "‘",
            "』" => out += "’",
            "'" => {
                let ascii = |s: &str| s.len() == 1 && s.as_bytes()[0].is_ascii_alphabetic();
                if i > 0 && i + 1 < cs.len() && ascii(cs[i - 1]) && ascii(cs[i + 1]) {
                    out += "'";
                } else {
                    out += if single { "‘" } else { "’" };
                    single = !single;
                }
            }
            _ => out += c,
        }
    }
    out
}
fn width(t: &str) -> String {
    let cs = t.graphemes(true).collect::<Vec<_>>();
    let mut out = String::new();
    for (i, c) in cs.iter().enumerate() {
        let prev = if i > 0 { cs[i - 1] } else { "" };
        let next = cs.get(i + 1).copied().unwrap_or("");
        out += match *c {
            "," if cjk(prev) => "，",
            "." if cjk(prev) && !numbers(next) => "。",
            "!" if cjk(prev) => "！",
            "?" if cjk(prev) => "？",
            ":" if cjk(prev) => "：",
            ";" if cjk(prev) => "；",
            "(" if cjk(next) => "（",
            ")" if cjk(prev) => "）",
            _ => c,
        };
    }
    out
}
fn spaces(t: &str) -> String {
    let cs = t.graphemes(true).collect::<Vec<_>>();
    let mut out = String::new();
    let mut i = 0;
    let latin = |c: &str| c.len() == 1 && c.as_bytes()[0].is_ascii_alphabetic();
    let digit = |c: &str| c.len() == 1 && c.as_bytes()[0].is_ascii_digit();
    while i < cs.len() {
        if cs[i] == " " || cs[i] == "　" {
            let start = i;
            while i < cs.len() && (cs[i] == " " || cs[i] == "　") {
                i += 1;
            }
            let prev = if start > 0 { cs[start - 1] } else { "" };
            let next = cs.get(i).copied().unwrap_or("");
            if (script(prev) && (script(next) || digit(next))) || (digit(prev) && script(next)) {
            } else if (script(prev) && latin(next)) || (latin(prev) && script(next)) {
                out.push(' ');
            } else {
                out += &cs[start..i].concat();
            }
        } else {
            if i > 0 && ((script(cs[i - 1]) && latin(cs[i])) || (latin(cs[i - 1]) && script(cs[i])))
            {
                out.push(' ');
            }
            out += cs[i];
            i += 1;
        }
    }
    Regex::new("[ ]{2,}")
        .unwrap()
        .replace_all(&out, " ")
        .into_owned()
}
fn finalize(t: &str) -> String {
    spaces(&width(&quotes(&ellipsis(t))))
}
fn rewrite_copy(action: &str) -> Value {
    let (noun, progress, inserted, copied) = match action {
        "promptOptimize" => (
            "提示词优化",
            "正在优化提示词…",
            "已替换为优化后的提示词。",
            "已复制优化结果，⌘V 替换",
        ),
        "goalBrief" => (
            "任务书",
            "正在整理任务书…",
            "已替换为整理后的任务书。",
            "已复制任务书，⌘V 替换",
        ),
        "publishFormatting" => (
            "规范排版",
            "正在规范排版…",
            "已替换选中文本。",
            "已复制排版，⌘V 替换",
        ),
        _ => (
            "润色",
            "正在润色…",
            "已替换选中文本。",
            "已复制改写，⌘V 替换",
        ),
    };
    json!({"noun":noun,"progress":progress,"inserted":inserted,"copied":copied})
}
pub fn rule(name: &str, a: Value) -> Value {
    let t = s(&a, "text");
    match name {
        "preClean" => json!(preclean(t)),
        "formatResult" => {
            let original = s(&a, "original");
            let reflow = s(&a, "reflow");
            let output = if trim(reflow).is_empty() {
                String::new()
            } else {
                finalize(
                    if crate::template_library::nfc(&fingerprint(original))
                        == crate::template_library::nfc(&fingerprint(reflow))
                    {
                        reflow
                    } else {
                        original
                    },
                )
            };
            json!({"text":output,"empty":trim(&output).is_empty()})
        }
        "replacementAdmission" => json!(if trim(t).is_empty() {
            "未生成可替换文本。"
        } else if a["hasTarget"] != true {
            "无法定位原选区，请重新选择文字后再试。"
        } else {
            ""
        }),
        "enabledActions" => {
            let order = [
                "ask",
                "polish",
                "sourceVerification",
                "researchAssist",
                "publishFormatting",
                "translate",
                "promptOptimize",
                "goalBrief",
            ];
            json!(order
                .iter()
                .filter(|k| a["cloud"] == true && a["enabled"][**k] == true)
                .collect::<Vec<_>>())
        }
        "toolboxRoute" => {
            let action = s(&a, "action");
            json!({
                "effect": match action {
                    "translate" | "researchAssist" => "question",
                    "sourceVerification" => "verify",
                    "ask" => "none",
                    _ => "rewrite",
                },
                "prompt": match action {
                    "translate" => "translationQuestion",
                    "researchAssist" => "researchAssistQuestion",
                    _ => "",
                },
                "display": match action {
                    "translate" => "翻译",
                    "researchAssist" => "辅助检索",
                    _ => "",
                }
            })
        }
        "clarificationScaffold" => {
            let qs = a["questions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" / ");
            json!(if a["goal"] == true {
                format!("请把选中的需求描述整理成一份目标任务书，按目标七问分节：目的 Why、完成态 Done、证据 Proof、反作弊 Anti、边界 Bounds、取舍 Trade、未知 Unknown。能从草稿合理推断的补上并标注（推断），推断不出的写进〈未知〉待裁决，不要编造。补充信息——{qs}：")
            } else {
                format!("请把选中的草稿改写成结构化提示词：补齐意图（为谁做、产出用来干什么）、目标、边界约束、产出形态，并用成对 XML 标签按语义分区（有层级就嵌套），不要写分步骤的操作脚手架，也不要要求复述内部推理。补充信息——{qs}：")
            })
        }
        _ => json!({"error":"unknown_ai_rule"}),
    }
}
#[derive(Default)]
pub struct Gesture {
    phase: u8,
    time: f64,
}
impl Gesture {
    pub fn event(&mut self, event: &str, a: Value) -> Result<Value, String> {
        let now = a["time"].as_f64().unwrap_or(0.0);
        let mut fired = false;
        match event {
            "invalidate" => self.phase = 0,
            "flags" => match s(&a, "modifiers") {
                "option" => {
                    self.phase = if self.phase == 2 && now - self.time <= 0.45 {
                        3
                    } else {
                        1
                    };
                    self.time = now;
                }
                "empty" => {
                    if self.phase == 1 && now - self.time <= 0.5 {
                        self.phase = 2;
                        self.time = now;
                    } else {
                        fired = self.phase == 3 && now - self.time <= 0.5;
                        self.phase = 0;
                    }
                }
                _ => self.phase = 0,
            },
            _ => return Err("invalid_event".into()),
        }
        Ok(json!(fired))
    }
}
pub struct Rewrite {
    copy: Value,
    phase: String,
    text: String,
    task: Value,
    message: Value,
    generation: u64,
}
impl Rewrite {
    pub fn new(a: Value) -> Self {
        let copy = rewrite_copy(s(&a, "action"));
        Self {
            message: copy["progress"].clone(),
            copy,
            phase: "generate".into(),
            text: String::new(),
            task: Value::Null,
            generation: 1,
        }
    }
    pub fn event(&mut self, event: &str, a: Value) -> Result<Value, String> {
        if event == "cancel" {
            self.generation += 1;
            self.phase = "done".into();
            self.message = Value::Null;
        } else if event != "next" && a["generation"].as_u64() != Some(self.generation) {
            return Ok(self.snapshot(false));
        } else {
            match event {
                "next" => {}
                "generated" if self.phase == "generate" => {
                    self.message = Value::Null;
                    self.text = s(&a, "text").into();
                    self.task = a["task"].clone();
                    self.phase = match s(&a, "kind") {
                        "ready" => "confirm",
                        "clarification" => "clarify",
                        _ => {
                            self.message = json!("未生成改写");
                            "done"
                        }
                    }
                    .into();
                }
                "confirmed" if self.phase == "confirm" => {
                    self.phase = if a["confirmed"] == true {
                        "deliver"
                    } else {
                        self.message = json!("已取消替换。");
                        "done"
                    }
                    .into();
                }
                "delivered" if self.phase == "deliver" => {
                    self.message = match s(&a, "kind") {
                        "inserted" => self.copy["inserted"].clone(),
                        "copied" => self.copy["copied"].clone(),
                        _ => a["message"].clone(),
                    };
                    self.phase = "done".into();
                }
                "failure" => {
                    self.phase = "done".into();
                    self.message = a["message"].clone();
                }
                _ => return Ok(self.snapshot(false)),
            }
        }
        Ok(self.snapshot(true))
    }
    fn snapshot(&self, accepted: bool) -> Value {
        json!({"action":self.phase,"generation":self.generation,"accepted":accepted,"text":self.text,"task":self.task,"message":self.message,"noun":self.copy["noun"]})
    }
}
