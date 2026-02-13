# Manage Functions (Console API)

Practical CRUD lifecycle using `/_fn/*` endpoints.

## Important: function paths are configurable

Function files are stored under `FN_FUNCTIONS_ROOT` (not hardcoded).

Defaults:

- Docker: `/app/srv/fn/functions`
- local repo: `$PWD/srv/fn/functions`

Set explicitly when needed:

```bash
export FN_FUNCTIONS_ROOT="$PWD/srv/fn/functions"
```

## Prerequisites

- platform running on `http://127.0.0.1:8080`
- Console API enabled (`FN_CONSOLE_API_ENABLED=1`)
- write mode enabled (`FN_CONSOLE_WRITE_ENABLED=1`) or admin token

## 1) Inspect catalog

```bash
curl -sS 'http://127.0.0.1:8080/_fn/catalog'
```

Use this first to confirm runtime names and discover current `functions_root`.

## 2) Create a function

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_new' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"methods":["GET"],"summary":"Demo function"}'
```

## 3) Read details

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_new&include_code=1'
```

## 4) Update policy (methods/limits)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
--data '{"timeout_ms":1200,"max_concurrency":5,"max_body_bytes":262144,"invoke":{"methods":["GET","POST"]}}'
```

## 4a) Reuse shared dependency packs (optional)

If multiple functions need the same dependencies, you can define a shared pack under:

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/<runtime>/<pack>/
```

Then attach it to a function via `shared_deps`:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"shared_deps":["common_http"]}'
```

## 4b) Add a schedule (interval cron)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"schedule":{"enabled":true,"every_seconds":60,"method":"GET","query":{"action":"inc"},"headers":{},"body":"","context":{}}}'
```

Inspect scheduler state:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/schedules'
```

## 5) Update env

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-env?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"GREETING_PREFIX":"hello"}'
```

## 6) Update code

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"code":"import json\n\ndef handler(event):\n    q = event.get(\"query\") or {}\n    return {\"status\":200,\"headers\":{\"Content-Type\":\"application/json\"},\"body\":json.dumps({\"ok\":True,\"query\":q})}\n"}'
```

## 7) Invoke through internal helper

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"runtime":"python","name":"demo_new","method":"GET","query":{"name":"Ops"}}'
```

This uses `ngx.location.capture('/fn/...')`, so it enforces the same policy as public traffic.

## 7b) Enqueue async job (run later)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/jobs' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"name":"demo_new","method":"GET","query":{"name":"Async"}}'
```

Then poll:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/jobs/<id>'
curl -sS 'http://127.0.0.1:8080/_fn/jobs/<id>/result'
```

## 8) Delete function

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_new' -X DELETE
```

## Common errors

- `404`: unknown function/version
- `405`: method not allowed by policy
- `409`: ambiguous function name across runtimes (or route mapping conflict)
- `403`: write disabled/local-only restriction
