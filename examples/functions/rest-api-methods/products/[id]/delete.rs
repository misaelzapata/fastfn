use serde_json::{json, Value};

// DELETE /products/:id — id merged into event from [id] filename
pub fn handler(event: Value) -> Value {
    let id: i64 = event["id"].as_str().unwrap_or("0").parse().unwrap_or(0);

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "id": id, "deleted": true
        })).unwrap()
    })
}
