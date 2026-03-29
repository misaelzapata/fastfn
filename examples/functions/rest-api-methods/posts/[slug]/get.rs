use serde_json::{json, Value};

// GET /posts/:slug — slug merged into event from [slug] filename
pub fn handler(event: Value) -> Value {
    let slug = event["slug"].as_str().unwrap_or("");

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "slug": slug, "title": format!("Post: {}", slug), "content": "Lorem ipsum..."
        })).unwrap()
    })
}
