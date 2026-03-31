# `fastfn.json` Reference

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes and tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

`fastfn.json` is the default CLI config file. FastFN reads it from the current directory unless you pass `--config`.

## Quick View

- Complexity: Reference
- Typical time: 10-20 minutes
- Use this when: you want one place to define default directories, routing behavior, runtime daemon counts, or host binaries
- Image workloads note: `apps` and `services` in this branch are available through native mode (`fastfn dev --native`, `fastfn run --native`)
- Outcome: reproducible local and CI behavior without long command lines

## Supported keys

| Key | Type | What it controls |
| --- | --- | --- |
| `functions-dir` | `string` | Default functions root when no directory is passed to CLI commands. |
| `public-base-url` | `string` | Canonical public URL used in generated OpenAPI `servers[0].url`. |
| `openapi-include-internal` | `boolean` | Whether internal `/_fn/*` endpoints appear in OpenAPI and Swagger. |
| `force-url` | `boolean` | Global opt-in that allows config-based routes to replace an already mapped URL. |
| `domains` | `array` | Domain checks used by `fastfn doctor domains`. |
| `runtime-daemons` | `object` or `string` | How many daemon instances to launch per external runtime. |
| `runtime-binaries` | `object` or `string` | Which host executable FastFN should use for each runtime or tool. |
| `hot-reload` | `boolean` | Enable/disable hot reload for `dev` and `run` commands. Default: `true`. |
| `apps` | `object` | Public HTTP apps backed by Docker/OCI images. |
| `services` | `object` | Private support workloads backed by Docker/OCI images. |

Notes:

- Preferred keys use kebab-case.
- Compatibility aliases are still accepted for older projects.
- `domains` only affects `fastfn doctor domains`; it does not block inbound hosts by itself.
- `runtime-daemons` applies to external runtimes (`node`, `python`, `php`, `rust`, `go`). `lua` runs in-process, so a daemon count for `lua` is ignored.
- `apps` require at least one public `routes` entry and a single `port`.
- `services` stay private and expose connection env vars to functions and image-backed apps.
- Current branch scope keeps image workloads on native mode only; classic Docker dev remains functions-only.

## Example 1: Default functions directory

`fastfn.json`

```json
{
  "functions-dir": "functions"
}
```

Run:

```bash
fastfn dev
```

Expected behavior:

- FastFN uses `functions/` automatically.

## Example 2: Scale runtime daemons

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "runtime-daemons": {
    "node": 3,
    "python": 3,
    "php": 2,
    "rust": 2
  }
}
```

Run:

```bash
FN_RUNTIMES=node,python,php,rust fastfn dev --native
```

Validate:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

What to expect:

- `node`, `python`, `php`, and `rust` show a `routing` mode.
- When a runtime has more than one socket, `routing` is `round_robin`.
- `sockets` lists each daemon instance separately.

String form is also supported:

```json
{
  "runtime-daemons": "node=3,python=3,php=2,rust=2"
}
```

## Example 3: Choose host binaries

`fastfn.json`

```json
{
  "runtime-binaries": {
    "python": "python3.12",
    "node": "node20",
    "php": "php8.3",
    "composer": "composer",
    "cargo": "cargo",
    "openresty": "/opt/homebrew/bin/openresty"
  }
}
```

Important detail:

- FastFN chooses one executable per key.
- All daemon instances for that runtime use the same configured executable.
- Multi-daemon routing does not mean mixed versions inside the same runtime group.

Supported binary keys:

| Key | Env override | Used for |
| --- | --- | --- |
| `openresty` | `FN_OPENRESTY_BIN` | OpenResty in native mode or inside the Docker container entrypoint. |
| `docker` | `FN_DOCKER_BIN` | Docker CLI used by `fastfn dev` and `fastfn doctor`. |
| `python` | `FN_PYTHON_BIN` | Python runtime daemon and Python-based launchers used by PHP, Rust, and Go daemons. |
| `node` | `FN_NODE_BIN` | Node runtime daemon process. |
| `npm` | `FN_NPM_BIN` | Node dependency installation. |
| `php` | `FN_PHP_BIN` | PHP worker execution inside the PHP daemon. |
| `composer` | `FN_COMPOSER_BIN` | PHP dependency installation. |
| `cargo` | `FN_CARGO_BIN` | Rust builds. |
| `go` | `FN_GO_BIN` | Go builds used by the Go daemon. |

If you only need a temporary override, the environment variables above work without editing `fastfn.json`.

## Example 4: Explicit socket map (advanced override)

`FN_RUNTIME_SOCKETS` can override generated sockets completely.

Example:

```bash
export FN_RUNTIME_SOCKETS='{"node":["unix:/tmp/fastfn/node-1.sock","unix:/tmp/fastfn/node-2.sock"],"python":"unix:/tmp/fastfn/python.sock"}'
fastfn dev --native functions
```

Rules:

- A runtime value can be a string or an array.
- If `FN_RUNTIME_SOCKETS` is set, it wins over `runtime-daemons` and `FN_RUNTIME_DAEMONS`.
- Use this only when you need full control over socket locations.

## Example 5: Public base URL and internal OpenAPI

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "public-base-url": "https://api.example.com",
  "openapi-include-internal": true
}
```

Validate:

```bash
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '{server: .servers[0].url, has_health: (.paths | has("/_fn/health"))}'
```

## Example 6: Simple image-backed app and MySQL service

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "apps": {
    "admin": {
      "image": "ghcr.io/acme/admin:latest",
      "port": 3000,
      "routes": ["/admin/*"],
      "env": {
        "NODE_ENV": "production"
      }
    }
  },
  "services": {
    "mysql": {
      "image": "mysql:8.4",
      "port": 3306,
      "volume": "mysql-data",
      "env": {
        "MYSQL_DATABASE": "app",
        "MYSQL_USER": "app",
        "MYSQL_PASSWORD": "secret",
        "MYSQL_ROOT_PASSWORD": "rootsecret"
      }
    }
  }
}
```

Run:

```bash
fastfn dev --native
```

What to expect:

- Requests matching `/admin/*` proxy to the `admin` image workload.
- Functions receive `SERVICE_MYSQL_HOST`, `SERVICE_MYSQL_PORT`, and `SERVICE_MYSQL_URL`.
- Known service names also receive convenience aliases such as `MYSQL_HOST`, `MYSQL_PORT`, and `MYSQL_URL`.
- `/_fn/health` includes `apps` and `services` snapshots alongside runtime health.

## Precedence

Config file lookup:

1. `--config <path>`
2. `./fastfn.json`
3. `./fastfn.toml`

Runtime daemon wiring:

1. `FN_RUNTIME_SOCKETS`
2. `FN_RUNTIME_DAEMONS`
3. `runtime-daemons`
4. Default: one daemon per external runtime

Binary selection:

1. `FN_*_BIN` environment variable for that key
2. `runtime-binaries`
3. FastFN default lookup candidates (`python3` then `python`, `node`, `php`, `cargo`, and so on)

OpenAPI base URL:

1. `FN_PUBLIC_BASE_URL`
2. `public-base-url`
3. `X-Forwarded-Proto` + `X-Forwarded-Host`
4. Request scheme + `Host`

## Validation

Smoke test:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '.servers[0].url'
```

## Troubleshooting

- If native mode says a runtime is missing, set the matching `FN_*_BIN` variable or `runtime-binaries`.
- If a runtime shows `up=false`, check the `sockets` list in `/_fn/health` first.
- If counts in `runtime-daemons` appear ignored, confirm you are scaling an external runtime, not `lua`.
- If socket locations do not match the generated pattern, look for `FN_RUNTIME_SOCKETS` in your environment.
- If you are not sure whether a setting belongs in config or in the environment, check the environment variables reference first.

### Additional environment variables

| Variable | Default | What it controls |
|----------|---------|-----------------|
| `FN_STRICT_FS` | `1` | Enable filesystem sandboxing for handlers. Set to `0` for development. |
| `FN_MAX_FRAME_BYTES` | — | Maximum request frame size accepted by the runtime socket. |
| `GO_BUILD_TIMEOUT_S` | `180` | Timeout in seconds for Go handler compilation. |
| `FN_HOT_RELOAD` | `1` | Enable hot reload. Applies to both `dev` and `run` commands. |

## Related links

- [Function specification](function-spec.md)
- [Environment variables](environment-variables.md)
- [Complete config reference](fn-config-complete.md)
- [HTTP API reference](http-api.md)
- [Architecture](../explanation/architecture.md)
- [Performance benchmarks](../explanation/performance-benchmarks.md)
- [Scale runtime daemons](../how-to/scale-runtime-daemons.md)
- [Run and test](../how-to/run-and-test.md)
