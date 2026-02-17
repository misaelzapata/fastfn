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
- Public routes (default):
  - `/<name>`
  - `/<name>@<version>`
- Optional compatibility alias:
  - `/fn/<name>`
  - `/fn/<name>@<version>`
  - Hidden from OpenAPI by default (set `FN_OPENAPI_INCLUDE_FN_PATHS=1` to include them).

## Runtime support status

Implemented and runnable now:

- `python`
- `node`
- `php`
- `lua` (in-process)

Experimental (opt-in via `FN_RUNTIMES`):

- `rust`
- `go`

## Configurable function root

Function discovery is filesystem-based and the root is configurable.

Resolution order:

1. `FN_FUNCTIONS_ROOT` (if set)
2. `/app/srv/fn/functions` (container default)
3. `$PWD/srv/fn/functions` (local dev default)
4. `/srv/fn/functions`

## Source filenames

The runtime looks for a valid entrypoint file in the following order:

1. Explicit `entrypoint` in `fn.config.json` (e.g. `src/my_handler.py`).
2. `app.{py,js,ts,php,lua,rs,go}`
3. `handler.{py,js,ts,php,lua,rs,go}`
4. `main.{py,js,ts,php,lua,rs,go}`
5. `index.{py,js,ts,php,lua}`

## Directory layout (relative to `FN_FUNCTIONS_ROOT`)

```text
<FN_FUNCTIONS_ROOT>/
  python/<name>[/<version>]/main.py
  node/<name>[/<version>]/index.ts
  php/<name>[/<version>]/handler.php
  lua/<name>[/<version>]/handler.lua
  rust/<name>[/<version>]/src/main.rs
  go/<name>[/<version>]/app.go
```

Optional files by function/version:

- `fn.config.json`
- `fn.env.json`
- `requirements.txt` (Python)
- `package.json` (Node)
- `composer.json` (PHP)
- `cjson.safe` available in Lua runtime sandbox
- `Cargo.toml` (Rust)
- `go.mod`, `go.sum` (Go, optional)

## Minimal handler examples

All handlers consume `event` and return `{status, headers, body}`.

### Python

```python
import json

def handler(event):
    return {
        "status": 200,
        "body": json.dumps({"hello": "world"}),
    }
```

### Node

```js
exports.handler = async (event) => {
  return {
    status: 200,
    body: JSON.stringify({ hello: 'world' }),
  };
};
```

### Go

```go
package main

import "encoding/json"

func handler(event map[string]interface{}) map[string]interface{} {
    body, _ := json.Marshal(map[string]interface{}{"hello": "world"})
    return map[string]interface{}{
        "status": 200,
        "headers": map[string]interface{}{"Content-Type": "application/json"},
        "body": string(body),
    }
}
```

### Lua

```lua
local cjson = require("cjson.safe")

function handler(event)
  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({ hello = "world" }),
  }
end
```

## Function config (`fn.config.json`)

Main fields:

- `timeout_ms`: Maximum execution time.
- `max_concurrency`: Max simultaneous requests (semaphor).
- `max_body_bytes`: Request body limit.
- `entrypoint`: (Optional) Explicit file path to the handler script relative to function root.
- `keep_warm`: (Optional) Periodic ping settings to keep the function hot.
- `worker_pool`: (Optional) Advanced runtime worker pool settings.
- `response.include_debug_headers`: Whether to include `X-Fn-Runtime` headers.
- `invoke.routes`: (Optional) Public URLs for the function (array). Defaults to `/<name>` and `/<name>/*`.
- `invoke.allow_hosts`: (Optional) Host allowlist for those routes (array).
- `invoke.force-url`: (Optional) If `true`, this function is allowed to override an already-mapped URL.

Notes:
- By default, FastFN does not silently override an existing URL mapping.
- Use `invoke.force-url: true` only when you intentionally want this function to take a route from another function (for example during a migration).
- Version-scoped configs (for example `node/my-fn/v2/fn.config.json`) never take over an existing URL by themselves; use `FN_FORCE_URL=1` if you need a version route to win.
- Global override: set `FN_FORCE_URL=1` (or `fastfn dev --force-url`) to treat all config/policy routes as forced.

Example with advanced fields:

```json
{
  "group": "demos",
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 1048576,
  "entrypoint": "src/api.py",
  "invoke": {
    "handler": "main",
    "force-url": false,
    "routes": ["/my-api", "/my-api/*"],
    "allow_hosts": ["api.example.com"]
  },
  "keep_warm": {
    "enabled": true,
    "min_warm": 1,
    "ping_every_seconds": 60,
    "idle_ttl_seconds": 300
  },
  "worker_pool": {
    "enabled": true,
    "min_warm": 0,
    "max_workers": 5,
    "idle_ttl_seconds": 600,
    "queue_timeout_ms": 2000,
    "overflow_status": 429
  },
  "response": {
    "include_debug_headers": true
  }
}
```

### Keep Warm

The `keep_warm` configuration instructs the runtime scheduler to periodically verify the function is loaded and ready.

- `enabled`: Activate the keep-warm scheduler.
- `min_warm`: Minimum number of instances (not fully implemented in all runtimes, usually 1).
- `ping_every_seconds`: Interval between heartbeats.
- `idle_ttl_seconds`: How long allowed to remain idle before scale-down.

### Worker Pool

For runtimes with subprocess worker pools (Python and Node; PHP and Lua use runtime-native execution models), `worker_pool` configures the persistent subprocess pool.

- `enabled`: Use persistent workers instead of one-shot processes.
- `max_workers`: Maximum number of subprocesses to spawn.
- `idle_ttl_seconds`: How long a worker stays alive without requests.
- `queue_timeout_ms`: How long to wait for a worker to become available before returning `overflow_status` (default 500).

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

Then your handler can return `{ "proxy": { "path": "/foo" } }`.

## Schedule (cron or interval)

You can attach a schedule to a function using either:

- `every_seconds` (simple interval)
- `cron` (cron expression)

### Interval schedule (`every_seconds`)

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

### Cron schedule (`cron`)

Cron supports:

- 5 fields: `min hour dom mon dow`
- 6 fields: `sec min hour dom mon dow`
- macros: `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`

```json
{
  "schedule": {
    "enabled": true,
    "cron": "*/5 * * * *",
    "timezone": "UTC",
    "method": "GET",
    "query": {},
    "headers": {},
    "body": "",
    "context": {}
  }
}
```

Timezone values:

- `UTC`, `Z`
- `local` (default if omitted)
- fixed offsets like `+02:00` or `-05:00`

Notes:

- This runs inside OpenResty (worker 0) and calls your function through the same gateway/runtime policy as normal traffic.
- To run a function every **X minutes**, set `every_seconds = X * 60` (example: every 15 minutes => `900`).
- Scheduler state is visible at `GET /_fn/schedules` (`next`, `last`, `last_status`, `last_error`).
- Schedules are stored in `fn.config.json` (so schedule definitions persist across restarts).
- Scheduler state is persisted to `<FN_FUNCTIONS_ROOT>/.fastfn/scheduler-state.json` by default (so `last/next/status/error` survives restarts).
- Common failure modes (`last_status` / `last_error`):
  - `405`: schedule `method` not allowed by function policy.
  - `413`: schedule `body` exceeded `max_body_bytes`.
  - `429`: function was busy (concurrency gate).
  - `503`: runtime down/unhealthy.
- Retry/backoff (optional):
  - Set `schedule.retry=true` for defaults, or provide an object:
  - `max_attempts` (default `3`), `base_delay_seconds` (default `1`), `max_delay_seconds` (default `30`), `jitter` (default `0.2`).
  - Retries apply to status `0`, `429`, `503`, and `>=500`. The scheduler updates `last_error` with a `retrying ...` message.
- Console UI: `GET /console/scheduler` shows schedules + keep_warm (requires `FN_UI_ENABLED=1`).
- Global toggles:
  - `FN_SCHEDULER_ENABLED=0` disables the scheduler entirely.
  - `FN_SCHEDULER_INTERVAL` controls the scheduler tick loop (default `1` second).
  - `FN_SCHEDULER_PERSIST_ENABLED=0` disables scheduler state persistence.
  - `FN_SCHEDULER_PERSIST_INTERVAL` controls how often scheduler state is flushed (seconds).
  - `FN_SCHEDULER_STATE_PATH` overrides the state file path.

## Function env and secrets

- `fn.env.json`: values injected into `event.env`
- secret masking is defined per key in the same file with `is_secret`

Example:

```json
{
  "API_KEY": {"value": "secret-value", "is_secret": true},
  "PUBLIC_FLAG": {"value": "on", "is_secret": false}
}
```
