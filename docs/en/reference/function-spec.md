# Function Specification

## Quick Start

The easiest way to conform to this spec is using the CLI:

```bash
fastfn init <name> --template <runtime>
```

This generates the correct folder structure and configuration file.

## Naming and routing

- Function name: `^[a-zA-Z0-9_-]+$`
- Version: `^[a-zA-Z0-9_.-]+$`
- Public routes:
  - `/fn/<name>`
  - `/fn/<name>@<version>`

## Runtime support status

Implemented and runnable now:

- `python`
- `node`
- `php`
- `rust`

## Configurable function root

Function discovery is filesystem-based and the root is configurable.

Resolution order:

1. `FN_FUNCTIONS_ROOT` (if set)
2. `/app/srv/fn/functions` (container default)
3. `$PWD/srv/fn/functions` (local dev default)
4. `/srv/fn/functions`

You can also control runtime discovery with:

- `FN_RUNTIMES` (CSV, e.g. `python,node,php,rust`)
- `FN_RUNTIME_SOCKETS` (JSON map runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base dir when socket map is not provided)

Runtime precedence for legacy routes:

- If the same function name exists in multiple runtimes, `/fn/<name>` picks the first runtime in `FN_RUNTIMES`.
- If `FN_RUNTIMES` is not set, it falls back to alphabetical order of runtime folders.

## Source filenames

Implemented runtime files:

- Python: `app.py` or `handler.py`
- Node: `app.js` or `handler.js`
- PHP: `app.php` or `handler.php`
- Rust: `app.rs` or `handler.rs`

## Directory layout (relative to `FN_FUNCTIONS_ROOT`)

```text
<FN_FUNCTIONS_ROOT>/
  python/<name>[/<version>]/app.py|handler.py
  node/<name>[/<version>]/app.js|handler.js
  php/<name>[/<version>]/app.php|handler.php
  rust/<name>[/<version>]/app.rs|handler.rs
```

Optional files by function/version:

- `fn.config.json`
- `fn.env.json`
- `requirements.txt` (Python)
- `package.json`, `package-lock.json` (Node)
- `composer.json`, `composer.lock` (PHP, optional)
- `Cargo.toml`, `Cargo.lock` (Rust, optional)

## Minimal handler examples (same contract)

All handlers consume `event` and return `{status, headers, body}`.

=== "Python"

    ```python
    import json

    def handler(event):
        name = (event.get("query") or {}).get("name", "world")
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"hello": name}),
        }
    ```

=== "Node"

    ```js
    exports.handler = async (event) => {
      const query = event.query || {};
      const name = query.name || 'world';
      return {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hello: name }),
      };
    };
    ```

=== "PHP"

    ```php
    <?php
    function handler($event) {
        $query = $event['query'] ?? [];
        $name = $query['name'] ?? 'world';

        return [
            'status' => 200,
            'headers' => ['Content-Type' => 'application/json'],
            'body' => json_encode(['hello' => $name]),
        ];
    }
    ```

=== "Rust"

    ```rust
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
            "body": json!({ "hello": name }).to_string()
        })
    }
    ```

## Function config (`fn.config.json`)

Main fields:

- `timeout_ms`
- `max_concurrency`
- `max_body_bytes`
- `group` (optional)
- `shared_deps` (optional)
- `edge` (optional edge passthrough config)
- `include_debug_headers`
- `schedule` (optional interval scheduler)
- `invoke.methods`
- `invoke.handler` (optional custom exported function name; default `handler`)
- `invoke.routes` (optional public endpoint mapping)
- `invoke.summary`
- `invoke.query`
- `invoke.body`

Example:

```json
{
  "group": "demos",
  "shared_deps": ["common_http"],
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 1048576,
  "include_debug_headers": false,
  "invoke": {
    "handler": "main",
    "methods": ["GET", "POST"],
    "routes": ["/api/my-function"],
    "summary": "My function",
    "query": {"name": "World"},
    "body": ""
  }
}
```

Notes:

- `invoke.handler` lets you use Lambda-style custom handler names (`main`, `run`, etc.).
- For Node and Python runtimes, the selected function must be exported/defined in the same file.
- `invoke.routes` is optional.
- If present, each route must be an absolute path (for example `/api/my-function`).
- Reserved prefixes are not allowed (`/fn`, `/_fn`, `/console`, `/docs`).
- Route conflicts return `409`.

## Edge passthrough config (`edge`)

If you want Cloudflare-Workers-style behavior (handler returns a `proxy` directive and the gateway performs the outbound request), enable it per function in `fn.config.json`:

```json
{
  "edge": {
    "base_url": "https://api.example.com",
    "allow_hosts": ["api.example.com"],
    "allow_private": false,
    "max_response_bytes": 1048576
  }
}
```

Then your handler can return `{ "proxy": { ... } }`. See the full response contract in: **Runtime Contract**.

## Shared dependency packs (`shared_deps`)

Sometimes you want multiple functions to reuse the same dependency install (for example: one `node_modules` for several Node functions, or one pip install directory for several Python functions).

`fastfn` supports opt-in shared dependency packs. In `fn.config.json`:

```json
{
  "shared_deps": ["qrcode_pack"]
}
```

Packs live under the function root, so they work with the default Docker volume mount:

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/<runtime>/<pack>/
```

Examples:

- Python pack: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/python/qrcode_pack/requirements.txt`
- Node pack: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/qrcode_pack/package.json`
- Node TypeScript pack (esbuild): `<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/ts_pack/package.json`

At runtime:

- Python installs into `<pack>/.deps` and adds it to `sys.path`
- Node installs into `<pack>/node_modules` and adds it to module resolution for that function invocation

This is not a kernel-level sandbox and does not provide full virtualenv/cargo isolation, but it is a practical way to deduplicate installs.

## Schedule (interval cron)

You can attach a simple interval schedule to a function:

```json
{
  "schedule": {
    "enabled": true,
    "every_seconds": 60,
    "method": "GET",
    "query": {},
    "headers": {},
    "body": "",
    "context": {}
  }
}
```

- The scheduler runs inside OpenResty (worker 0).
- It invokes the same runtime over unix socket.
- The gateway policy still applies (methods, body limit, concurrency, timeout).

## Function env and secrets

- `fn.env.json`: values injected into `event.env`
- secret masking is defined per key in the same file with `is_secret`

Example:

```json
{
  "API_KEY": {"value": "secret-value", "is_secret": true},
  "PUBLIC_FLAG": {"value": "on", "is_secret": false},
  "LEGACY_VALUE": "still-supported"
}
```
