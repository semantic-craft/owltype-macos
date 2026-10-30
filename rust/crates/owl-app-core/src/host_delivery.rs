//! Host delivery owns the two write slots, binding lifetime and UTF-16 cursor intent.
//! The native adapter supplies observations and executes effects; no platform callbacks here.
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;

type Range = [u64; 2];
fn range(v: &Value) -> Option<Range> {
    let r: Range = serde_json::from_value(v.clone()).ok()?;
    (r[0] < i64::MAX as u64 && r[1] < i64::MAX as u64 && r[0].checked_add(r[1])? < i64::MAX as u64)
        .then_some(r)
}
fn end(r: Range) -> Range {
    [r[0] + r[1], 0]
}
fn inserted(text: &str, base: u64) -> Option<Range> {
    range(&json!([base, text.encode_utf16().count()]))
}
fn boundary(text: &str, offset: u64) -> bool {
    let mut n = 0;
    if offset == 0 {
        return true;
    }
    for s in text.graphemes(true) {
        n += s.encode_utf16().count() as u64;
        if n == offset {
            return true;
        }
    }
    false
}
fn no_mark(f: &Value) -> bool {
    f["marked"][0].as_u64() == Some(i64::MAX as u64)
        || range(&f["marked"]).is_some_and(|r| r[1] == 0)
}
fn outcome(s: &str) -> Value {
    json!({"outcome":s})
}

#[derive(Default)]
pub struct Delivery {
    source: Option<Value>,
    invalid: bool,
    dispatched: bool,
    immediate: bool,
    preparation: Option<String>,
    committed: Option<Range>,
    presenting: bool,
    suspended: bool,
    result: Option<Value>,
    origin: Option<Range>,
    revision: u64,
    selection: Option<Range>,
    preparation_pending: bool,
    verify_pending: bool,
    move_pending: bool,
    effect_pending: Option<String>,
}
impl Delivery {
    pub fn new(args: Value) -> Self {
        let source = args.get("source").filter(|s| !s.is_null()).cloned();
        let committed = source
            .as_ref()
            .filter(|s| s["committed"] == true)
            .and_then(|s| range(&s["range"]));
        Self {
            source,
            committed,
            preparation: committed.map(|_| "ready".into()),
            immediate: true,
            ..Self::default()
        }
    }
    fn ready(&self, f: &Value) -> bool {
        !self.invalid && !self.dispatched && f["sourceValid"] == true && f["rejection"].is_null()
    }
    fn valid(&self, f: &Value) -> bool {
        !self.invalid && f["sourceValid"] == true && f["rejection"].is_null()
    }
    fn confirmed(&self, text: &str, r: Range, f: &Value) -> bool {
        self.valid(f)
            && f["ranges"] == true
            && f["text"].as_str() == Some(text)
            && range(&f["selection"]) == Some(end(r))
            && no_mark(f)
    }
    fn owns(&self, f: &Value) -> bool {
        let Some(s) = &self.source else {
            return false;
        };
        let Some(r) = range(&s["range"]) else {
            return false;
        };
        let text = s["marked"].as_str().unwrap_or("");
        self.ready(f)
            && f["ranges"] == true
            && !text.is_empty()
            && text.encode_utf16().count() as u64 == r[1]
            && range(&f["marked"]) == Some(r)
            && range(&f["selection"]) == Some(end(r))
            && f["text"] == s["marked"]
    }
    pub fn event(&mut self, event: &str, f: Value) -> Result<Value, String> {
        Ok(match event {
            "invalid" => json!(self.invalid),
            "dispatched" => json!(self.dispatched),
            "immediate" => json!(self.immediate),
            "end_immediate" => {
                self.immediate = false;
                json!(true)
            }
            "invalidate" => {
                self.invalid = true;
                self.presenting = false;
                self.suspended = false;
                json!(true)
            }
            "ready" => json!(self.ready(&f)),
            "restore" => json!(
                self.source.is_none()
                    || (!self.invalid && f["sourceValid"] == true && f["canRestore"] == true)
            ),
            "presentation" => {
                let allowed = self.source.is_some()
                    && self.preparation.as_deref() == Some("ready")
                    && !self.invalid;
                if allowed {
                    self.presenting = f["active"] == true;
                }
                json!(allowed)
            }
            "application" => {
                if f["original"] != true && f["presentation"] != true {
                    self.invalid = true;
                }
                json!(true)
            }
            "deactivate" => {
                self.suspended = self.preparation.as_deref() == Some("ready")
                    && !self.invalid
                    && f["canRestore"] == true
                    && (self.presenting || f["presentationFocused"] == true);
                if !self.suspended {
                    self.invalid = true;
                }
                json!(true)
            }
            "activate" => {
                if !self.suspended
                    || f["sourceValid"] != true
                    || (!f["rejection"].is_null() && f["rejection"] != "unverifiableTarget")
                {
                    self.invalid = true;
                }
                self.suspended = false;
                json!(true)
            }
            "read_range" => {
                if let Some(r) = self.committed {
                    json!(r)
                } else if let Some(s) = &self.source {
                    s["range"].clone()
                } else {
                    f["marked"].clone()
                }
            }
            "prepare" => {
                if self.source.is_none() {
                    return Ok(outcome("ready"));
                }
                if let Some(p) = &self.preparation {
                    return Ok(outcome(p));
                }
                if !self.owns(&f) {
                    self.invalid = true;
                    self.preparation = Some("originalNotPreserved".into());
                    outcome("originalNotPreserved")
                } else {
                    self.preparation = Some("originalAttemptedUnverified".into());
                    self.preparation_pending = true;
                    self.effect_pending = Some("original".into());
                    self.revision = f["revision"].as_u64().unwrap_or(0);
                    let s = self.source.as_ref().unwrap();
                    json!({"text":s["original"],"origin":s["range"]})
                }
            }
            "prepared" => {
                if !self.preparation_pending {
                    return Ok(json!({"ignored":true}));
                }
                self.preparation_pending = false;
                let s = self.source.as_ref().ok_or("invalid_event")?;
                let text = s["original"].as_str().unwrap_or("");
                let r = range(&s["range"]).and_then(|r| inserted(text, r[0]));
                if self.ready(&f)
                    && f["revision"].as_u64() == Some(self.revision)
                    && r.is_some_and(|r| self.confirmed(text, r, &f))
                {
                    self.committed = r;
                    self.preparation = Some("ready".into());
                    outcome("ready")
                } else {
                    self.invalid = true;
                    outcome("originalAttemptedUnverified")
                }
            }
            "result_begin" => {
                if self.dispatched {
                    json!(false)
                } else {
                    self.result = Some(json!({"text":"", "cursorOffset":f["cursorOffset"]}));
                    json!(true)
                }
            }
            "result_chunk" => {
                if self.dispatched {
                    json!(false)
                } else {
                    let result = self.result.as_mut().ok_or("invalid_event")?;
                    let Value::String(text) = &mut result["text"] else {
                        return Err("invalid_event".into());
                    };
                    text.push_str(f["text"].as_str().ok_or("invalid_request")?);
                    json!(true)
                }
            }
            "plan" => {
                if !self.ready(&f) {
                    return Ok(outcome(if self.dispatched {
                        "targetChanged"
                    } else {
                        f["rejection"].as_str().unwrap_or("targetChanged")
                    }));
                }
                let result = self.result.clone().ok_or("invalid_event")?;
                let mut replacement = None;
                let origin = if let Some(s) = &self.source {
                    if let Some(r) = self.committed {
                        if f["replace"] != true
                            || !self.confirmed(s["original"].as_str().unwrap_or(""), r, &f)
                        {
                            return Ok(outcome("targetChanged"));
                        }
                        replacement = Some(r);
                        Some(r)
                    } else {
                        if !self.owns(&f) {
                            return Ok(outcome("targetChanged"));
                        }
                        range(&s["range"])
                    }
                } else if !result["cursorOffset"].is_null() && f["ranges"] == true {
                    let selection = range(&f["selection"]);
                    if no_mark(&f) {
                        selection
                    } else {
                        range(&f["marked"]).filter(|r| {
                            selection.is_some_and(|s| s[0] >= r[0] && s[0] + s[1] <= r[0] + r[1])
                                && f["text"]
                                    .as_str()
                                    .is_some_and(|t| t.encode_utf16().count() as u64 == r[1])
                        })
                    }
                } else {
                    None
                };
                self.dispatched = true;
                self.effect_pending = Some("result".into());
                self.verify_pending = origin.is_some();
                self.origin = origin;
                self.revision = f["revision"].as_u64().unwrap_or(0);
                self.result = Some(result.clone());
                json!({"origin":origin,"replacement":replacement})
            }
            "verify" => {
                if !self.verify_pending {
                    return Ok(json!({"ignored":true}));
                }
                self.verify_pending = false;
                let result = self.result.as_ref().ok_or("invalid_event")?;
                let text = result["text"].as_str().unwrap_or("");
                let r = self.origin.and_then(|o| inserted(text, o[0]));
                if !r.is_some_and(|r| self.confirmed(text, r, &f)) {
                    outcome("attemptedUnverified")
                } else if result["cursorOffset"].is_null() {
                    outcome("confirmed")
                } else {
                    let offset = result["cursorOffset"].as_u64();
                    if !offset.is_some_and(|o| boundary(text, o)) {
                        outcome("positionUnverified")
                    } else {
                        let r = r.unwrap();
                        self.selection = range(&f["selection"]);
                        self.revision = f["revision"].as_u64().unwrap_or(0);
                        self.move_pending = true;
                        self.effect_pending = Some("cursor".into());
                        json!({"target":[r[0]+offset.unwrap(),0],"inserted":r})
                    }
                }
            }
            "admit" => {
                let kind = f["kind"].as_str().unwrap_or("");
                let pending = self.effect_pending.take();
                if pending.as_deref() == Some(kind)
                    && self.valid(&f)
                    && f["revision"].as_u64() == Some(self.revision)
                {
                    json!({})
                } else {
                    self.invalid = true;
                    match kind {
                        "original" => {
                            self.preparation_pending = false;
                            self.preparation = Some("originalNotPreserved".into());
                            outcome("originalNotPreserved")
                        }
                        "cursor" => {
                            self.move_pending = false;
                            outcome("positionUnverified")
                        }
                        _ => {
                            self.verify_pending = false;
                            outcome(f["rejection"].as_str().unwrap_or("targetChanged"))
                        }
                    }
                }
            }
            "moved" => {
                if !self.move_pending {
                    return Ok(outcome("positionUnverified"));
                }
                self.move_pending = false;
                if !self.valid(&f) || f["revision"].as_u64() != Some(self.revision) {
                    outcome("positionUnverified")
                } else if f["moved"] == true && f["selection"] == f["target"] {
                    outcome("positioned")
                } else if range(&f["selection"]) == self.selection {
                    outcome("leftAtEnd")
                } else {
                    outcome("positionUnverified")
                }
            }
            _ => return Err("invalid_event".into()),
        })
    }
}

/// Focus restoration policy is separate from native application identity and timer callbacks.
/// Each poll consumes a token, so repeated or superseded callbacks cannot dispatch again.
#[derive(Default)]
pub struct Focus {
    capture_attempted: bool,
    active: bool,
    remaining: u32,
    token: u64,
}
impl Focus {
    pub fn event(&mut self, event: &str, facts: Value) -> Result<Value, String> {
        let effect = |action: &str, token: u64| json!({"action":action,"token":token});
        Ok(match event {
            "capture" => {
                self.capture_attempted = true;
                json!(true)
            }
            "drop" => {
                self.capture_attempted = false;
                json!(true)
            }
            "restore" => {
                self.capture_attempted = false;
                json!(facts["target"] == true)
            }
            "begin" => {
                let needed = self.capture_attempted;
                self.capture_attempted = false;
                self.token = self.token.wrapping_add(1);
                self.active = false;
                if facts["host"] != true || (needed && facts["target"] != true) {
                    effect("missing", self.token)
                } else if facts["pending"] != true {
                    effect("ignore", self.token)
                } else if facts["target"] != true {
                    effect("dispatch", self.token)
                } else {
                    self.active = true;
                    self.remaining = 40;
                    effect("restore", self.token)
                }
            }
            "poll" => {
                if !self.active || facts["token"].as_u64() != Some(self.token) {
                    return Ok(effect("ignore", self.token));
                }
                self.token = self.token.wrapping_add(1);
                if facts["pending"] != true {
                    self.active = false;
                    effect("ignore", self.token)
                } else if (facts["restored"] == true && facts["ready"] == true)
                    || self.remaining == 0
                {
                    self.active = false;
                    effect(
                        if facts["restored"] == true {
                            "dispatch"
                        } else {
                            "focusNotRestored"
                        },
                        self.token,
                    )
                } else {
                    self.remaining -= 1;
                    effect("wait", self.token)
                }
            }
            _ => return Err("invalid_event".into()),
        })
    }
}
