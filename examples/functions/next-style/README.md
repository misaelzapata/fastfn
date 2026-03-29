# Next.js Style Routing Demo

This example shows file-based routing with runtime auto-discovery.

It also demonstrates private helper imports that are shared by multiple endpoints without becoming public routes.

## Structure

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `users/_shared.js` -> private helper shared by both user routes
- `hello.js` -> `GET /hello`
- `html/index.js` -> `GET /html` (HTML response)
- `showcase/index.js` -> `GET /showcase` (HTML + CSS page + real-time form preview)
- `showcase/get.form.js` -> `GET /showcase/form` (read form state)
- `showcase/post.form.js` -> `POST /showcase/form` (save form state)
- `showcase/put.form.js` -> `PUT /showcase/form` (update form state)
- `downloads/get.report.js` -> `GET /downloads/report` (CSV download attachment)
- `downloads/get.image.js` -> `GET /downloads/image` (image download attachment)
- `blog/index.py` -> `GET /blog`
- `blog/[...slug].py` -> `GET /blog/:slug*`
- `blog/_shared.py` -> private helper shared by both blog routes
- `admin/post.users.[id].py` -> `POST /admin/users/:id`
- `php/get.profile.[id].php` -> `GET /php/profile/:id`
- `php/get.export.php` -> `GET /php/export` (mod_php-style raw CSV output)
- `php/_shared.php` -> private helper shared by both PHP routes
- `rust/get.health.rs` -> `GET /rust/health`
- `rust/get.version.rs` -> `GET /rust/version`
- `rust/_shared.rs` -> private helper shared by both Rust routes

Private helpers stay out of route discovery and out of `/_fn/openapi.json`:

- `/users/_shared` does not exist
- `/blog/_shared` does not exist
- `/php/_shared` does not exist
- `/rust/_shared` does not exist

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

> **Note:** Rust and Go are not in the default native-mode runtimes.
> To include them, set `FN_RUNTIMES`:
>
> ```bash
> FN_RUNTIMES=python,node,php,lua,rust ./bin/fastfn dev examples/functions/next-style
> ```

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
curl -sS http://127.0.0.1:8080/blog
curl -sS http://127.0.0.1:8080/blog/a/b/c
curl -sS -X POST http://127.0.0.1:8080/admin/users/123
curl -sS http://127.0.0.1:8080/php/profile/123
curl -sS -OJ http://127.0.0.1:8080/php/export
curl -sS http://127.0.0.1:8080/rust/health
curl -sS http://127.0.0.1:8080/rust/version
```
