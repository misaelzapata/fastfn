use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let name = event["query"]["name"].as_str().unwrap_or("World");
    let body = json!({
        "greeting": format!("Hello, {}!", name),
        "runtime": "rust"
    });
    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": body.to_string()
    })
}
