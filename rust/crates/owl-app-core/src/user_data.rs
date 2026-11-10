//! User-owned pins and user-data transactions. Native adapters provide raw effects only.
use crate::storage::*;
use crate::template_library::nfc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Deserialize, Serialize)]
pub struct Pin {
    code: String,
    text: String,
    traditional: bool,
}
impl Pin {
    fn same(&self, other: &Self) -> bool {
        nfc(&self.code) == nfc(&other.code)
            && nfc(&self.text) == nfc(&other.text)
            && self.traditional == other.traditional
    }
}
pub struct Pins {
    words: Vec<Pin>,
    revision: u64,
}
impl Pins {
    pub fn new(args: Value) -> Self {
        Self {
            words: serde_json::from_value(args).unwrap_or_default(),
            revision: 0,
        }
    }
    pub fn event(&mut self, event: &str, args: Value) -> Result<Value> {
        let mut inserted = false;
        if event == "toggle" || event == "remove" {
            let pin: Pin = decode(args)?;
            let exists = self.words.iter().any(|p| p.same(&pin));
            self.words.retain(|p| !p.same(&pin));
            if event == "toggle" && !exists {
                self.words.insert(0, pin);
                inserted = true;
            }
            self.revision = self.revision.wrapping_add(1);
        } else if event != "snapshot" {
            return Err("invalid_event".into());
        }
        let engine = self
            .words
            .iter()
            .map(|p| format!("{}\t{}\t{}", p.code, u8::from(p.traditional), p.text))
            .collect::<Vec<_>>()
            .join("\n");
        Ok(
            json!({"words":self.words,"revision":self.revision,"engineValue":engine,"inserted":inserted}),
        )
    }
}
fn normalized(value: &str) -> String {
    let mut value = value.replace('ü', "v");
    for initial in ["j", "q", "x", "y"] {
        value = value.replace(&format!("{initial}v"), &format!("{initial}u"));
    }
    for initial in ["n", "l"] {
        value = value.replace(&format!("{initial}ue"), &format!("{initial}ve"));
    }
    value
}
pub fn rule(rule: &str, args: Value) -> Value {
    match rule {
        "pin_source_requests" => json!(args["engineValue"]
            .as_str()
            .unwrap_or("")
            .split('\n')
            .filter_map(|line| {
                let parts: Vec<_> = line.splitn(3, '\t').collect();
                (parts.len() == 3 && parts[1] == "1")
                    .then(|| json!({"code":parts[0],"text":parts[2]}))
            })
            .collect::<Vec<_>>()),
        "pin_sources" => json!(args["facts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|fact| {
                let source = fact["source"].as_str().unwrap_or("");
                !source.is_empty()
                    && nfc(fact["roundtrip"].as_str().unwrap_or(""))
                        == nfc(fact["text"].as_str().unwrap_or(""))
            })
            .map(|fact| json!({"code":fact["code"],"text":fact["text"],"source":fact["source"]}))
            .collect::<Vec<_>>()),
        "pin_target" => {
            let input = args["input"].as_str().unwrap_or("");
            let candidate = args["candidate"].as_str().unwrap_or("");
            let preedit = args["preedit"].as_str().unwrap_or("");
            let syllables: Vec<_> = preedit
                .split([' ', '\''])
                .filter(|s| !s.is_empty())
                .map(normalized)
                .collect();
            let valid = args["schema"] == "rime_ice"
                && args["selStart"] == 0
                && args["caret"].as_u64() == Some(input.len() as u64)
                && !input.is_empty()
                && input.bytes().all(|b| b.is_ascii_lowercase() || b == b'\'')
                && !candidate.is_empty()
                && candidate.chars().all(|c| {
                    (0x3400..=0x9fff).contains(&(c as u32))
                        || (0x20000..=0x2fa1f).contains(&(c as u32))
                })
                && syllables.len() == candidate.graphemes(true).count()
                && syllables.iter().all(|s| {
                    include_str!("pin_syllables.txt")
                        .split_whitespace()
                        .any(|v| v == s)
                })
                && syllables.join("") == normalized(&input.replace('\'', ""));
            json!({"word":valid.then(|| json!({"code":input,"text":candidate,"traditional":args["traditional"]}))})
        }
        _ => Value::Null,
    }
}

fn native<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    effect(host, &format!("user_native_{operation}"), args)
}
fn reset_items<H: Host>(host: &mut H) -> Result<Vec<String>> {
    let kind = native(host, "kind", json!({"name":"msime-user"}))?;
    if kind == "missing" {
        return Ok(vec![]);
    }
    if kind != "directory" {
        return Err("not_directory".into());
    }
    let names: Vec<String> = decode(native(host, "list", json!({"name":"msime-user"}))?)?;
    let mut items: Vec<_> = names
        .into_iter()
        .filter(|n| {
            n == "msime_user.db"
                || n.starts_with("msime_user.db-")
                || n.starts_with("msime_user.db.corrupt-")
        })
        .collect();
    items.sort();
    if native(host, "exists", json!({"name":"msime-user/dictionaries"}))? == true {
        items.push("dictionaries".into());
    }
    Ok(items)
}
fn reset_error(kind: &str, item: &str, reason: String, restoration: Option<Result<()>>) -> Value {
    let restored = restoration.as_ref().map(|r| r.is_ok());
    let restore_reason = restoration.and_then(|r| r.err());
    json!({"error":{"kind":kind,"item":item,"reason":reason,"restored":restored,"restoreReason":restore_reason}})
}
fn reset<H: Host>(host: &mut H, timestamp: &str) -> Result<Value> {
    let items = match reset_items(host) {
        Ok(v) => v,
        Err(e) => return Ok(reset_error("inspection", "msime-user", e, None)),
    };
    if items.is_empty() {
        return Ok(json!({"removedItems":[],"backupDir":null}));
    }
    let base = format!(".owl-backup/rust-userdict-reset-{timestamp}");
    let mut backup = base.clone();
    let mut suffix = 2;
    while native(host, "exists", json!({"name":backup}))? == true {
        backup = format!("{base}-{suffix}");
        suffix += 1;
    }
    let mut current = items[0].clone();
    let copied = (|| -> Result<()> {
        native(host, "mkdir", json!({"name":backup}))?;
        for item in &items {
            current = item.clone();
            native(
                host,
                "copy",
                json!({"source":format!("msime-user/{item}"),"destination":format!("{backup}/{item}")}),
            )?;
        }
        Ok(())
    })();
    if let Err(e) = copied {
        let _ = native(host, "remove", json!({"name":backup}));
        return Ok(reset_error("backup", &current, e, None));
    }
    for item in &items {
        let deleted = native(host, "checkpoint", json!({"name":item}))
            .and_then(|_| native(host, "remove", json!({"name":format!("msime-user/{item}")})));
        if let Err(e) = deleted {
            let restored = (|| -> Result<()> {
                native(host, "mkdir", json!({"name":"msime-user"}))?;
                for item in &items {
                    native(host, "remove", json!({"name":format!("msime-user/{item}")}))?;
                }
                for item in &items {
                    native(
                        host,
                        "copy",
                        json!({"source":format!("{backup}/{item}"),"destination":format!("msime-user/{item}")}),
                    )?;
                }
                Ok(())
            })();
            return Ok(reset_error("remove", item, e, Some(restored)));
        }
    }
    let path = native(host, "path", json!({"name":backup}))?;
    Ok(json!({"removedItems":items,"backupDir":path}))
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    match operation {
        "user_reset_items" => match reset_items(host) {
            Ok(items) => Ok(json!({"removedItems":items})),
            Err(e) => Ok(reset_error("inspection", "msime-user", e, None)),
        },
        "user_reset" => reset(host, args["timestamp"].as_str().unwrap_or("")),
        _ => Err("invalid_operation".into()),
    }
}
