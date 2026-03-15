# Console and Admin Access


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes/tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
## Quick View

- Complexity: Intermediate
- Typical time: 10-15 minutes
- Use this when: you want to harden /console and /_fn endpoints
- Outcome: console and admin API are exposed only as intended


This guide is intentionally focused on the **admin surface only**:

- `/console`
- `/_fn/*`

For function business auth (API key, session, JWT patterns), use:

- `docs/en/tutorial/auth-and-secrets.md`

## Scope

This page covers:

- enabling/disabling Console UI/API
- write protections
- local-only mode
- admin token for remote operations
- URL-based console deep links
- gateway dashboard for mapped routes

## Flags

- `FN_UI_ENABLED` (default `0`)
- `FN_CONSOLE_API_ENABLED` (default `1`)
- `FN_CONSOLE_WRITE_ENABLED` (default `0`)
- `FN_CONSOLE_LOCAL_ONLY` (default `1`)
- `FN_ADMIN_TOKEN` (optional)
- `FN_CONSOLE_LOGIN_ENABLED` (default `0`, Console UI only)
- `FN_CONSOLE_LOGIN_API` (default `0`, if enabled: protect Console API too)
- `FN_CONSOLE_LOGIN_USERNAME` / `FN_CONSOLE_LOGIN_PASSWORD`
- `FN_CONSOLE_SESSION_SECRET` (or reuse `FN_ADMIN_TOKEN`)

## Recommended baseline

- keep `FN_UI_ENABLED=0` unless needed
- keep `FN_CONSOLE_LOCAL_ONLY=1`
- keep `FN_CONSOLE_WRITE_ENABLED=0` by default
- set `FN_ADMIN_TOKEN` for controlled remote admin calls

## Optional login (Console UI)

If you want a login screen for `/console`:

```bash
export FN_CONSOLE_LOGIN_ENABLED=1
export FN_CONSOLE_LOGIN_USERNAME='admin'
export FN_CONSOLE_LOGIN_PASSWORD='dev-password'
export FN_CONSOLE_SESSION_SECRET='change-me-too'
```

If you also want the Console API (`/_fn/*`) to require login cookies:

```bash
export FN_CONSOLE_LOGIN_API=1
```

## Read current UI/API state

```bash
curl -sS 'http://127.0.0.1:8080/_fn/ui-state'
```

## Use admin token

```bash
curl -sS 'http://127.0.0.1:8080/_fn/ui-state' \
  -H 'x-fn-admin-token: my-secret-token'
```

## Toggle admin surface at runtime

```bash
curl -sS 'http://127.0.0.1:8080/_fn/ui-state' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"ui_enabled":true,"api_enabled":true,"write_enabled":false,"local_only":true}'
```

`/_fn/ui-state` behavior:

- `GET` is read-only.
- `PUT|POST|PATCH|DELETE` are write operations and require write permission.

## Typical admin errors

- `403 console ui local-only`
- `403 console api local-only`
- `403 console write disabled`
- `404 console ui disabled`

## Console deep links (real URLs)

The console supports deep links that survive refresh:

![FastFN Admin Console dashboard view](../../assets/screenshots/admin-console-dashboard.png)

- `/console`
- `/console/explorer`
- `/console/explorer/<runtime>/<function>`
- `/console/explorer/<runtime>/<function>@<version>`
- `/console/gateway`
- `/console/configuration`
- `/console/crud`
- `/console/wizard`

Example:

- `/console/explorer/node/hello@v2`

Gateway dashboard quick link:

- `/console/gateway`

The Gateway tab shows:

- mapped public route path
- target function (`runtime/function@version`)
- allowed methods
- route conflicts detected during discovery

## Console UI quick tour

The Console is organized into top-level tabs:

- **Explorer**: function detail + a safe invoke form (`/_fn/invoke`).
- **Wizard**: beginner step-by-step function generator.
- **Gateway**: mapped endpoint dashboard (public URL -> function target).
- **Configuration**: grouped panels for:
  - policy limits/methods/routes
  - edge proxy config (`edge.*`) for `{ "proxy": { ... } }` responses
  - schedule (interval cron)
  - env editor (secrets are masked)
  - code editor
- **CRUD**: create/delete functions, plus Console access toggles.

Schedule panel notes:

- Schedules are configured per function in `fn.config.json` under `schedule`.
- `GET /_fn/schedules` shows current schedule state (`next`, `last`, last status/error).

## Production hardening checklist

- keep console/API private or behind VPN
- avoid exposing `/_fn/*` directly to public internet
- require admin token for write/admin operations
- keep write disabled except maintenance windows

## Validate it

- Call `GET /_fn/ui-state` before and after a config change.
- Confirm write operations fail without the right local/admin access.
- Load `/console` once with the intended login mode before exposing it to others.

## Troubleshooting

- If `/console` is missing, confirm `FN_UI_ENABLED=1`.
- If reads work but writes fail, check `FN_CONSOLE_WRITE_ENABLED` and `FN_ADMIN_TOKEN`.
- If login loops, clear cookies and confirm `FN_CONSOLE_SESSION_SECRET` is set consistently.

## Next step

Continue with [Manage functions](./manage-functions.md) to use the admin surface for real create/update/delete flows.

## Related links

- [Manage functions](./manage-functions.md)
- [Security confidence](./security-confidence.md)
- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and test](./run-and-test.md)
