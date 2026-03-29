use serde_json::{json, Value};
use std::io::{self, Read};

mod user_handler;

fn main() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        print!("{}", json!({"error": "failed to read stdin"}).to_string());
        return;
    }

    let req: Value = serde_json::from_str(&input).unwrap_or_else(|_| json!({}));
    let mut event = req.get("event").cloned().unwrap_or_else(|| json!({}));
    if let Some(params) = event.get("params").cloned() {
        if let (Some(event_map), Some(params_map)) = (event.as_object_mut(), params.as_object()) {
            for (k, v) in params_map {
                event_map.entry(k.clone()).or_insert(v.clone());
            }
        }
    }
    let out = user_handler::handler(event);
    print!("{}", out.to_string());
}
