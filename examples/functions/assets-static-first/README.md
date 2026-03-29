# Static-First Demo

Cloudflare-style static assets mounted at `/`, with API routes falling back to runtime handlers only when no asset matches.

## Config (`fn.config.json`)

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "404",
    "run_worker_first": false
  }
}
```

- `not_found_handling: "404"` — unknown paths return a JSON 404 error (no SPA fallback)
- `run_worker_first: false` — static files are checked before function handlers

## Run

```bash
fastfn dev examples/functions/assets-static-first
```

## Routes

| Path | Source | Behavior |
|------|--------|----------|
| `/` | `public/index.html` | Static shell |
| `/style.css` | `public/style.css` | Static CSS |
| `/app.js` | `public/app.js` | Static JS |
| `/api-node` | `node/api-node/handler.js` | Node handler (JSON) |
| `/api-python` | `python/api-python/handler.py` | Python handler (JSON) |
| `/nonexistent` | — | 404 JSON error |

## Test

```bash
curl -sS http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/api-node
curl -sS http://127.0.0.1:8080/api-python
curl -sS http://127.0.0.1:8080/nonexistent     # 404 JSON
```
