# Chapter 4 - Function Metadata and Methods (`fn.config.json`)

Goal: enforce HTTP methods and execution limits.

## Step 1: create config

Path: `srv/fn/functions/node/hello_world/fn.config.json`

```json
{
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 262144,
  "invoke": {
    "summary": "hello world tutorial function",
    "methods": ["GET", "POST"],
    "query": { "name": "World" },
    "body": ""
  }
}
```

## Step 2: validate method policy

Allowed:

```bash
curl -i -sS 'http://127.0.0.1:8080/fn/hello_world' | sed -n '1,12p'
```

Blocked method example:

```bash
curl -i -sS -X DELETE 'http://127.0.0.1:8080/fn/hello_world' | sed -n '1,20p'
```

Expected: `405 Method Not Allowed`.

## Step 3: confirm docs

Open `http://127.0.0.1:8080/docs` and verify only configured methods are shown.
