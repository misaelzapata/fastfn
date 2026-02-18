# Chapter 4 - Function Metadata and Methods (`fn.config.json`)

Goal: enforce HTTP methods and execution limits.

## Step 1: create `fn.config.json`

Create `functions/hello-world/fn.config.json`:

```json
{
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 262144,
  "invoke": {
    "summary": "hello world tutorial function",
    "methods": ["GET"],
    "query": { "name": "World" },
    "body": ""
  }
}
```

Notes:

- In file-routes layout, a `fn.config.json` without `runtime`/`name`/`entrypoint` is a **policy overlay** for every handler file under that folder.
- Here we intentionally restrict this function folder to `GET` only (even though Chapter 2 created a `post.js` handler). This is a practical pattern for temporarily disabling non-GET methods without deleting code.

## Step 2: validate method policy

Allowed:

```bash
curl -i -sS 'http://127.0.0.1:8080/hello-world' | sed -n '1,12p'
```

Blocked method example (`POST` is routed, but denied by policy):

```bash
curl -i -sS -X POST 'http://127.0.0.1:8080/hello-world' --data '{}' | sed -n '1,20p'
```

Expected: `405 Method Not Allowed`.

## Step 3: confirm docs 

Open `http://127.0.0.1:8080/docs` and verify only configured methods are shown.
