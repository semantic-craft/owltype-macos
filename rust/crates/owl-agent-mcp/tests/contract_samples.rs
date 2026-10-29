//! Every file in `shared/contracts/agent-bridge/samples` decodes into the bridge types and encodes
//! back to the same JSON; every file in `samples/invalid` is rejected. Swift runs the same files in
//! `OwlAgentBridgeContractTests`.

use owl_agent_mcp::bridge::*;
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

fn contract_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../shared/contracts/agent-bridge")
}

fn samples(dir: &Path) -> Vec<(String, Value)> {
    let mut files: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    files
        .into_iter()
        .map(|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap_or_else(|e| panic!("{name}: {e}"));
            (name, value)
        })
        .collect()
}

/// `<method>.request[.variant].json`, `<method>.response[.variant].json` or `error.<code>.json`.
fn check(name: &str, value: &Value) -> Result<Value, String> {
    let parts: Vec<&str> = name.trim_end_matches(".json").split('.').collect();
    let text = value.to_string();
    if parts[0] == "error" {
        let response: Response = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let Response::Failure(failure) = &response else { return Err("not an error response".into()) };
        if parts.get(1) != Some(&failure.error.code.name()) {
            return Err(format!("file names {:?}, message carries {}", parts.get(1), failure.error.code.name()));
        }
        return Ok(serde_json::to_value(&response).unwrap());
    }
    let method = Method::parse(parts[0]).ok_or_else(|| format!("unknown method in file name {}", parts[0]))?;
    match parts.get(1) {
        Some(&"request") => {
            let request: Request = serde_json::from_str(&text).map_err(|e| e.to_string())?;
            let call = request.call().map_err(|e| format!("{e:?}"))?;
            if call.method() != method {
                return Err("method does not match file name".into());
            }
            Ok(serde_json::to_value(Request::new(request.id.clone(), &call)).unwrap())
        }
        Some(&"response") => {
            let response: Response = serde_json::from_str(&text).map_err(|e| e.to_string())?;
            let Response::Success(success) = response else { return Err("not a success response".into()) };
            let outcome = Outcome::decode(method, success.result.clone()).map_err(|e| e.to_string())?;
            Ok(serde_json::to_value(Response::Success(Success { result: outcome.to_value(), ..success })).unwrap())
        }
        other => Err(format!("file name kind {other:?}")),
    }
}

#[test]
fn valid_samples_round_trip() {
    let all = samples(&contract_dir().join("samples"));
    assert!(all.len() >= 30, "expected the full sample set, found {}", all.len());
    for (name, value) in all {
        let encoded = check(&name, &value).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(encoded, value, "{name} does not round-trip");
    }
}

#[test]
fn invalid_samples_are_rejected() {
    let all = samples(&contract_dir().join("samples/invalid"));
    assert!(!all.is_empty());
    for (name, value) in all {
        assert!(check(&name, &value).is_err(), "{name} was accepted");
    }
}

#[test]
fn samples_cover_every_method_outcome_and_error() {
    let names: BTreeSet<String> = samples(&contract_dir().join("samples")).into_iter().map(|(name, _)| name).collect();
    for method in Method::ALL {
        for kind in ["request", "response"] {
            let prefix = format!("{}.{kind}", method.as_str());
            assert!(names.iter().any(|name| name.starts_with(&prefix)), "no {prefix} sample");
        }
    }
    for code in ErrorCode::ALL {
        assert!(names.contains(&format!("error.{}.json", code.name())), "no sample for {}", code.name());
    }
    let mut statuses = BTreeSet::new();
    let mut reasons = BTreeSet::new();
    for (name, value) in samples(&contract_dir().join("samples")) {
        if name.starts_with("deliver_text.response") {
            let result: DeliverResult = serde_json::from_value(value["result"].clone()).unwrap();
            statuses.insert(result.status());
            if let DeliverResult::TargetChanged { reason, .. } = result {
                reasons.insert(reason);
            }
        }
    }
    assert_eq!(statuses, DeliverResult::STATUSES.into_iter().collect());
    assert_eq!(reasons, TargetChangedReason::ALL.into_iter().collect());
}

#[test]
fn schema_lists_match_the_types() {
    let schema: Value = serde_json::from_str(&fs::read_to_string(contract_dir().join("bridge.schema.json")).unwrap()).unwrap();
    assert_eq!(schema["contractVersion"], CONTRACT_VERSION);
    assert_eq!(schema["protocolVersion"], PROTOCOL_VERSION);
    let methods: Vec<&str> = Method::ALL.iter().map(|m| m.as_str()).collect();
    assert_eq!(schema["methods"], serde_json::json!(methods));
    assert_eq!(schema["$defs"]["request"]["properties"]["method"]["enum"], serde_json::json!(methods));
    for code in ErrorCode::ALL {
        assert_eq!(schema["errorCodes"][code.name()], code.code(), "{}", code.name());
    }
    assert_eq!(schema["errorCodes"].as_object().unwrap().len(), ErrorCode::ALL.len());
    assert_eq!(schema["deliverStatuses"], serde_json::json!(DeliverResult::STATUSES));
    let reasons: Vec<Value> = TargetChangedReason::ALL.iter().map(|r| serde_json::to_value(r).unwrap()).collect();
    assert_eq!(schema["targetChangedReasons"], Value::Array(reasons));
    let deliver = &schema["$defs"]["deliverParams"]["properties"];
    assert_eq!(deliver["text"]["maxLength"], MAX_DELIVER_CHARS);
    assert_eq!(deliver["timeoutMs"]["minimum"], *DELIVER_TIMEOUT_RANGE_MS.start());
    assert_eq!(deliver["timeoutMs"]["maximum"], *DELIVER_TIMEOUT_RANGE_MS.end());
    assert_eq!(deliver["timeoutMs"]["default"], DEFAULT_DELIVER_TIMEOUT_MS);
}
