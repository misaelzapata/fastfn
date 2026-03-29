use serde_json::{json, Value};

pub fn handler(_event: Value) -> Value {
    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({
            "ok": true,
            "runtime": "rust",
            "message": "Rust function with serde_json only"
        }).to_string()
    })
}
