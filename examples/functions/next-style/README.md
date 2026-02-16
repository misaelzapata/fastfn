# Next.js Style Routing Demo

This example shows file-based routing with runtime auto-discovery.

## Structure

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `hello.js` -> `GET /hello`
- `html/index.js` -> `GET /html` (HTML response)
- `showcase/index.js` -> `GET /showcase` (HTML + CSS page + real-time form preview)
- `showcase/get.form.js` -> `GET /showcase/form` (read form state)
- `showcase/post.form.js` -> `POST /showcase/form` (save form state)
- `showcase/put.form.js` -> `PUT /showcase/form` (update form state)
- `downloads/get.report.js` -> `GET /downloads/report` (CSV download attachment)
- `downloads/get.image.js` -> `GET /downloads/image` (image download attachment)
- `blog/[...slug].py` -> `GET /blog/:slug*`
- `admin/post.users.[id].py` -> `POST /admin/users/:id`
- `php/get.profile.[id].php` -> `GET /php/profile/:id`
- `php/get.export.php` -> `GET /php/export` (mod_php-style raw CSV output)
- `rust/get.health.rs` -> `GET /rust/health`

## Run

From repo root:

```bash
./bin/fastfn dev examples/functions/next-style
```

Hot reload controls (optional):

```bash
FN_HOT_RELOAD_WATCHDOG=1 \
FN_HOT_RELOAD_WATCHDOG_POLL=0.2 \
FN_HOT_RELOAD_DEBOUNCE_MS=150 \
./bin/fastfn dev examples/functions/next-style
```

Manual catalog reload (both methods supported):

```bash
curl -sS -X POST http://127.0.0.1:8080/_fn/reload
curl -sS http://127.0.0.1:8080/_fn/reload
```

Then call:

```bash
curl -sS http://127.0.0.1:8080/users
curl -sS http://127.0.0.1:8080/users/123
curl -sS http://127.0.0.1:8080/hello
curl -sS http://127.0.0.1:8080/html?name=Developer
curl -sS http://127.0.0.1:8080/showcase
curl -sS http://127.0.0.1:8080/showcase/form
curl -sS -X POST http://127.0.0.1:8080/showcase/form -H 'content-type: application/json' --data '{"name":"Misael","accent":"#38bdf8","message":"Saved from POST"}'
curl -sS -X PUT http://127.0.0.1:8080/showcase/form -H 'content-type: application/json' --data '{"name":"Misael","accent":"#f59e0b","message":"Updated from PUT"}'
curl -sS -OJ http://127.0.0.1:8080/downloads/report
curl -sS -OJ http://127.0.0.1:8080/downloads/image
curl -sS http://127.0.0.1:8080/blog/a/b/c
curl -sS -X POST http://127.0.0.1:8080/admin/users/123
curl -sS http://127.0.0.1:8080/php/profile/123
curl -sS -OJ http://127.0.0.1:8080/php/export
curl -sS http://127.0.0.1:8080/rust/health
```
