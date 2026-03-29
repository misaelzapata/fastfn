// Session & cookie demo — shows how to access event["session"] in Rust.
//
// The wrapper calls: user_handler::handler(event: Value) -> Value
// event["session"]["id"]      — auto-detected session ID
// event["session"]["cookies"] — map of parsed cookie key/value pairs
// event["query"]["name"]      — query parameter
// event["method"]             — HTTP method

use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let method = event["method"].as_str().unwrap_or("GET");

    let session = &event["session"];
    let sid = session["id"].as_str().unwrap_or("none");
    let cookies = &session["cookies"];

    let name = event["query"]["name"].as_str().unwrap_or("Guest");

    // Demonstrate stderr capture
    eprintln!("[rust-session] session_id={} method={}", sid, method);

    let body = json!({
        "runtime": "rust",
        "session_id": sid,
        "name": name,
        "method": method,
        "cookies": cookies,
        "message": format!("Hello {}! (Rust runtime)", name),
    });

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": body.to_string(),
    })
}
