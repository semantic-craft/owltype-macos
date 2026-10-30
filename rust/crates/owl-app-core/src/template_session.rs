//! Ephemeral template sessions. No platform callbacks or storage on the event path.
use crate::template_library::{automatic_index, AutomaticNode, Entry, Expansion};
use serde_json::{json, Value};

pub enum Session {
    Delivery(crate::host_delivery::Delivery),
    Runtime(Runtime),
    Binding { expected: Value, valid: bool },
    Invocation(Box<Invocation>),
    Index(Vec<AutomaticNode>),
    Recognizer { buffer: String, path: Vec<usize> },
}
impl Session {
    pub fn create(kind: &str, args: Value) -> Result<Self, String> {
        match kind {
            "delivery" => Ok(Self::Delivery(crate::host_delivery::Delivery::new(args))),
            "runtime" => Ok(Self::Runtime(Runtime::default())),
            "binding" => Ok(Self::Binding {
                expected: expected_binding(args),
                valid: true,
            }),
            "invocation" => Ok(Self::Invocation(Box::new(Invocation::new(args)?))),
            "index" => Ok(Self::Index(automatic_index(
                &serde_json::from_value::<Vec<Entry>>(args).map_err(|_| "invalid_request")?,
            )?)),
            "recognizer" => Ok(Self::Recognizer {
                buffer: String::new(),
                path: vec![0],
            }),
            _ => Err("invalid_request".into()),
        }
    }
    pub fn event(
        &mut self,
        event: &str,
        args: Value,
        index: Option<&Session>,
    ) -> Result<Value, String> {
        match self {
            Self::Delivery(delivery) => delivery.event(event, args),
            Self::Runtime(runtime) => runtime.event(event, args),
            Self::Binding { expected, valid } => {
                if event != "valid" {
                    *valid &= args == *expected;
                }
                Ok(json!(valid))
            }
            Self::Invocation(invocation) => invocation.event(event, args),
            Self::Index(nodes) => {
                if event == "empty" {
                    Ok(json!(nodes.len() == 1))
                } else {
                    Err("invalid_event".into())
                }
            }
            Self::Recognizer { buffer, path } => {
                if event == "buffer" {
                    return Ok(json!(buffer));
                }
                if event == "take" {
                    path.clear();
                    path.push(0);
                    return Ok(json!(std::mem::take(buffer)));
                }
                let Some(Self::Index(nodes)) = index else {
                    return Err("missing_index".into());
                };
                let input = args["input"].as_str().unwrap_or("");
                let text = args["text"].as_str().unwrap_or("");
                let restore = |buffer: &mut String, path: &mut Vec<usize>, consume: bool| {
                    path.clear();
                    path.push(0);
                    let text = std::mem::take(buffer);
                    json!({"kind":"restore","replay":text == ";","text":text,"consume":consume})
                };
                if buffer.is_empty() {
                    if args["canStart"] != true || input != "text" || text != ";" {
                        return Ok(json!({"kind":"pass"}));
                    }
                    let Some(next) = nodes[0].children.get("59") else {
                        return Ok(json!({"kind":"pass"}));
                    };
                    buffer.push(';');
                    path.push(*next);
                    return Ok(json!({"kind":"mark","text":buffer}));
                }
                let node = *path.last().unwrap_or(&0);
                // A changed snapshot cannot index an old recognition path.
                if node >= nodes.len() {
                    return Ok(restore(buffer, path, false));
                }
                match input {
                    "backspace" => {
                        buffer.pop();
                        path.pop();
                        Ok(json!({"kind":if buffer.is_empty(){"clear"}else{"mark"},"text":buffer}))
                    }
                    "escape" => Ok(restore(buffer, path, true)),
                    "interrupt" => Ok(restore(buffer, path, false)),
                    "text" => {
                        let delimiter = matches!(
                            text,
                            " " | "\t"
                                | "\n"
                                | ","
                                | "."
                                | "?"
                                | "!"
                                | ":"
                                | "，"
                                | "。"
                                | "？"
                                | "！"
                                | "："
                        );
                        let entry = if delimiter {
                            match nodes[node].entry.as_ref() {
                                Some(e) if e.expansion_mode != Expansion::Immediate => Some(e),
                                _ => return Ok(restore(buffer, path, false)),
                            }
                        } else {
                            let bytes = text.as_bytes();
                            if bytes.len() != 1
                                || (buffer == ";" && bytes[0] != b';')
                                || (buffer != ";"
                                    && !bytes[0].is_ascii_alphanumeric()
                                    && !matches!(bytes[0], b'_' | b'-'))
                            {
                                return Ok(restore(buffer, path, false));
                            }
                            let Some(next) = nodes[node].children.get(&bytes[0].to_string()) else {
                                buffer.push_str(text);
                                let mut result = restore(buffer, path, true);
                                result["replay"] = json!(false);
                                return Ok(result);
                            };
                            buffer.push_str(text);
                            path.push(*next);
                            nodes[*next]
                                .entry
                                .as_ref()
                                .filter(|e| e.expansion_mode == Expansion::Immediate)
                        };
                        if let Some(entry) = entry {
                            let trigger = std::mem::take(buffer);
                            path.clear();
                            path.push(0);
                            Ok(
                                json!({"kind":"invoke","entry":entry,"trigger":trigger,"delimiter":if delimiter {Some(text)} else {None}}),
                            )
                        } else {
                            Ok(json!({"kind":"mark","text":buffer}))
                        }
                    }
                    _ => Err("invalid_event".into()),
                }
            }
        }
    }
}

use crate::template::{self, Diagnostic, Evaluation, Parsed, TemporalFact};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

pub struct Invocation {
    parsed: Parsed,
    legacy: bool,
    body: String,
    trailing: String,
    preview: bool,
    context: Option<Value>,
    context_failed: bool,
    allow_empty: bool,
    started: bool,
    phase: String,
    dispatched: bool,
    result: Value,
    generation: u64,
    binding: Value,
    valid: bool,
    invalidated: bool,
}
impl Invocation {
    fn new(args: Value) -> Result<Self, String> {
        Ok(Self {
            parsed: serde_json::from_value(args["parsed"].clone())
                .map_err(|_| "invalid_request")?,
            legacy: args["legacy"] == true,
            body: args["body"].as_str().unwrap_or("").into(),
            trailing: args["trailing"].as_str().unwrap_or("").into(),
            preview: args["preview"] == true,
            context: None,
            context_failed: false,
            allow_empty: false,
            started: false,
            phase: "awaiting".into(),
            dispatched: false,
            result: Value::Null,
            generation: 0,
            binding: expected_binding(args["binding"].clone()),
            valid: true,
            invalidated: false,
        })
    }
    fn awaiting(&self) -> bool {
        self.phase == "awaiting" && self.valid
    }
    fn evaluate(&self, values: Value) -> Evaluation {
        if !self.awaiting() {
            return Evaluation {
                preview_text: self.result["text"]
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| self.body.clone() + &self.trailing),
                diagnostics: vec![Diagnostic {
                    severity: "error".into(),
                    range: Default::default(),
                    message: "本次调用已结束，请重新调用模板。".into(),
                }],
                missing_keys: vec![],
                needs_empty_clipboard_decision: false,
                cursor_offset: None,
            };
        }
        if self.context_failed {
            let mut diagnostics = self.parsed.diagnostics.clone();
            diagnostics.push(Diagnostic {
                severity: "error".into(),
                range: Default::default(),
                message: "模板数据超出处理范围或无法读取，请缩短内容后重试。".into(),
            });
            return Evaluation {
                preview_text: self.body.clone() + &self.trailing,
                diagnostics,
                missing_keys: vec![],
                needs_empty_clipboard_decision: false,
                cursor_offset: None,
            };
        }
        let values = self
            .parsed
            .parameters
            .iter()
            .filter_map(|p| {
                values[if self.legacy { &p.name } else { &p.key }]
                    .as_str()
                    .map(|v| (p.key.clone(), v.into()))
            })
            .collect();
        let context = self.context.as_ref().unwrap_or(&Value::Null);
        let temporal: BTreeMap<String, TemporalFact> =
            serde_json::from_value(context["temporal"].clone()).unwrap_or_default();
        let mut result = template::render(
            &self.parsed,
            &values,
            context["clipboard"].as_str().unwrap_or("notRequested"),
            context["clipboard_text"].as_str(),
            self.allow_empty,
            &temporal,
        );
        let ready = is_ready(&result);
        result.preview_text.push_str(&self.trailing);
        if ready
            && result
                .cursor_offset
                .is_some_and(|offset| !boundary(&result.preview_text, offset))
        {
            result.diagnostics.push(Diagnostic {
                severity: "error".into(),
                range: Default::default(),
                message: "光标位置与保留的分隔符组成同一字符，请调整模板。".into(),
            });
        }
        result
    }
    fn event(&mut self, event: &str, args: Value) -> Result<Value, String> {
        let accepted = match event {
            "awaiting" => return Ok(json!(self.awaiting())),
            "invalidated" => return Ok(json!(self.invalidated)),
            "fail" => {
                // A native fact that cannot cross the ABI is a visible evaluation error,
                // not cancellation. Keep presentation/cancellation available and never
                // recapture or silently truncate that context into a deliverable result.
                if self.awaiting() && self.context.is_none() {
                    self.context_failed = true;
                    true
                } else {
                    false
                }
            }
            "evaluate" => return Ok(json!(self.evaluate(args["values"].clone()))),
            "initial" => {
                return Ok(json!(self
                    .parsed
                    .parameters
                    .iter()
                    .filter_map(|p| self.parsed.initial_values.get(&p.key).map(|v| (
                        if self.legacy {
                            p.name.clone()
                        } else {
                            p.key.clone()
                        },
                        v.clone()
                    )))
                    .collect::<BTreeMap<_, _>>()))
            }
            "needs_context" => {
                return Ok(json!(
                    self.awaiting()
                        && !self.context_failed
                        && self.context.is_none()
                        && !self
                            .parsed
                            .diagnostics
                            .iter()
                            .any(|d| d.severity == "error")
                ))
            }
            "freeze" => {
                if self.awaiting() && self.context.is_none() {
                    self.context = Some(args);
                    true
                } else {
                    false
                }
            }
            "empty" => {
                if self.awaiting()
                    && self.context.as_ref().is_some_and(|c| {
                        matches!(c["clipboard"].as_str(), Some("empty" | "nonText"))
                            || (c["clipboard"] == "text" && c["clipboard_text"] == "")
                    })
                {
                    self.allow_empty = true;
                    true
                } else {
                    false
                }
            }
            "allow_empty" => return Ok(json!(self.allow_empty)),
            "start" => {
                if self.awaiting() && !self.started {
                    self.started = true;
                    true
                } else {
                    false
                }
            }
            "immediate" => {
                let result = self.evaluate(args["values"].clone());
                return Ok(json!(
                    !self.preview
                        && self.parsed.parameters.is_empty()
                        && result.diagnostics.is_empty()
                        && is_ready(&result)
                ));
            }
            "prepare" => {
                return Ok(json!(
                    self.awaiting()
                        && !self
                            .parsed
                            .diagnostics
                            .iter()
                            .any(|d| d.severity == "error")
                ))
            }
            "confirm" => {
                let evaluation = self.evaluate(args["values"].clone());
                if self.awaiting() && is_ready(&evaluation) {
                    self.phase = "delivering".into();
                    self.generation += 1;
                    self.result = json!({"text":evaluation.preview_text,"cursorOffset":evaluation.cursor_offset});
                    self.context = None;
                    true
                } else {
                    false
                }
            }
            "dispatch" => {
                if self.phase == "delivering" && self.valid && !self.dispatched {
                    self.dispatched = true;
                    true
                } else {
                    false
                }
            }
            "pending" => {
                return Ok(json!(
                    self.phase == "delivering" && self.valid && !self.dispatched
                ))
            }
            "complete" => {
                if self.phase == "delivering"
                    && args["generation"].as_u64() == Some(self.generation)
                    && self.valid
                {
                    self.phase = "completed".into();
                    true
                } else {
                    false
                }
            }
            "cancel" => {
                if self.phase == "awaiting" || (self.phase == "delivering" && !self.dispatched) {
                    self.phase = "cancelled".into();
                    self.generation += 1;
                    self.context = None;
                    true
                } else {
                    false
                }
            }
            "binding" => {
                self.valid &= args == self.binding;
                if !self.valid {
                    self.context = None;
                    if self.phase == "awaiting" || self.phase == "delivering" {
                        self.phase = "cancelled".into();
                        self.invalidated = true;
                        self.generation += 1;
                    }
                }
                return Ok(json!(self.valid));
            }
            "snapshot" => {
                return Ok(
                    json!({"phase":self.phase,"result":self.result,"generation":self.generation}),
                )
            }
            _ => return Err("invalid_event".into()),
        };
        Ok(json!(accepted))
    }
}
fn is_ready(e: &Evaluation) -> bool {
    template::ready(
        &e.diagnostics
            .iter()
            .map(|d| d.severity.clone())
            .collect::<Vec<_>>(),
        e.missing_keys.len(),
        e.needs_empty_clipboard_decision,
    )
}
fn boundary(text: &str, offset: usize) -> bool {
    let mut units = 0;
    if offset == 0 {
        return true;
    }
    for g in text.graphemes(true) {
        units += g.encode_utf16().count();
        if units == offset {
            return true;
        }
        if units > offset {
            return false;
        }
    }
    false
}

/// Pure admission/readback rules. Native callers supply facts without querying the host here.
pub fn rule(operation: &str, args: Value) -> Value {
    let range = |key: &str| -> Option<(u64, u64)> {
        let values = args[key].as_array()?;
        let start = values.first()?.as_u64()?;
        let len = values.get(1)?.as_u64()?;
        if start >= isize::MAX as u64
            || len >= isize::MAX as u64
            || start.checked_add(len)? > isize::MAX as u64
        {
            None
        } else {
            Some((start, len))
        }
    };
    match operation {
        "ax_fallback" => json!(
            args["selected"] == "deniedChromiumClient"
                && args["surrounding"] == "deniedChromiumClient"
        ),
        "committed_observe" => json!(
            args["allowed"] == true
                && args["axFallback"] == true
                && args["engineValid"] == true
                && args["input"] == ""
                && args["preedit"] == ""
        ),
        "committed_original" => json!(format!(
            "{}{}",
            args["trigger"].as_str().unwrap_or(""),
            args["delimiter"].as_str().unwrap_or("")
        )),
        "engine_idle" => json!(
            args["valid"] == true
                && args["input"] == ""
                && args["preedit"] == ""
                && args["candidates"] == 0
                && args["preview"] == ""
        ),
        "valid_range" => json!(range("range").is_some()),
        "can_start" => {
            let valid = range("selection").is_some_and(|(start, len)| {
                len == 0
                    && (start == 0
                        || args["preceding"].as_str().is_some_and(|s| {
                            s.encode_utf16().count() == 1
                                && s.chars().next().is_some_and(|c| {
                                    c.is_whitespace() || ",.?!:，。？！：".contains(c)
                                })
                        }))
            }) && (args["marked"][0].as_u64() == Some(isize::MAX as u64)
                || args["marked"][1] == 0);
            json!(valid)
        }
        "owns" => {
            let text = args["text"].as_str().unwrap_or("");
            let expected = args["start"]
                .as_u64()
                .map(|s| (s, text.encode_utf16().count() as u64));
            json!(
                expected.is_some()
                    && range("marked") == expected
                    && expected.is_some_and(
                        |(s, l)| range("selection") == s.checked_add(l).map(|end| (end, 0))
                    )
                    && args["substring"].as_str() == Some(text)
            )
        }
        "allows" => json!(
            args["enabled"] == true
                && args["empty"] == false
                && args["bundle"].as_str().is_some_and(|id| !id.is_empty()
                    && !args["disabled"].as_array().is_some_and(|a| a
                        .iter()
                        .any(|v| v.as_str() == Some(id.to_lowercase().as_str()))))
        ),
        "trailing" => json!(if args["mode"] == "delimiterKeep" {
            args["delimiter"].as_str().unwrap_or("")
        } else {
            ""
        }),
        "source" => {
            let trigger = args["trigger"].as_str().unwrap_or("");
            let delimiter = args["delimiter"].as_str();
            let marked = args["marked"].as_str().unwrap_or("");
            let expected = if args["mode"] == "immediate" {
                &trigger[..trigger.char_indices().next_back().map_or(0, |(i, _)| i)]
            } else {
                trigger
            };
            let start = args["start"].as_u64();
            let len = marked.encode_utf16().count() as u64;
            if args["pending"] == true
                || args["invocation"] != "automatic"
                || args["entryTrigger"].as_str() != Some(trigger)
                || !crate::template_library::automatic_valid(trigger)
                || marked != expected
                || (args["mode"] == "immediate") != delimiter.is_none()
                || !start.is_some_and(|s| {
                    s < isize::MAX as u64
                        && s.checked_add(len).is_some_and(|e| e <= isize::MAX as u64)
                })
            {
                return json!({"valid":false});
            }
            json!({"valid":true,"original":trigger.to_string()+delimiter.unwrap_or(""),"trailing":if args["mode"]=="delimiterKeep" {delimiter.unwrap_or("")}else{""}})
        }
        _ => Value::Null,
    }
}

#[derive(Default)]
pub struct Runtime {
    revision: u64,
    policy_revision: u64,
    enabled: bool,
    disabled: Vec<String>,
    entries: BTreeMap<String, Value>,
    versions: BTreeMap<String, u64>,
}
impl Runtime {
    fn event(&mut self, event: &str, args: Value) -> Result<Value, String> {
        match event {
            "publish" => {
                let entries: Vec<Entry> = serde_json::from_value(args["entries"].clone())
                    .map_err(|_| "invalid_request")?;
                let next: BTreeMap<String, Value> = entries
                    .into_iter()
                    .map(|e| (e.id.clone(), json!(e)))
                    .collect();
                self.revision = self.revision.wrapping_add(1);
                for id in self.entries.keys().chain(next.keys()) {
                    if self.entries.get(id) != next.get(id) {
                        self.versions.insert(id.clone(), self.revision);
                    }
                }
                self.entries = next;
                let enabled = args["enabled"] == true;
                let mut disabled = serde_json::from_value::<Vec<String>>(args["disabled"].clone())
                    .map_err(|_| "invalid_request")?
                    .into_iter()
                    .map(|s| s.to_lowercase())
                    .collect::<Vec<_>>();
                disabled.sort();
                disabled.dedup();
                if self.enabled != enabled || self.disabled != disabled {
                    self.policy_revision = self.policy_revision.wrapping_add(1);
                }
                self.enabled = enabled;
                self.disabled = disabled;
                Ok(json!(true))
            }
            "revision" => Ok(json!(self.revision)),
            "policy_revision" => Ok(json!(self.policy_revision)),
            "enabled" => Ok(json!(self.enabled)),
            "disabled" => Ok(json!(self.disabled)),
            "entry_binding" => {
                let id = args["id"].as_str().unwrap_or("").to_uppercase();
                let version = self.versions.get(&id).copied().unwrap_or(0);
                let selected = serde_json::from_value::<Entry>(args["entry"].clone())
                    .map_err(|_| "invalid_request")?;
                let matches = self
                    .entries
                    .get(&id)
                    .is_none_or(|entry| json!(selected) == *entry);
                // An unregistered synthetic/legacy value remains usable until this ID enters
                // the committed library. A deleted previously known entry never matches.
                let matches = matches && (version == 0 || self.entries.contains_key(&id));
                Ok(json!({"version":version.to_string(),"matches":matches.to_string()}))
            }
            _ => Err("invalid_event".into()),
        }
    }
}

fn expected_binding(mut facts: Value) -> Value {
    if let Some(map) = facts.as_object_mut() {
        if map.contains_key("matches") {
            map.insert("matches".into(), json!("true"));
        }
    }
    facts
}
