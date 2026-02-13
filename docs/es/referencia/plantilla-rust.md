# Plantilla de handler Rust

El runtime Rust ya esta implementado. Usa esta plantilla para `app.rs` o `handler.rs`.

```rust title="rust-handler.rs"
use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let name = event
        .get("query")
        .and_then(|q| q.get("name"))
        .and_then(|n| n.as_str())
        .unwrap_or("mundo");

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": json!({ "runtime": "rust", "hello": name }).to_string()
    })
}
```
