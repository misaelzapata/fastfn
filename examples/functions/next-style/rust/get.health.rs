use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({
            "route": "GET /rust/health",
            "runtime": "rust",
            "params": event.get("params").cloned().unwrap_or_else(|| json!({}))
        }).to_string()
    })
}
