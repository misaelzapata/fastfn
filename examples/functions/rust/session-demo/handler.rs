use serde_json::{json, Value};

// Session & cookie demo — shows how to access event["session"] in Rust.
//
// Usage:
//   Send a request with Cookie header: session_id=abc123; theme=dark

pub fn handler(event: Value) -> Value {
    let session = &event["session"];
    let session_id = session["id"].as_str().unwrap_or("");
    let cookies = &session["cookies"];

    if session_id.is_empty() {
        return json!({
            "status": 401,
            "headers": {"Content-Type": "application/json"},
            "body": json!({
                "error": "No session cookie found",
                "hint": "Send Cookie: session_id=your-token"
            }).to_string()
        });
    }

    let theme = cookies["theme"].as_str().unwrap_or("light");

    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({
            "authenticated": true,
            "session_id": session_id,
            "theme": theme,
            "all_cookies": cookies
        }).to_string()
    })
}
