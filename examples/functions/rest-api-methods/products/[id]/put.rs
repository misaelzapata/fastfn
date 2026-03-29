use serde_json::{json, Value};

// PUT /products/:id — id merged into event from [id] filename
pub fn handler(event: Value) -> Value {
    let id: i64 = event["id"].as_str().unwrap_or("0").parse().unwrap_or(0);

    let body_str = event["body"].as_str().unwrap_or("{}");
    let mut data: Value = match serde_json::from_str(body_str) {
        Ok(v) => v,
        Err(_) => {
            return json!({
                "status": 400,
                "body": r#"{"error":"Invalid JSON"}"#
            });
        }
    };

    data["id"] = json!(id);
    data["updated"] = json!(true);

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&data).unwrap()
    })
}
