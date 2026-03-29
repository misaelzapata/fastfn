use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let name = event
        .get("query")
        .and_then(|q| q.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("world");

    let greeting = event
        .get("env")
        .and_then(|e| e.get("RUST_GREETING"))
        .and_then(|v| v.as_str())
        .unwrap_or("rust");

    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({
            "runtime": "rust",
            "function": "rust-profile",
            "hello": format!("{}-{}", greeting, name)
        }).to_string()
    })
}
