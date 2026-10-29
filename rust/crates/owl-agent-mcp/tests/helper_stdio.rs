//! Runs the built `owltype-mcp` as an agent client would: MCP over its stdin/stdout, with a fake
//! OwlAgentBridge on a private socket that answers from the contract samples.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::mpsc;
use std::thread;

fn sample(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../shared/contracts/agent-bridge/samples").join(name);
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// A bridge that answers each method with its contract sample, reporting the requests it saw.
fn fake_bridge(directory: &Path) -> (PathBuf, mpsc::Receiver<Value>) {
    let socket = directory.join("bridge.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let stream = stream.unwrap();
            let mut writer = stream.try_clone().unwrap();
            for line in BufReader::new(stream).lines() {
                let request: Value = serde_json::from_str(&line.unwrap()).unwrap();
                let mut answer = match request["method"].as_str().unwrap() {
                    "hello" => sample("hello.response.json"),
                    "owltype_status" => sample("owltype_status.response.json"),
                    "templates_list" => sample("templates_list.response.json"),
                    "template_get" => sample("template_get.response.json"),
                    "template_render" => sample("template_render.response.json"),
                    "deliver_text" => sample("deliver_text.response.delivered.json"),
                    _ => sample("error.method_not_found.json"),
                };
                answer["id"] = request["id"].clone();
                sender.send(request).unwrap();
                writeln!(writer, "{answer}").unwrap();
            }
        }
    });
    (socket, receiver)
}

struct Helper {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl Helper {
    fn start(socket: &Path) -> Helper {
        let mut child = Command::new(env!("CARGO_BIN_EXE_owltype-mcp"))
            .env("OWLTYPE_AGENT_BRIDGE_SOCKET", socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let mut helper = Helper { child, stdin, stdout, next_id: 1 };
        let initialized = helper.request(
            "initialize",
            json!({ "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": { "name": "grok-build", "version": "0.9.3" } }),
        );
        assert_eq!(initialized["result"]["protocolVersion"], "2025-11-25");
        assert_eq!(initialized["result"]["serverInfo"]["name"], "owltype-mcp");
        helper.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        helper
    }

    fn send(&mut self, message: Value) {
        writeln!(self.stdin, "{message}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let mut line = String::new();
            assert!(self.stdout.read_line(&mut line).unwrap() > 0, "helper closed stdout");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                return message;
            }
        }
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn private_directory() -> tempfile::TempDir {
    // Under /tmp: the default temporary directory can exceed sun_path's 104 bytes.
    let directory = tempfile::Builder::new().prefix("owlmcp").tempdir_in("/tmp").unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    directory
}

#[test]
fn lists_and_calls_owltype_status_through_the_bridge() {
    let directory = private_directory();
    let (socket, seen) = fake_bridge(directory.path());
    let mut helper = Helper::start(&socket);

    let tools = helper.request("tools/list", json!({}));
    let names: Vec<&str> = tools["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(names, owl_agent_mcp::server::tool_names());
    assert!(names.contains(&"owltype_status"));

    let called = helper.request("tools/call", json!({ "name": "owltype_status", "arguments": {} }));
    assert_eq!(called["result"]["isError"], false);
    assert_eq!(called["result"]["structuredContent"], sample("owltype_status.response.json")["result"]);

    let hello = seen.recv().unwrap();
    assert_eq!(hello["method"], "hello");
    assert_eq!(hello["params"]["protocolVersion"], 1);
    assert_eq!(hello["params"]["helper"]["name"], "owltype-mcp");
    assert_eq!(hello["params"]["agentClient"], json!({ "name": "grok-build", "version": "0.9.3" }));
    assert_eq!(seen.recv().unwrap()["method"], "owltype_status");
}

#[test]
fn reports_owltype_offline_as_a_tool_error() {
    let directory = private_directory();
    let mut helper = Helper::start(&directory.path().join("bridge.sock"));
    let called = helper.request("tools/call", json!({ "name": "owltype_status", "arguments": {} }));
    assert_eq!(called["result"]["isError"], true);
    let text = called["result"]["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("not reachable"), "{text}");
}

#[test]
fn refuses_a_socket_in_a_shared_directory() {
    let directory = private_directory();
    let (socket, _seen) = fake_bridge(directory.path());
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut helper = Helper::start(&socket);
    let called = helper.request("tools/call", json!({ "name": "owltype_status", "arguments": {} }));
    assert_eq!(called["result"]["isError"], true);
    assert!(called["result"]["content"][0]["text"].as_str().unwrap().contains("not private"));
}

#[test]
fn rejects_arguments_and_unknown_tools() {
    let directory = private_directory();
    let mut helper = Helper::start(&directory.path().join("bridge.sock"));
    let extra = helper.request("tools/call", json!({ "name": "owltype_status", "arguments": { "x": 1 } }));
    assert_eq!(extra["result"]["isError"], true);
    let unknown = helper.request("tools/call", json!({ "name": "nope", "arguments": {} }));
    assert_eq!(unknown["result"]["isError"], true);
}

#[test]
fn prints_its_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_owltype-mcp")).arg("--version").output().unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8(output.stdout).unwrap().contains("bridge protocol 1"));
}

#[test]
fn template_tools_forward_their_arguments() {
    let directory = private_directory();
    let (socket, seen) = fake_bridge(directory.path());
    let mut helper = Helper::start(&socket);
    let id = "6F1C2E0A-2B7D-4C1E-9D3B-1A2B3C4D5E6F";

    let listed = helper.request("tools/call", json!({ "name": "templates_list", "arguments": {} }));
    assert_eq!(listed["result"]["structuredContent"], sample("templates_list.response.json")["result"]);
    let rendered = helper.request(
        "tools/call",
        json!({ "name": "template_render", "arguments": { "id": id, "arguments": { "n:议题": "发版" } } }),
    );
    assert_eq!(rendered["result"]["structuredContent"], sample("template_render.response.json")["result"]);
    let requests: Vec<Value> = seen.try_iter().filter(|request| request["method"] != "hello").collect();
    assert_eq!(requests[1]["params"], json!({ "id": id, "arguments": { "n:议题": "发版" } }));

    let missing = helper.request("tools/call", json!({ "name": "template_get", "arguments": {} }));
    assert_eq!(missing["result"]["isError"], true);
    let extra = helper.request("tools/call", json!({ "name": "template_get", "arguments": { "id": id, "body": "x" } }));
    assert_eq!(extra["result"]["isError"], true);
}

#[test]
fn deliver_text_forwards_the_request_and_checks_it_first() {
    let directory = private_directory();
    let (socket, seen) = fake_bridge(directory.path());
    let mut helper = Helper::start(&socket);
    let arguments = json!({ "requestId": "grok-2026-10-29-0001", "text": "今天的发版改到下午三点。", "timeoutMs": 120000 });
    let delivered = helper.request("tools/call", json!({ "name": "deliver_text", "arguments": arguments }));
    assert_eq!(delivered["result"]["structuredContent"]["status"], "delivered");
    let forwarded: Vec<Value> = seen.try_iter().filter(|request| request["method"] == "deliver_text").collect();
    assert_eq!(forwarded[0]["params"], arguments);

    for bad in [json!({ "requestId": "has space", "text": "x" }), json!({ "requestId": "a", "text": "" }),
                json!({ "requestId": "a", "text": "x", "timeoutMs": 1 })] {
        let refused = helper.request("tools/call", json!({ "name": "deliver_text", "arguments": bad }));
        assert_eq!(refused["result"]["isError"], true, "{bad}");
    }
    assert_eq!(seen.try_iter().filter(|request| request["method"] == "deliver_text").count(), 0);
}
