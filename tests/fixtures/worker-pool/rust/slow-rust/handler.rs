use serde_json::{json, Value};
use std::{thread, time::Duration};

pub fn handler(_event: Value) -> Value {
    thread::sleep(Duration::from_millis(200));
    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": json!({ "ok": true, "runtime": "rust" }).to_string()
    })
}

