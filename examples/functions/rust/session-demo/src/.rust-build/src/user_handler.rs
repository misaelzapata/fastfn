// Session & cookie demo — shows how to access event.session in Rust.
//
// Usage:
//   Send a request with Cookie header: session_id=abc123; theme=dark
//   The handler reads event.session.cookies, event.session.id, and prints debug info.
//
// event.session shape:
//   - id:      auto-detected from session_id / sessionid / sid cookies (or null)
//   - raw:     the full Cookie header string
//   - cookies: HashMap of parsed cookie key/value pairs

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();

    let payload: Value = serde_json::from_str(&input).unwrap_or(json!({}));
    let event = &payload["event"];
    let session = &event["session"];

    let session_id = session["id"].as_str().unwrap_or("");
    let cookies: HashMap<String, String> = session["cookies"]
        .as_object()
        .map(|m| {
            m.iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                .collect()
        })
        .unwrap_or_default();

    // Demonstrate stderr capture — this will appear in Quick Test > stderr
    eprintln!("[session-demo] session_id = {}", session_id);
    eprintln!("[session-demo] cookies = {:?}", cookies);

    if session_id.is_empty() {
        let body = json!({
            "error": "No session cookie found",
            "hint": "Send Cookie: session_id=your-token",
        });
        print_response(401, &body.to_string());
        return;
    }

    let theme = cookies.get("theme").map(|s| s.as_str()).unwrap_or("light");
    let body = json!({
        "authenticated": true,
        "session_id": session_id,
        "theme": theme,
        "all_cookies": cookies,
    });
    print_response(200, &body.to_string());
}

fn print_response(status: u16, body: &str) {
    let resp = json!({
        "status": status,
        "headers": { "Content-Type": "application/json" },
        "body": body,
    });
    println!("{}", resp);
}
