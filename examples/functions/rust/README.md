# Rust Examples

Rust handlers are compiled at invocation time by the rust-daemon.

## Run

Rust is not in the default native runtimes. Enable it with `FN_RUNTIMES`:

```bash
FN_RUNTIMES=rust fastfn dev examples/functions/rust
```

## Routes

| Route | Method | What it does |
|-------|--------|-------------|
| `/rust-profile` | GET | Simple profile endpoint |
| `/session-demo` | GET | Cookie/session inspection. Send `Cookie: session_id=abc123; theme=dark` |

## Handler contract

Rust handlers must be named `handler.rs` at the function directory root and export:

```rust
use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({"hello": "world"}).to_string()
    })
}
```

The daemon wraps and compiles this — do not use `fn main()` with stdin/stdout.
Discovery only recognizes `handler.rs` at the directory root (not `src/main.rs`).

## Test

```bash
curl -sS http://127.0.0.1:8080/rust-profile
curl -sS http://127.0.0.1:8080/session-demo                                    # 401
curl -sS -H 'Cookie: session_id=abc123; theme=dark' http://127.0.0.1:8080/session-demo  # 200
```
