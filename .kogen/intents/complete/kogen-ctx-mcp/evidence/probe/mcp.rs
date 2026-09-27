use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::path::Path;
use std::process::Command;

const VERSIONS: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

pub fn serve(root: &Path) -> i32 {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { return 1 };
        if line.trim().is_empty() {
            continue;
        }
        if let Some(reply) = handle(root, &line) {
            if writeln!(out, "{reply}").and_then(|_| out.flush()).is_err() {
                return 1;
            }
        }
    }
    0
}

fn err(id: Value, code: i64, msg: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":msg}})
}

fn handle(root: &Path, line: &str) -> Option<Value> {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return Some(err(Value::Null, -32700, "Parse error"));
    };
    let Some(obj) = v.as_object() else {
        return Some(err(Value::Null, -32600, "Invalid Request"));
    };
    let id = obj.get("id").cloned();
    let Some(method) = obj.get("method").and_then(Value::as_str) else {
        return id.map(|id| err(id, -32600, "Invalid Request"));
    };
    let id = id?;
    let result = match method {
        "initialize" => {
            let asked = v
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            let p = if VERSIONS.contains(&asked) {
                asked
            } else {
                "2025-11-25"
            };
            json!({"protocolVersion":p,"capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"kogen-ctx","version":"0.1.0"}})
        }
        "ping" => json!({}),
        "tools/list" => json!({"tools":[
            {"name":"search","inputSchema":{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer"}}}},
            {"name":"symbols","inputSchema":{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer"}}}},
            {"name":"refs","inputSchema":{"type":"object","required":["target"],"properties":{"target":{"type":"string"},"limit":{"type":"integer"}}}},
            {"name":"map","inputSchema":{"type":"object","properties":{"tokens":{"type":"integer"},"focus":{"type":"array","items":{"type":"string"}}}}}]}),
        "tools/call" => {
            let name = v
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or("");
            if !["search", "symbols", "refs", "map"].contains(&name) {
                return Some(err(id, -32602, "Unknown tool"));
            }
            let args = v.pointer("/params/arguments").cloned().unwrap_or(json!({}));
            let (ok, text) = call(root, name, &args);
            json!({"content":[{"type":"text","text":text}],"isError":!ok})
        }
        _ => return Some(err(id, -32601, "Method not found")),
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

fn call(root: &Path, name: &str, args: &Value) -> (bool, String) {
    let mut argv = vec![name.to_string()];
    let key = match name {
        "search" | "symbols" => Some("query"),
        "refs" => Some("target"),
        _ => None,
    };
    if let Some(key) = key {
        if let Some(s) = args.get(key).and_then(Value::as_str) {
            argv.push(s.to_string());
        }
    }
    if let Some(n) = args.get("limit").and_then(Value::as_i64) {
        argv.extend(["--limit".to_string(), n.to_string()]);
    }
    if let Some(n) = args.get("tokens").and_then(Value::as_i64) {
        argv.extend(["--tokens".to_string(), n.to_string()]);
    }
    if let Some(fs) = args.get("focus").and_then(Value::as_array) {
        for f in fs.iter().filter_map(Value::as_str) {
            argv.extend(["--focus".to_string(), f.to_string()]);
        }
    }
    let exe = match std::env::current_exe() {
        Ok(e) => e,
        Err(e) => return (false, format!("kogen-ctx: {e}\n")),
    };
    match Command::new(exe)
        .args(&argv)
        .arg("--root")
        .arg(root)
        .output()
    {
        Ok(o) if o.status.success() => (true, String::from_utf8_lossy(&o.stdout).into_owned()),
        Ok(o) => (false, String::from_utf8_lossy(&o.stderr).into_owned()),
        Err(e) => (false, format!("kogen-ctx: {e}\n")),
    }
}
