//! Verification coordinates and routes. Search failure never asserts that a fact is false.
use crate::foundation_text::{is_whitespace_and_newline, trim, trim_spaces};
use regex::Regex;
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;
fn s<'a>(a: &'a Value, k: &str) -> &'a str {
    a[k].as_str().unwrap_or("")
}
fn strip(t: &str) -> &str {
    for w in [
        "依据", "根据", "参见", "按照", "依照", "适用", "载于", "见", "据", "依", "按", "载",
    ] {
        if let Some(rest) = t.strip_prefix(w) {
            return rest;
        }
    }
    t
}
fn normalize(t: &str) -> String {
    t.chars()
        .filter(|c| !is_whitespace_and_newline(*c))
        .collect()
}
fn query(t: &str) -> String {
    t.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .graphemes(true)
        .take(80)
        .collect()
}
fn encode(t: &str) -> String {
    let mut out = String::new();
    for b in t.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~!$'()*,;:@/?:".contains(&b) && !b"+&=?#".contains(&b)
        {
            out.push(b as char);
        } else {
            out += &format!("%{b:02X}");
        }
    }
    out
}
fn style(source: &str) -> Value {
    match source {
        "baiduScholar" => json!({"base":"https://xueshu.baidu.com/s","param":"wd"}),
        "cnki" => json!({"base":"https://kns.cnki.net/kns8s/defaultresult/index","param":"kw"}),
        "webSearch" => json!({"base":"https://www.baidu.com/s","param":"wd"}),
        "bing" => json!({"base":"https://www.bing.com/search","param":"q"}),
        "itslaw" => json!({"base":"https://www.itslaw.com/search","param":"searchWord"}),
        "wanfang" => json!({"base":"https://s.wanfangdata.com.cn/paper","param":"q"}),
        "vip" => json!({"base":"https://qikan.cqvip.com/Qikan/Search/Index","param":"key"}),
        "pkulaw" => json!({"domain":"pkulaw.com"}),
        "govLaw" => json!({"domain":"flk.npc.gov.cn"}),
        "rmfyalk" => json!({"domain":"rmfyalk.court.gov.cn"}),
        "wenshu" => json!({"domain":"wenshu.court.gov.cn"}),
        _ => json!({}),
    }
}
fn route(q: &str, source: &str) -> Value {
    let st = style(source);
    let url = if let Some(base) = st["base"].as_str() {
        Some(format!("{base}?{}={}", s(&st, "param"), encode(q)))
    } else {
        st["domain"].as_str().map(|d| {
            format!(
                "https://www.bing.com/search?q={}",
                encode(&format!("site:{d} {q}"))
            )
        })
    };
    json!({"kind":if source=="qwenSearch"{"modelSearch"}else if source=="manual"{"copyOnly"}else{"deepLink"},"source":source,"query":q,"url":url})
}
fn anchors(t: &str) -> Value {
    let rules: Value = serde_json::from_str(include_str!("verification_rules.json")).unwrap();
    let mut seen = std::collections::HashSet::new();
    let mut out = vec![];
    for r in rules.as_array().unwrap() {
        for m in Regex::new(s(r, "pattern")).unwrap().find_iter(t) {
            let n = normalize(m.as_str());
            let label = if r["kind"] == "officialDocument" {
                strip(&n)
            } else {
                &n
            };
            if label.graphemes(true).count() < r["minLength"].as_u64().unwrap() as usize
                || !seen.insert(crate::template_library::nfc(label))
            {
                continue;
            }
            out.push(json!({"id":format!("{}:{label}",s(r,"kind")),"label":label,"kind":r["kind"],"status":"pending","query":label,"preferredSources":r["sources"]}));
        }
    }
    json!(out)
}
fn case_number(t: &str, year: i64) -> Value {
    let mut shapes = vec![];
    for c in Regex::new(r"入库编号(\d{4})-\d{2}-\d-\d{3}-\d{3}")
        .unwrap()
        .captures_iter(t)
    {
        if let Ok(y) = c[1].parse::<i64>() {
            shapes.push(
                json!({"raw":&c[0],"year":y,"courtCode":"","caseType":"caseLibrary","sequence":0}),
            );
        }
    }
    for (marker, kind) in [
        ("刑初", "criminalFirstInstance"),
        ("刑终", "criminalSecondInstance"),
        ("民初", "civilFirstInstance"),
        ("民终", "civilSecondInstance"),
        ("行初", "administrativeFirstInstance"),
        ("执", "execution"),
    ] {
        let pattern = format!(r"[（(](\d{{4}})[）)]([^（）()号]*?){marker}(\d+)号");
        for c in Regex::new(&pattern).unwrap().captures_iter(t) {
            if let (Ok(y), Ok(n)) = (c[1].parse::<i64>(), c[3].parse::<i64>()) {
                if !c[2].is_empty() {
                    shapes.push(json!({"raw":&c[0],"year":y,"courtCode":&c[2],"caseType":kind,"sequence":n}));
                }
            }
        }
    }
    if let Some(valid) = shapes
        .iter()
        .find(|s| (1900..=year).contains(&s["year"].as_i64().unwrap()))
    {
        return json!({"caseNumber":valid,"status":"complete"});
    }
    let status = if !shapes.is_empty() {
        "suspectedFabricated"
    } else if Regex::new(r"\p{Han}+\d+(刑初|刑终|民初|民终|行初|执)|入库编号\d")
        .unwrap()
        .is_match(t)
    {
        "partial"
    } else if Regex::new(r"[（(]\d{4}[）)][^\s。，、；：（）()]{1,18}号")
        .unwrap()
        .is_match(t)
    {
        "suspectedFabricated"
    } else {
        "missing"
    };
    json!({"caseNumber":null,"status":status})
}
fn escape(t: &str) -> String {
    trim(t).replace('\'', "''")
}
fn field(f: &str, q: &str) -> String {
    let q = trim(q);
    let op = match f {
        "SU" => "%=",
        "TI" | "AB" => "%",
        _ => "=",
    };
    let terms = q
        .split_whitespace()
        .map(escape)
        .filter(|x| !x.is_empty())
        .collect::<Vec<_>>();
    let val = if ["SU", "TI", "AB"].contains(&f) && terms.len() > 1 {
        terms
            .iter()
            .map(|t| format!("'{t}'"))
            .collect::<Vec<_>>()
            .join(" * ")
    } else {
        format!("'{}'", escape(q))
    };
    format!("{f} {op} {val}")
}
fn normalize_field(t: &str) -> String {
    let t = trim_spaces(t).to_uppercase();
    if ["SU", "TI", "AU", "AB", "KY", "DOI"].contains(&t.as_str()) {
        t
    } else {
        "SU".into()
    }
}
fn cnki(a: &Value) -> String {
    let q = trim(s(a, "query"));
    if q.is_empty() {
        return "".into();
    }
    let mut parts = vec![field(&normalize_field(s(a, "field")), q)];
    let au = trim(s(a, "author"));
    if !au.is_empty() {
        parts.push(format!("AU = '{}'", escape(au)));
    }
    let journals = s(a, "journal")
        .split('+')
        .map(escape)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>();
    if journals.len() == 1 {
        parts.push(format!("LY = '{}'", journals[0]));
    } else if journals.len() > 1 {
        parts.push(format!(
            "({})",
            journals
                .iter()
                .map(|s| format!("LY = '{s}'"))
                .collect::<Vec<_>>()
                .join(" OR ")
        ));
    }
    parts.join(" AND ")
}
fn display(source: &str) -> &str {
    match source {
        "govLaw" => "国家法规库",
        "pkulaw" => "北大法宝",
        "cnki" => "知网",
        "vip" => "维普",
        "wanfang" => "万方",
        "baiduScholar" => "百度学术",
        "itslaw" => "无讼",
        "wenshu" => "裁判文书网",
        "rmfyalk" => "人民法院案例库",
        "bing" => "必应",
        "webSearch" => "百度",
        _ => "",
    }
}
pub fn rule(name: &str, a: Value) -> Value {
    match name {
        "receiptPending" => json!(["idle", "notFound", "error"].contains(&s(&a, "kind"))),
        "caseDisposition" => json!(match s(&a, "status") {
            "complete" => "admit",
            "partial" => "attemptCompleteElseDiscard",
            _ => "discard",
        }),
        "receiptState" => resolved_state(&a),
        "admittedAnchors" => json!(anchors(s(&a, "text"))
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["kind"] != "caseLaw"
                || case_number(s(v, "label"), a["currentYear"].as_i64().unwrap_or(0))["status"]
                    == "complete")
            .collect::<Vec<_>>()),
        "normalizeAnchor" => json!(normalize(s(&a, "text"))),
        "stripLeadIn" => json!(strip(s(&a, "text"))),
        "anchors" => anchors(s(&a, "text")),
        "caseNumber" => case_number(s(&a, "text"), a["currentYear"].as_i64().unwrap_or(0)),
        "normalizeQuery" => json!(query(s(&a, "text"))),
        "defaultSource" => json!(match s(&a, "kind") {
            "caseLaw" => "pkulaw",
            "law" | "administrativeRule" | "standard" | "officialDocument" => "govLaw",
            _ => "baiduScholar",
        }),
        "searchStyle" => style(s(&a, "source")),
        "route" => route(s(&a, "query"), s(&a, "source")),
        "queryEncode" => json!(encode(s(&a, "text"))),
        "safeURL" => {
            let t = trim(s(&a, "text"));
            let safe = url::Url::parse(t).ok().filter(|u| {
                ["http", "https"].contains(&u.scheme())
                    && u.host_str().is_some_and(|h| !h.is_empty())
                    && u.username().is_empty()
                    && u.password().is_none()
                    && !t
                        .split_once("://")
                        .map(|(_, rest)| {
                            rest.split(['/', '?', '#'])
                                .next()
                                .unwrap_or("")
                                .contains('@')
                        })
                        .unwrap_or(false)
            });
            json!({"url":safe.map(|_|t)})
        }
        "pasteQuery" => {
            json!({"query":a["routes"].as_array().into_iter().flatten().find(|r|r["url"].as_str().is_some_and(|s|url::Url::parse(s).is_ok_and(|u|u.query().is_none_or(str::is_empty)))).map(|r|&r["query"])})
        }
        "cnki" => json!(cnki(&a["input"])),
        "cnkiNormalize" => json!(normalize_field(s(&a, "text"))),
        "verifyMenu" => {
            let fallback = query(s(&a, "text"));
            let mut out = vec![];
            for (title, kinds, sources) in [
                (
                    "法规",
                    vec!["law", "administrativeRule", "standard", "officialDocument"],
                    vec!["govLaw", "pkulaw"],
                ),
                (
                    "案例",
                    vec!["caseLaw"],
                    vec!["pkulaw", "itslaw", "wenshu", "rmfyalk"],
                ),
                (
                    "文献",
                    vec!["scholarlyArticle"],
                    vec!["cnki", "vip", "wanfang", "baiduScholar"],
                ),
                ("兜底", vec![], vec!["bing", "webSearch"]),
            ] {
                let q = a["anchors"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|v| kinds.contains(&s(v, "kind")))
                    .map(|v| {
                        let q = trim(s(v, "query"));
                        if q.is_empty() {
                            s(v, "label")
                        } else {
                            q
                        }
                    })
                    .unwrap_or(&fallback);
                if q.is_empty() {
                    continue;
                }
                let mut items = vec![];
                for source in sources {
                    items.push(json!({"source":source,"title":if source=="cnki"{"知网·关键词"}else{display(source)},"route":route(q,source)}));
                    if source == "cnki" {
                        items.push(json!({"source":source,"title":"知网·专业检索式","route":{"kind":"deepLink","source":source,"query":cnki(&json!({"query":q,"field":"SU"})),"url":"https://kns.cnki.net/kns8s/AdvSearch"}}));
                    }
                }
                out.push(json!({"title":title,"items":items}));
            }
            json!(out)
        }
        _ => crate::ai_selection::rule(name, a),
    }
}

/// Receipt business state. Per-anchor generation rejects callbacks after cancel/manual fallback.
pub struct Receipt {
    anchors: Vec<Value>,
    text: String,
    available: bool,
    states: serde_json::Map<String, Value>,
    generations: std::collections::HashMap<String, u64>,
    completed: Value,
}
impl Receipt {
    pub fn new(a: Value) -> Self {
        Self {
            anchors: a["anchors"].as_array().cloned().unwrap_or_default(),
            text: s(&a, "text").into(),
            available: a["available"] == true,
            states: serde_json::Map::new(),
            generations: Default::default(),
            completed: Value::Null,
        }
    }
    fn state(&self, id: &str) -> Value {
        self.states
            .get(id)
            .cloned()
            .unwrap_or(json!({"kind":"idle"}))
    }
    fn snapshot(&self, accepted: bool, generation: u64) -> Value {
        let busy = self.states.values().any(|v| v["kind"] == "loading");
        let outcome = self
            .states
            .values()
            .any(|v| ["success", "confirmed", "notFound", "error"].contains(&s(v, "kind")));
        let verified = self
            .anchors
            .iter()
            .filter(|a| ["success", "confirmed"].contains(&s(&self.state(s(a, "id")), "kind")))
            .count();
        let suspected = self
            .anchors
            .iter()
            .filter(|a| a["kind"] == "law" && self.state(s(a, "id"))["kind"] == "notFound")
            .count();
        json!({"accepted":accepted,"generation":generation,"states":self.states,"busy":busy,"hasOutcome":outcome,"verifiedCount":verified,"pendingCount":self.anchors.len()-verified,"suspectedCount":suspected,"completedAt":self.completed})
    }
    pub fn event(&mut self, event: &str, a: Value) -> Result<Value, String> {
        let id = s(&a, "id");
        let mut accepted = true;
        let mut generation = *self.generations.get(id).unwrap_or(&0);
        match event {
            "eligible" => {
                return Ok(json!(self
                    .anchors
                    .iter()
                    .filter(|a| ["idle", "notFound", "error"]
                        .contains(&s(&self.state(s(a, "id")), "kind")))
                    .map(|a| a["id"].clone())
                    .collect::<Vec<_>>()))
            }
            "snapshot" => {}
            "begin" => {
                accepted = self.available && self.state(id)["kind"] != "loading";
                if accepted {
                    generation += 1;
                    self.generations.insert(id.into(), generation);
                    self.states.insert(id.into(), json!({"kind":"loading"}));
                }
            }
            "cancel" | "fallback" => {
                generation += 1;
                self.generations.insert(id.into(), generation);
                if event == "fallback" || self.state(id)["kind"] == "loading" {
                    self.states.insert(id.into(), json!({"kind":"idle"}));
                }
            }
            "confirm" => {
                let mut state = self.state(id);
                accepted = state["kind"] == "success";
                if accepted {
                    state["kind"] = json!("confirmed");
                    self.states.insert(id.into(), state);
                }
            }
            "complete" => {
                accepted = a["generation"].as_u64() == Some(generation)
                    && self.state(id)["kind"] == "loading";
                if accepted {
                    self.states.insert(id.into(), resolved_state(&a));
                    self.completed = a["time"].clone();
                }
            }
            "receipt" => return Ok(json!(self.receipt(s(&a, "timestamp")))),
            _ => return Err("invalid_event".into()),
        }
        Ok(self.snapshot(accepted, generation))
    }
    fn receipt(&self, timestamp: &str) -> String {
        let mut lines = vec![
            format!("法墨核验回执 · {timestamp}"),
            format!("引文：「{}」", query(&self.text)),
        ];
        for a in &self.anchors {
            let state = self.state(s(a, "id"));
            let verified = ["success", "confirmed"].contains(&s(&state, "kind"));
            let label = match s(a, "kind") {
                "law" => "法条",
                "caseLaw" => "案例",
                "administrativeRule" => "法规",
                "standard" => "标准",
                "scholarlyArticle" => "文献",
                "officialDocument" => "文件",
                "date" => "日期",
                "money" => "金额",
                _ => "其他",
            };
            let mut line = format!(
                "{} {}（{label}）",
                if verified { "[已核]" } else { "[待核]" },
                s(a, "label")
            );
            match s(&state, "kind") {
                "success" | "confirmed" => {
                    line += &format!(
                        "\n    来源：{} {}",
                        s(&state["source"], "title"),
                        s(&state["source"], "url")
                    )
                }
                "notFound" => {
                    line += if a["kind"] == "law" {
                        " — 疑似杜撰 · 待核（联网搜不到该条号）"
                    } else {
                        " — 未能通过联网核实（搜不到 ≠ 不存在）"
                    }
                }
                "error" => line += &format!(" — {}", s(&state, "message")),
                _ => {}
            }
            lines.push(line);
        }
        let v = self.snapshot(true, 0);
        lines.push(format!(
            "已核 {} · 待核 {} · 疑似杜撰 {}",
            v["verifiedCount"], v["pendingCount"], v["suspectedCount"]
        ));
        lines.join("\n")
    }
}
pub fn resolved_state(a: &Value) -> Value {
    if a["error"] == "empty" {
        return json!({"kind":"notFound"});
    }
    if a["error"] == "failure" {
        return json!({"kind":"error","message":a["message"]});
    }
    let Some(first) = a["sources"].as_array().and_then(|v| v.first()) else {
        return json!({"kind":"notFound"});
    };
    let title = if s(first, "title").is_empty() {
        s(first, "url")
    } else {
        s(first, "title")
    };
    let host = url::Url::parse(s(first, "url"))
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .unwrap_or("联网核验".into());
    let content = s(a, "content");
    let snippet = if content.is_empty() {
        Value::Null
    } else {
        json!(content.graphemes(true).take(200).collect::<String>())
    };
    json!({"kind":"success","source":{"title":title,"url":first["url"],"accessedAt":a["timestamp"],"provider":host,"snippet":snippet}})
}
