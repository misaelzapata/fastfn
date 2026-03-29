use serde_json::{json, Value};

// GET /files/* — catch-all, path captures everything after /files/
pub fn handler(event: Value) -> Value {
    let path = event["path"].as_str().unwrap_or("");
    let segments: Vec<&str> = if path.is_empty() { vec![] } else { path.split('/').collect() };

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "path": path,
            "segments": segments,
            "depth": segments.len(),
        })).unwrap()
    })
}
