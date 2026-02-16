use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": json!({
            "message": "Hello from Rust!",
            "runtime": "rust"
        }).to_string()
    })
}
