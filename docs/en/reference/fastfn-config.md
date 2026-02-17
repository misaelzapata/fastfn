# `fastfn.json` Reference

`fastfn.json` is the default CLI config file.

FastFN looks for this file in the current directory when you run commands like `fastfn dev` or `fastfn run`.

## Supported Keys

| Key | Type | Description |
| --- | --- | --- |
| `functions-dir` | `string` | Default functions root when no directory is passed to CLI commands. |
| `public-base-url` | `string` | Canonical public base URL used in generated OpenAPI `servers[0].url`. |
| `openapi-include-internal` | `boolean` | Controls if internal/admin endpoints (`/_fn/*`) are listed in OpenAPI/Swagger. Does not disable the endpoints themselves. Default `false`. |
| `force-url` | `boolean` | Global opt-in to allow config/policy routes to override already-mapped URLs. Default `false`. Prefer setting `invoke.force-url` per function instead. |
| `domains` | `array` | Domains used by `fastfn doctor domains` for DNS/TLS/HTTP diagnostics. |

Notes:
- Preferred keys use kebab-case: `functions-dir`, `public-base-url`.
- Compatibility aliases are still accepted: `functions_dir`, `functionsDir`, `public_base_url`, `publicBaseUrl`.
- OpenAPI internal visibility aliases are also accepted: `openapi_include_internal`, `openapi.include_internal`, `swagger-include-admin`.
- `domains` is for `fastfn doctor domains` checks only. It does not enforce inbound host routing by itself.
- To restrict inbound hosts per function, use `invoke.allow_hosts` in each `fn.config.json`.
- You can also opt-in globally via `force-url` or the CLI flag `--force-url` (unsafe; use sparingly).

## Example 1: Local Dev Default Directory

`fastfn.json`

```json
{
  "functions-dir": "examples/functions/next-style"
}
```

Run:

```bash
fastfn dev
```

Expected behavior:
- FastFN uses `examples/functions/next-style` automatically.

## Example 2: Native Production-Like Run with Public Domain

`fastfn.json`

```json
{
  "functions-dir": "srv/fn/functions",
  "public-base-url": "https://api.example.com"
}
```

Run:

```bash
FN_HOST_PORT=8080 fastfn run --native
```

Validate OpenAPI server URL:

```bash
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq -r '.servers[0].url'
# https://api.example.com
```

## Example 3: Domain from Reverse Proxy Headers

If `public-base-url` is not set, FastFN derives OpenAPI URL from request headers:
- `X-Forwarded-Proto`
- `X-Forwarded-Host`
- fallback: request `Host`

Test:

```bash
curl -sS \
  -H 'X-Forwarded-Proto: https' \
  -H 'X-Forwarded-Host: api.proxy.example' \
  http://127.0.0.1:8080/_fn/openapi.json | jq -r '.servers[0].url'
# https://api.proxy.example
```

## Example 4: Domains Block for Doctor

`fastfn.json`

```json
{
  "domains": [
    "api.example.com",
    {
      "domain": "www.example.com",
      "expected-target": "lb.example.net",
      "enforce-https": true
    }
  ]
}
```

Run:

```bash
fastfn doctor domains
fastfn doctor domains --json
```

`domains` entries support:
- string form: `"api.example.com"`
- object form:
  - `domain` (required)
  - `expected-target` (optional, accepts IP or CNAME)
  - `enforce-https` (optional, default `true`)

## Example 5: Show Internal/Admin Endpoints in Swagger (Without Disabling APIs)

`fastfn.json`

```json
{
  "functions-dir": "examples/functions/next-style",
  "openapi-include-internal": true
}
```

Run:

```bash
fastfn dev
```

Validate:

```bash
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '.paths | has("/_fn/health")'
# true
```

To hide internal/admin endpoints from Swagger again, set it to `false` (or remove the key).

## Precedence

1. CLI flag `--config` (explicit file path).
2. `fastfn.json` in current directory.
3. `fastfn.toml` (fallback only).

For URL resolution in OpenAPI:
1. `FN_PUBLIC_BASE_URL` env var (or `public-base-url` from `fastfn.json`).
2. `X-Forwarded-Proto` + `X-Forwarded-Host`.
3. Request scheme + `Host`.

## Security Note

FastFN blocks direct HTTP access to local config files:
- `/fastfn.json` returns `404`.
- `/fastfn.toml` returns `404`.
