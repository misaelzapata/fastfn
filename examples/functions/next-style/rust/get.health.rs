#[path = "_shared.rs"]
mod _shared;

use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    _shared::json_response(
        "GET /rust/health",
        _shared::params_from_event(&event),
        json!({
            "status_text": "ok",
        }),
    )
}
