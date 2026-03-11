use serde_json::{json, Value};

// POST /products — create a product
pub fn handler(event: Value) -> Value {
    let body_str = event["body"].as_str().unwrap_or("{}");
    let data: Value = match serde_json::from_str(body_str) {
        Ok(v) => v,
        Err(_) => {
            return json!({
                "status": 400,
                "body": r#"{"error":"Invalid JSON"}"#
            });
        }
    };

    let name = data["name"].as_str().unwrap_or("").trim().to_string();
    if name.is_empty() {
        return json!({
            "status": 400,
            "body": r#"{"error":"name is required"}"#
        });
    }

    let price = data["price"].as_f64().unwrap_or(0.0);
    json!({
        "status": 201,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "id": 42, "name": name, "price": price, "created": true
        })).unwrap()
    })
}
