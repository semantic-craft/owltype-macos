//! Shared picker filtering/selection policy.
use crate::foundation_text::{localized_contains, trim_spaces};
use crate::storage::{decode, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    pub display: String,
    pub search_text: String,
}
#[derive(Serialize, Deserialize)]
pub struct Model {
    pub rows: Vec<Row>,
    pub query: String,
    pub selection: i64,
}
fn visible(m: &Model) -> Vec<Row> {
    let query = trim_spaces(&m.query);
    if query.is_empty() {
        return m.rows.clone();
    }
    m.rows
        .iter()
        .filter(|row| localized_contains(&row.search_text, query))
        .cloned()
        .collect()
}
pub fn dispatch(operation: &str, args: Value) -> Result<Value> {
    let mut m: Model = decode(args["model"].clone())?;
    if operation == "picker_visible" {
        return Ok(json!(visible(&m)));
    }
    if operation == "picker_selected" {
        let rows = visible(&m);
        return Ok(json!({"row":usize::try_from(m.selection).ok().and_then(|i|rows.get(i))}));
    }
    if operation == "picker_number" {
        let number = args["number"].as_i64().unwrap_or(0);
        let rows = visible(&m);
        return Ok(
            json!({"row":if (1..=9).contains(&number){rows.get((number-1)as usize)}else{None}}),
        );
    }
    match args["action"].as_str() {
        Some("query") => m.query = args["query"].as_str().unwrap_or("").into(),
        Some("select") => {
            let index = args["index"].as_i64().unwrap_or(-1);
            let count = visible(&m).len() as i64;
            if index >= 0 && index < count {
                m.selection = index
            }
            return Ok(json!(m));
        }
        Some("move") => {
            m.selection = m
                .selection
                .saturating_add(args["delta"].as_i64().unwrap_or(0))
        }
        _ => return Err("unknown_picker_action".into()),
    }
    let count = visible(&m).len() as i64;
    m.selection = if count > 0 {
        m.selection.clamp(0, count - 1)
    } else {
        -1
    };
    Ok(json!(m))
}
