# Rust Handler Template


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Rust runtime is implemented. Use this template for `app.rs` or `handler.rs`.

```rust title="rust-handler.rs"
use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let name = event
        .get("query")
        .and_then(|q| q.get("name"))
        .and_then(|n| n.as_str())
        .unwrap_or("world");

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": json!({ "runtime": "rust", "hello": name }).to_string()
    })
}
```

## Contract

Defines expected request/response shape, configuration fields, and behavioral guarantees.

## End-to-End Example

Use the examples in this page as canonical templates for implementation and testing.

## Edge Cases

- Missing configuration fallbacks
- Route conflicts and precedence
- Runtime-specific nuances

## See also

- [Function Specification](function-spec.md)
- [HTTP API Reference](http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
