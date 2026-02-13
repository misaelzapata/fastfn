# Architecture

## Design goals

The platform optimizes for three things at once:

1. fast local development
2. per-function operational control
3. low operational complexity

That is why it keeps OpenResty as the single HTTP edge and uses language runtimes over Unix sockets.

## Mental model

HTTP client -> OpenResty (`/fn/...`) -> runtime (`python`/`node`/`php`/`rust`) -> handler

In Docker, everything runs in one `openresty` service, including runtime processes.

## Filesystem discovery (configurable)

There is no static `routes.json`. Functions are discovered from a filesystem root.

The discovery root is configurable via `FN_FUNCTIONS_ROOT`.

Resolution order:

1. `FN_FUNCTIONS_ROOT`
2. `/app/srv/fn/functions`
3. `$PWD/srv/fn/functions`
4. `/srv/fn/functions`

Runtime list is also configurable:

- `FN_RUNTIMES` (CSV, e.g. `python,node,php,rust`)

Socket mapping is configurable:

- `FN_RUNTIME_SOCKETS` (JSON map runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base dir when map is not provided)

Legacy route precedence:

- If the same function name exists in multiple runtimes, `/fn/<name>` resolves to the first runtime in `FN_RUNTIMES`.
- If `FN_RUNTIMES` is not set, it uses alphabetical order of runtime folders.

## Per-function policy

`fn.config.json` can define:

- `invoke.methods`
- `timeout_ms`
- `max_concurrency`
- `max_body_bytes`

This avoids rigid global behavior and keeps control near each function owner.

## Uniform runtime contract

All runtimes share one protocol:

- request: `{ fn, version, event }`
- response: `{ status, headers, body }`

That keeps the gateway language-agnostic.

## Security model

Built-in controls include:

- path traversal protection
- symlink escape prevention for code/config writes
- secret masking (`fn.env.json` with `is_secret=true`) in the console
- console permissions via flags (`ui/api/write/local_only`)
- strict per-function filesystem sandbox enabled by default (`FN_STRICT_FS=1`)

## Known tradeoffs

- higher latency than pure embedded Lua for some workloads
- filesystem discovery requires folder structure discipline
- public auth is function-level by default (not centralized)

The tradeoff is intentional: strong local velocity plus practical control.
