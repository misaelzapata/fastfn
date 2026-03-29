use serde_json::{json, Value};

pub fn params_from_event(event: &Value) -> Value {
    event.get("params").cloned().unwrap_or_else(|| json!({}))
}

pub fn json_response(route: &str, params: Value, extra: Value) -> Value {
    let mut body = json!({
        "route": route,
        "runtime": "rust",
        "helper": "rust/_shared.rs",
        "params": params,
    });

    if let (Some(body_obj), Some(extra_obj)) = (body.as_object_mut(), extra.as_object()) {
        for (key, value) in extra_obj {
            body_obj.insert(key.clone(), value.clone());
        }
    }

    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": body.to_string()
    })
}
