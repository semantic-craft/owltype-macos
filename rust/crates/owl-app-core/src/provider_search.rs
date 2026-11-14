//! Search provider wire and grounding, shared by explicit Ask and source verification.
use crate::{foundation_text::trim, provider_wire::s};
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;
fn query(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .graphemes(true)
        .take(128)
        .collect()
}
fn parse(root: &Value, doubao: bool) -> Value {
    if !root.is_object() {
        return json!({"error":"malformed"});
    }
    if doubao {
        let err = &root["ResponseMetadata"]["Error"];
        if err.is_object() {
            return json!({"error":"service","code":err["Code"].as_str().map(str::to_owned).unwrap_or_else(||err.get("CodeN").map(|v|v.as_str().map(str::to_owned).unwrap_or_else(||v.to_string())).unwrap_or("unknown".into())),"message":s(err,"Message")});
        }
        if !root["Result"].is_object() {
            return json!({"error":"malformed"});
        }
        if let Some(code) = root["Result"]["ErrorCode"].as_i64().filter(|c| *c != 0) {
            return json!({"error":"service","code":code.to_string(),"message":s(&root["Result"],"ErrorMsg")});
        }
    } else if !root["results"].is_array()
        || root["results"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| !v.is_object())
    {
        return json!({"error":"malformed"});
    }
    let raw = if doubao {
        &root["Result"]["Documents"]
    } else {
        &root["results"]
    };
    let mut values = vec![];
    for r in raw
        .as_array()
        .filter(|rows| rows.iter().all(Value::is_object))
        .into_iter()
        .flatten()
    {
        let url = s(r, if doubao { "Url" } else { "url" });
        let url = if doubao {
            url
        } else {
            url.split('#').next().unwrap_or(url)
        };
        let title = s(r, if doubao { "Title" } else { "title" });
        if !url.starts_with("http") || title.is_empty() {
            continue;
        }
        let snippet = if doubao {
            r["Snippet"]
                .as_array()
                .filter(|rows| rows.iter().all(Value::is_object))
                .into_iter()
                .flatten()
                .filter(|p| s(p, "Type") == "text")
                .filter_map(|p| p["Text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            let summary = s(r, "summary");
            if summary.is_empty() {
                s(r, "snippet")
            } else {
                summary
            }
            .into()
        };
        let date = if doubao {
            s(&r["DocumentInfo"], "PublishTime").to_owned()
        } else {
            s(r, "date").graphemes(true).take(10).collect()
        };
        let host = if doubao {
            s(&r["HostInfo"], "Hostname")
        } else {
            s(r, "site_name")
        };
        values.push(json!({"url":url,"title":title,"snippet":trim(&snippet),"publishedAt":if date.is_empty(){None}else{Some(date)},"hostname":if host.is_empty(){None}else{Some(host)},"needsHost":!doubao&&host.is_empty()}));
    }
    json!({"values":values})
}
pub(crate) fn numbered(results: &[Value]) -> String {
    results
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let mut lines = vec![format!("[{}] {}", i + 1, s(r, "title"))];
            if let Some(host) = r["hostname"].as_str() {
                lines.push(format!("来源：{host}"));
            }
            if let Some(date) = r["publishedAt"].as_str() {
                lines.push(format!("发布时间：{date}"));
            }
            lines.push(format!("网址：{}", s(r, "url")));
            if !s(r, "snippet").is_empty() {
                lines.push(format!("摘要：{}", s(r, "snippet")));
            }
            lines.join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}
fn cited(results: &[Value], answer: &str) -> Vec<Value> {
    let re = regex::Regex::new(r"\[(\d{1,2})\]").expect("fixed regex");
    let mut seen = vec![];
    let mut values = vec![];
    for m in re.captures_iter(answer) {
        if let Ok(n) = m[1].parse::<usize>() {
            if n > 0 && n <= results.len() && !seen.contains(&n) {
                seen.push(n);
                values.push(results[n - 1].clone());
            }
        }
    }
    values
}
pub fn rule(op: &str, a: &Value) -> Value {
    let results = a["results"].as_array().cloned().unwrap_or_default();
    match op {
        "searchBody" => {
            let limit = a["limit"].as_i64().unwrap_or(1);
            if a["doubao"] == true {
                json!({"Query":trim(s(a,"query")).graphemes(true).take(100).collect::<String>(),"DocCount":limit.clamp(1,20),"MaxSnippetLength":800,"MaxImageCountPerDoc":1})
            } else {
                let q = query(s(a, "query"));
                json!({"query":q,"ori_question":q,"count":limit.clamp(1,50)})
            }
        }
        "searchParse" => {
            let mut bytes: Vec<u8> = serde_json::from_value(a["bytes"].clone()).unwrap_or_default();
            if a["doubao"] == true {
                for b in &mut bytes {
                    if *b < 0x20 {
                        *b = 0x20;
                    }
                }
            }
            let root = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            parse(&root, a["doubao"] == true)
        }
        "groundingPrompt" => {
            let header=format!("已为用户的最后一个问题联网检索（{}）。依据检索结果作答，涉及事实处用 [序号] 标注出处；优先采信一手官方来源；结果不足以回答时如实说明，不要凭记忆补来源或编造网址。",s(a,"day"));
            json!(if results.is_empty() {
                header + "\n\n检索结果：无（未检索到相关网页）。"
            } else {
                header + "\n\n检索结果：\n" + &numbered(&results)
            })
        }
        "footer" => {
            if results.is_empty() {
                return json!("");
            }
            let c = cited(&results, s(a, "answer"));
            let empty = c.is_empty();
            let listed = if empty {
                results.iter().take(3).cloned().collect()
            } else {
                c
            };
            let lines = listed
                .iter()
                .map(|r| {
                    format!(
                        "[{}] [{}]({})",
                        results.iter().position(|p| p == r).unwrap_or(0) + 1,
                        s(r, "title"),
                        s(r, "url")
                    )
                })
                .collect::<Vec<_>>()
                .join("\n");
            json!(format!(
                "\n\n{}\n{}",
                if empty {
                    "检索到的网页："
                } else {
                    "来源："
                },
                lines
            ))
        }
        _ => Value::Null,
    }
}
