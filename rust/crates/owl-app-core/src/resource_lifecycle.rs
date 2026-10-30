//! Observable lifecycle state. Native tasks, alerts and idle-session refresh execute
//! returned actions; they do not keep a parallel transaction or retry state.
use crate::storage::Result;
use serde_json::{json, Value};
#[derive(Default)]
pub struct Center {
    running: bool,
    prepared: Value,
    rollback: Value,
    failed: Option<String>,
    phase: String,
    version: Value,
    progress: f64,
    message: String,
    awaiting: bool,
}
impl Center {
    fn snapshot(&self, action: &str) -> Value {
        json!({"action":action,"phase":if self.phase.is_empty(){"notInstalled"}else{&self.phase},"version":self.version,"progress":self.progress,"message":self.message,"prepared":self.prepared,"rollback":self.rollback,"awaiting":self.awaiting})
    }
    fn begin(&mut self, operation: &str) -> Value {
        if self.running
            || match operation {
                "prepare" => !self.prepared.is_null(),
                "activate" => self.prepared.is_null(),
                "rollback" => self.rollback.is_null(),
                _ => true,
            }
        {
            return self.snapshot("");
        }
        self.running = true;
        self.failed = None;
        self.phase = match operation {
            "prepare" => "preparing",
            "activate" => "activating",
            _ => "rollingBack",
        }
        .into();
        self.progress = 0.;
        self.snapshot(operation)
    }
    pub fn event(&mut self, event: &str, a: Value) -> Result<Value> {
        match event {
            "can_refresh" => return Ok(json!(!self.running && self.prepared.is_null())),
            "prepare" | "activate" | "rollback" => return Ok(self.begin(event)),
            "retry" => {
                let op = self.failed.clone().unwrap_or_else(|| "prepare".into());
                return Ok(self.begin(&op));
            }
            "refreshed" => {
                if self.running || !self.prepared.is_null() {
                    return Ok(self.snapshot(""));
                }
                self.failed = None;
                if let Some(error) = a["error"].as_str() {
                    self.rollback = Value::Null;
                    self.phase = "failed".into();
                    self.message = format!("Rust 词库状态无法读取：{error}");
                } else if !a["state"].is_null() {
                    self.phase = "installed".into();
                    self.version = a["state"]["current"]["manifest"]["version"].clone();
                    self.rollback = a["state"]["previous"]["manifest"]["version"].clone();
                } else {
                    self.rollback = Value::Null;
                    self.phase = "notInstalled".into();
                }
            }
            "progress" => {
                if self.running {
                    self.phase = "preparing".into();
                    self.progress = a["fraction"].as_f64().unwrap_or(0.);
                }
            }
            "prepared" => {
                self.running = false;
                self.failed = None;
                self.prepared = a;
                self.version = self.prepared["resource"]["record"]["manifest"]["version"].clone();
                self.phase = "prepared".into();
            }
            "activated" | "rolledBack" => {
                self.running = false;
                self.failed = None;
                self.prepared = Value::Null;
                self.phase = "installed".into();
                self.version = a["current"]["manifest"]["version"].clone();
                self.rollback = a["previous"]["manifest"]["version"].clone();
                self.awaiting = true;
                return Ok(self.snapshot("refresh"));
            }
            "refresh_done" => self.awaiting = false,
            "failed" => {
                self.running = false;
                let op = a["operation"].as_str().unwrap_or("prepare");
                self.failed = Some(op.into());
                if op == "prepare" {
                    self.prepared = Value::Null;
                }
                let label = match op {
                    "activate" => "词库启用失败",
                    "rollback" => "词库回退失败",
                    _ => "词库准备失败",
                };
                self.phase = "failed".into();
                self.message = format!("{label}：{}", a["message"].as_str().unwrap_or(""));
            }
            "snapshot" => (),
            _ => return Err("invalid_event".into()),
        }
        Ok(self.snapshot(""))
    }
}
#[derive(Default)]
pub struct Models {
    status: serde_json::Map<String, Value>,
}
impl Models {
    pub fn event(&mut self, event: &str, a: Value) -> Result<Value> {
        match event {
            "update" => {
                let error = a["error"].as_str().filter(|s| !s.is_empty());
                self.status.insert(
                    a["kind"].as_str().ok_or("invalid_kind")?.into(),
                    json!({"state":a["state"],"error":error}),
                );
            }
            "reset" => self.status.clear(),
            "snapshot" => (),
            _ => return Err("invalid_event".into()),
        }
        Ok(json!(self.status))
    }
}
pub fn rule(rule: &str, a: Value) -> Value {
    match rule {
        "needs_prompt" => {
            json!(a["active"].is_null() || a["active"].as_i64() < a["bundled"].as_i64())
        }
        "launch" => json!(if a["needsFetch"] != true {
            "doNothing"
        } else if a["autoFetch"] == true {
            "fetchSilently"
        } else if a["promptShown"] == true {
            "doNothing"
        } else if a["onboardingDone"] == true {
            "armPrompt"
        } else {
            "deferToOnboarding"
        }),
        "managed_schema" => {
            let schema = a["schema"].as_str().unwrap_or("");
            json!(
                !schema.is_empty()
                    && a["destinations"]
                        .as_array()
                        .is_some_and(|d| d.contains(&json!(format!("{schema}.schema.yaml"))))
            )
        }
        _ => Value::Null,
    }
}
