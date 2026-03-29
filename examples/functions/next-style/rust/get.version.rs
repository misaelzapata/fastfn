#[path = "_shared.rs"]
mod _shared;

use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    _shared::json_response(
        "GET /rust/version",
        _shared::params_from_event(&event),
        json!({
            "version": "v1",
        }),
    )
}
