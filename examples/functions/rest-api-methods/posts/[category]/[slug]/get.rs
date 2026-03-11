use serde_json::{json, Value};

// GET /posts/:category/:slug — both params merged into event
pub fn handler(event: Value) -> Value {
    let category = event["category"].as_str().unwrap_or("");
    let slug = event["slug"].as_str().unwrap_or("");

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "category": category,
            "slug": slug,
            "title": format!("{}/{}", category, slug),
            "url": format!("/posts/{}/{}", category, slug),
        })).unwrap()
    })
}
