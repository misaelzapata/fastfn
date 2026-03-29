use serde_json::{json, Value};

pub fn handler(_event: Value) -> Value {
    json!({
        "status": 200,
        "headers": {
            "Content-Type": "text/plain; charset=utf-8"
        },
        "body": "hello from rust runtime"
    })
}
