use serde_json::{json, Value};

// GET /products — list all products
pub fn handler(_event: Value) -> Value {
    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "products": [
                { "id": 1, "name": "Widget", "price": 9.99 },
                { "id": 2, "name": "Gadget", "price": 24.99 }
            ],
            "total": 2
        })).unwrap()
    })
}
