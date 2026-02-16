# Operational Recipes

This page is for copy/paste operations with context and expected outcomes.

## Recipe 1: check platform health

When to use: startup verification and incident triage.

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

Expected: stable runtimes `python`, `node`, `php`, and `lua` show `health.up = true` (`rust`/`go` when enabled).

If `curl` cannot connect but the stack is up (and/or `wget` works), try:

```bash
# force IPv4
curl -4 -sS 'http://127.0.0.1:8080/_fn/health'

# ignore proxy env vars (if your environment sets them)
curl --noproxy '*' -sS 'http://127.0.0.1:8080/_fn/health'
```

In sandboxed environments where the host loopback is blocked, run the request from inside the container:

```bash
docker compose exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/_fn/health'"
```

## Recipe 2: inspect function catalog

When to use: confirm discovery and runtime ownership.

```bash
curl -sS 'http://127.0.0.1:8080/_fn/catalog'
```

Expected: function lists exist for `python`, `node`, `php`, and `lua` (`rust`/`go` when enabled).

## Recipe 3: invoke query-driven function

```bash
curl -sS 'http://127.0.0.1:8080/echo?key=test'
```

Expected: JSON includes `key = test`.

## Recipe 4: invoke versioned route

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=NodeWay'
```

Expected: JSON response from your configured hello route.

## Recipe 4b: invoke PHP and Rust examples

```bash
curl -sS 'http://127.0.0.1:8080/php/profile/123'
curl -sS 'http://127.0.0.1:8080/rust/health'
```

## Recipe 4c: invoke routes (Python + Node + PHP + Lua patterns)

```bash
curl -sS 'http://127.0.0.1:8080/blog/a/b/c'
curl -sS 'http://127.0.0.1:8080/users/123'
```

## Recipe 5: change method policy live

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node-echo' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"invoke":{"methods":["PUT","DELETE"]}}'
```

Validate:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8080/node-echo?name=x'         # expect 405
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT 'http://127.0.0.1:8080/node-echo?name=x' # expect 200
```

## Recipe 6: update function env

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-env?runtime=python&name=hello' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"GREETING_PREFIX":{"value":"hello","is_secret":false},"API_KEY":{"value":"demo-secret","is_secret":true}}'
```

Then:

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

Expected greeting uses new prefix.

## Recipe 7: invoke with custom context

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"name":"hello","method":"GET","query":{"name":"Ctx"},"context":{"trace_id":"abc-123","tenant":"demo"}}'
```

Expected: `trace_id` available to handler under `event.context.user`.

## Recipe 8: create function via API

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo-recipe' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"methods":["GET"],"summary":"API-created demo"}'
```

Expected: function directory, code file, and config created.

## Recipe 9: edit function code via API

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=demo-recipe' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"code":"import json\n\ndef handler(event):\n    q = event.get(\"query\") or {}\n    return {\"status\":200,\"headers\":{\"Content-Type\":\"application/json\"},\"body\":json.dumps({\"demo\":q.get(\"name\",\"ok\")})}\n"}'
```

Validate:

```bash
curl -sS 'http://127.0.0.1:8080/demo-recipe?name=RecipeOK'
```

## Recipe 10: return non-JSON payloads

```bash
curl -sS 'http://127.0.0.1:8080/html-demo?name=Web'
curl -sS 'http://127.0.0.1:8080/csv-demo?name=Alice'
curl -sS 'http://127.0.0.1:8080/png-demo' --output out.png
```

Expected:

- `html-demo` -> `text/html`
- `csv-demo` -> `text/csv`
- `png-demo` -> valid PNG signature

## Cleanup after demo runs

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo-recipe' -X DELETE
```
