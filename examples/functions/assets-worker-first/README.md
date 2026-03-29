# Worker-First Demo

Framework-style build output mounted from `dist/`, with worker routes taking precedence before static assets.

## Config (`fn.config.json`)

```json
{
  "assets": {
    "directory": "dist",
    "not_found_handling": "single-page-application",
    "run_worker_first": true
  }
}
```

- `run_worker_first: true` — function handlers are checked before static files
- `not_found_handling: "single-page-application"` — unknown paths return `dist/index.html` (200)

## Run

Go and Rust are not default native runtimes. To enable them:

```bash
FN_RUNTIMES=python,node,php,lua,go,rust fastfn dev examples/functions/assets-worker-first
```

Without Go/Rust enabled, only static assets will be served.

## Routes

| Path | Source | Behavior |
|------|--------|----------|
| `/` | `dist/index.html` | Static shell |
| `/style.css` | `dist/style.css` | Static CSS |
| `/app.js` | `dist/app.js` | Static JS |
| `/hello` | `rust/hello/handler.rs` | Rust handler wins over `dist/hello/index.html` |
| `/api-go` | `go/api-go/handler.go` | Go handler (JSON) |
| `/catalog/overview` | SPA fallback | Returns `dist/index.html` (200) |

## Test

```bash
curl -sS http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/hello            # Rust handler (not static file)
curl -sS http://127.0.0.1:8080/api-go
curl -sS http://127.0.0.1:8080/catalog/overview  # SPA fallback
```
