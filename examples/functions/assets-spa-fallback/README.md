# SPA Fallback Demo

History API SPA with `public/` mounted at `/` and deep-link fallback to `public/index.html`.

## Config (`fn.config.json`)

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

- `not_found_handling: "single-page-application"` — unknown paths return `index.html` with HTTP 200 (SPA deep-link support)
- `run_worker_first: false` — static files are checked before function handlers

## Run

```bash
fastfn dev examples/functions/assets-spa-fallback
```

## Routes

| Path | Source | Behavior |
|------|--------|----------|
| `/` | `public/index.html` | Static shell |
| `/style.css` | `public/style.css` | Static CSS |
| `/app.js` | `public/app.js` | Static JS |
| `/api-profile` | `php/api-profile/handler.php` | PHP handler (JSON) |
| `/api-flags` | `lua/api-flags/handler.lua` | Lua handler (JSON) |
| `/dashboard` | SPA fallback | Returns `index.html` (200) |
| `/settings` | SPA fallback | Returns `index.html` (200) |
| `/any/deep/path` | SPA fallback | Returns `index.html` (200) |

## Test

```bash
curl -sS http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/api-profile
curl -sS http://127.0.0.1:8080/api-flags
curl -sS http://127.0.0.1:8080/dashboard       # returns index.html (SPA fallback)
curl -sS http://127.0.0.1:8080/nonexistent      # returns index.html (SPA fallback)
```
