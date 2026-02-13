# 🚀 fastfn

[![CI](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg)](https://codecov.io/gh/misaelzapata/fastfn)
[![Docs](https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)
![OpenResty](https://img.shields.io/badge/OpenResty-1.27.1.2-orange)
![OpenAPI](https://img.shields.io/badge/OpenAPI-3.1-blue)
![Python](https://img.shields.io/badge/Python-3.x-3776AB)
![Node.js](https://img.shields.io/badge/Node.js-18%2B-339933)
![PHP](https://img.shields.io/badge/PHP-8.x-777BB4)
![Rust](https://img.shields.io/badge/Rust-stable-000000)

**fastfn** is a local-first function platform on top of OpenResty.

## Highlights

- File-based function discovery (no static routes file required)
- Per-function policies (`timeout_ms`, `max_concurrency`, `max_body_bytes`, methods)
- Optional endpoint mapping per function (`invoke.routes`)
- OpenAPI/Swagger generation from discovered functions
- Console API for CRUD/config/env/code updates
- Gateway dashboard in Console (mapped URL -> function + conflict visibility)
- Single env model: `fn.env.json` with optional `{ "value": "...", "is_secret": true }`
- Strict filesystem sandbox by default (`FN_STRICT_FS=1`)

## Quick start

```bash
docker compose up -d --build
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

If `curl` cannot connect but the container is up (and/or `wget` works), common causes are IPv6/proxy settings.

Try:

```bash
# force IPv4
curl -4 -sS 'http://127.0.0.1:8080/_fn/health'

# ignore proxy env vars (if you have them)
curl --noproxy '*' -sS 'http://127.0.0.1:8080/_fn/health'
```

If you're in a sandboxed environment that blocks host loopback connections, run the request from inside the container:

```bash
docker compose exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/_fn/health'"
```

Local (without Docker):

```bash
./scripts/start-python.sh
./scripts/start-node.sh
./scripts/start-php.sh
./scripts/start-rust.sh
./scripts/start-openresty.sh
```

Test a function:

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello?name=World'
```

Console deep link example:

- `http://127.0.0.1:8080/console/explorer/node/node_echo`
- `http://127.0.0.1:8080/console/gateway` (mapped routes dashboard)
- `http://127.0.0.1:8080/console/wizard` (step-by-step function creator)

Optional custom endpoint mapping in `fn.config.json`:

```json
{
  "invoke": {
    "handler": "main",
    "methods": ["GET"],
    "routes": ["/api/hello"]
  }
}
```

`invoke.handler` is optional (default is `handler`) and lets you use Lambda-style custom names like `main` or `run` (Node/Python runtimes).

## Function root is configurable

Discovery does not require a hardcoded `srv/fn/functions` path.

Resolution order:

1. `FN_FUNCTIONS_ROOT`
2. `/app/srv/fn/functions` (container default)
3. `$PWD/srv/fn/functions` (local default)
4. `/srv/fn/functions`

Useful env vars:

- `FN_FUNCTIONS_ROOT`
- `FN_RUNTIMES`
- `FN_RUNTIME_SOCKETS`
- `FN_SOCKET_BASE_DIR`
- `FN_PREINSTALL_PY_DEPS_ON_START` (`1` = preinstall Python deps on boot)
- `FN_PREINSTALL_NODE_DEPS_ON_START` (`1` = preinstall Node deps on boot)

Versioned Node URL example:

- `/fn/hello@v2`
- `/fn/qr@v2`

## Shared dependency packs (optional)

If multiple functions need the same dependencies, you can deduplicate installs with `shared_deps`.

Packs live under:

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/<runtime>/<pack>/
```

Then attach in `fn.config.json`:

```json
{
  "shared_deps": ["qrcode_pack"]
}
```

## Schedules (Cron, `every_seconds`)

fastfn includes a simple scheduler that can invoke a function on an interval, **without any extra HTTP server**.

Where it runs:
- Scheduler runs inside OpenResty (worker 0) and calls the function runtime over the same unix socket protocol as normal HTTP requests.

How to configure (per function):
- Add `schedule` to `fn.config.json` (in the function folder, or in a version folder).

Example: enable a tick every 1 second:

```json
{
  "schedule": {
    "enabled": true,
    "every_seconds": 1,
    "method": "GET",
    "query": { "action": "inc" },
    "headers": {},
    "body": "",
    "context": {}
  }
}
```

Scheduler status:
- `GET /_fn/schedules` (internal API; respects console guards)

Demo function included:
- `GET /fn/cron_tick?action=read`

## Runtime status

Implemented now:

- Python
- Node
- PHP
- Rust

Built-in runtime examples:

- `/fn/hello` (python)
- `/fn/hello@v2` (node)
- `/fn/qr` (python + requirements auto-install)
- `/fn/qr@v2` (node + npm auto-install)
- `/fn/php_profile` (php)
- `/fn/rust_profile` (rust)
- `/fn/gmail_send` (python, Gmail SMTP helper, dry-run default)
- `/fn/telegram_send` (node, Telegram Bot API helper, dry-run default)
- `/fn/edge_proxy` (node, edge passthrough demo)
- `/fn/edge_filter` (node, edge filter auth + rewrite demo)
- `/fn/edge_auth_gateway` (node, Bearer auth gateway + passthrough demo)
- `/fn/github_webhook_guard` (node, webhook signature verify demo)
- `/fn/edge_header_inject` (node, header injection + passthrough demo)
- `/fn/request_inspector` (node, echo-style inspector for demos)
- `/fn/telegram_ai_reply` (node, Telegram webhook -> OpenAI -> Telegram reply, dry-run by default)

## Quality checks

```bash
./scripts/smoke.sh
./scripts/curl-examples.sh
./scripts/stress.sh
./scripts/benchmark-qr.sh default
./scripts/benchmark-qr.sh no-throttle
./scripts/coverage.sh
./scripts/test-playwright.sh
./scripts/test-all.sh
```

## Playwright UI E2E

Gateway/Console has a real browser E2E flow with Playwright:

- maps endpoint route to function (`invoke.routes`)
- validates Gateway tab rendering
- clicks **Edit mapping** in Gateway row
- verifies deep-link navigation to Configuration tab and mapped route editor

Run:

```bash
./scripts/test-playwright.sh
```

## Documentation

- [English docs](./docs/en/index.md)
- [Documentación en Español](./docs/es/index.md)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).
