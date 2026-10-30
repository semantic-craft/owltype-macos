//! Shared picker filtering/selection policy; native collation facts preserve Foundation search.
use crate::storage::*;
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
fn visible<H: Host>(host: &mut H, m: &Model) -> Result<Vec<Row>> {
    let query = crate::foundation_text::trim_spaces(&m.query);
    if query.is_empty() {
        return Ok(m.rows.clone());
    }
    let mut rows = vec![];
    for row in &m.rows {
        let found: bool = decode(effect(
            host,
            "localized_contains",
            json!({"text":row.search_text,"query":query}),
        )?)?;
        if found {
            rows.push(row.clone())
        }
    }
    Ok(rows)
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    let mut m: Model = decode(args["model"].clone())?;
    if operation == "picker_visible" {
        return Ok(json!(visible(host, &m)?));
    }
    if operation == "picker_selected" {
        let rows = visible(host, &m)?;
        return Ok(json!({"row":usize::try_from(m.selection).ok().and_then(|i|rows.get(i))}));
    }
    if operation == "picker_number" {
        let number = args["number"].as_i64().unwrap_or(0);
        let rows = visible(host, &m)?;
        return Ok(
            json!({"row":if (1..=9).contains(&number){rows.get((number-1)as usize)}else{None}}),
        );
    }
    match args["action"].as_str() {
        Some("query") => m.query = args["query"].as_str().unwrap_or("").into(),
        Some("select") => {
            let index = args["index"].as_i64().unwrap_or(-1);
            let count = visible(host, &m)?.len() as i64;
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
    let count = visible(host, &m)?.len() as i64;
    m.selection = if count > 0 {
        m.selection.clamp(0, count - 1)
    } else {
        -1
    };
    Ok(json!(m))
}
