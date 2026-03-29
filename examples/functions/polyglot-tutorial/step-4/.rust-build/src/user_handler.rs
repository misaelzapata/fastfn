use serde_json::{json, Value};

pub fn handler(_event: Value) -> Value {
    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({
            "step": 4,
            "runtime": "rust",
            "status": "ready",
            "message": "Rust helper is warm."
        }).to_string()
    })
}
