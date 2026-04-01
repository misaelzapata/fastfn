# `fastfn.json` Reference

> Verified status as of **April 1, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes and tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

`fastfn.json` is the default CLI config file. FastFN reads it from the current directory unless you pass `--config`.

## Quick View

- Complexity: Reference
- Typical time: 10-20 minutes
- Use this when: you want one place to define default directories, routing behavior, runtime daemon counts, or host binaries
- Image workloads note: `apps` and `services` in this branch are available through native mode (`fastfn dev --native`, `fastfn run --native`) and run as Firecracker microVMs from local bundles, registry images, `image_file`, or `dockerfile`
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
| `apps` | `object` | Public HTTP apps backed by Firecracker microVMs. |
| `services` | `object` | Private support workloads backed by Firecracker microVMs. |

Notes:

- Preferred keys use kebab-case.
- Compatibility aliases are still accepted for older projects.
- `domains` only affects `fastfn doctor domains`; it does not block inbound hosts by itself.
- `runtime-daemons` applies to external runtimes (`node`, `python`, `php`, `rust`, `go`). `lua` runs in-process, so a daemon count for `lua` is ignored.
- `apps` require at least one public `routes` entry and a primary `port`.
- `services` stay private by default and expose connection env vars to functions and image-backed apps.
- Each image workload must choose exactly one source: `image`, `image_file`, or `dockerfile`.
- `image` can be either a local Firecracker bundle directory or an OCI registry/image reference such as `mysql:8.4`.
- `image_file` loads a local OCI or Docker image archive before converting it to a cached Firecracker bundle.
- `dockerfile` builds through the Docker Engine API, then converts the resulting OCI image into a cached Firecracker bundle under `.fastfn/firecracker/images/`.
- Current branch scope keeps image workloads on native mode only, and only on Linux/KVM hosts; classic Docker dev remains functions-only.
- The fast path is resident and prewarmed by default: once an app or service is up, public and internal traffic go through stable broker endpoints instead of rebuilding or restarting Firecracker on each request.
- Folder-local `fn.config.json` files can declare `app`, `service`, `apps`, or `services` without editing the global `fastfn.json`.

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

## Example 6: Resident Firecracker app and MySQL service

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "apps": {
    "admin": {
      "dockerfile": "./functions/admin/Dockerfile",
      "context": "./functions/admin",
      "port": 3000,
      "routes": ["/admin/*"],
      "lifecycle": {
        "idle_action": "run",
        "prewarm": true
      },
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
      "lifecycle": {
        "idle_action": "run",
        "prewarm": true
      },
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

- Requests matching `/admin/*` proxy to the `admin` Firecracker workload.
- Functions receive `SERVICE_MYSQL_HOST`, `SERVICE_MYSQL_PORT`, and `SERVICE_MYSQL_URL`.
- Services also receive direct aliases based on their real service names, such as `MYSQL_HOST` or `MARIADB_HOST` when those names are not ambiguous.
- `/_fn/health` includes `apps` and `services` snapshots alongside runtime health, including `broker_host`, `broker_port`, `internal_host`, `lifecycle_state`, and `firecracker_pid`.

## Example 7: Restrict a public app with `allow_hosts` and `allow_cidrs`

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "apps": {
    "dashboard": {
      "image": "traefik/whoami:v1.10.2",
      "port": 80,
      "routes": ["/dashboard/*"],
      "access": {
        "allow_hosts": ["dashboard.example.com", "*.corp.example.com"],
        "allow_cidrs": ["203.0.113.0/24", "2001:db8::/32"]
      }
    }
  }
}
```

What to expect:

- Host matching is case-insensitive and supports exact values plus `*.example.com` style wildcards.
- Client IP matching accepts both CIDR strings and single IPs, which FastFN normalizes to `/32` or `/128`.
- When both `allow_hosts` and `allow_cidrs` are present on HTTP, both must pass.
- Public TCP ports only support `allow_cidrs`.
- If FastFN sits behind a trusted proxy, set `FN_TRUSTED_PROXY_CIDRS` so the gateway can safely honor `X-Forwarded-For`.

Folder-local variant:

```json
{
  "service": {
    "image": "postgres:16",
    "port": 5432,
    "volume": "payments-db"
  }
}
```

Placed in `functions/payments/fn.config.json`, this declares a folder-scoped service without changing the root `fastfn.json`.

## Image workload sources and lifecycle

Workload source fields:

- `image`: local Firecracker bundle directory or registry/image reference.
- `image_file`: local OCI or Docker archive file.
- `dockerfile`: local Dockerfile path. Use `context` when the build context differs from the Dockerfile directory.

Lifecycle fields:

```json
{
  "lifecycle": {
    "idle_action": "run",
    "pause_after_ms": 15000,
    "prewarm": true
  }
}
```

Behavior:

- Default policy is speed-first: `idle_action` defaults to `run` and `prewarm` defaults to `true` for both `apps` and `services`.
- `pause_after_ms` only matters when `idle_action` is `pause`.
- `services` should normally stay resident; `pause` is mainly useful for low-priority apps where saving memory matters more than latency.
- Once prewarmed, FastFN serves public HTTP and private `*.internal` traffic through stable brokers, so hot requests do not rebuild, repull, or restart Firecracker.
- Prewarmed services also wait for a short stable-ready window before FastFN considers them attachable. That prevents dependent apps from connecting to a transient bootstrap listener and then failing during warmup.

## Access policy

The simple firewall lives on public image workloads.

Supported shapes:

- `app.access` and `service.access` act as shorthands for the primary public port in the simple `port + routes` schema.
- `ports[].access` applies policy per public endpoint when you use the expanded `ports` schema.

Fields:

```json
{
  "access": {
    "allow_hosts": ["api.example.com", "*.corp.example.com"],
    "allow_cidrs": ["203.0.113.0/24", "2001:db8::/32"]
  }
}
```

Rules:

- `allow_hosts` is HTTP-only and matches the request host after FastFN normalizes the `Host` or `X-Forwarded-Host` header.
- `allow_cidrs` works for both HTTP and TCP public ports.
- On HTTP, `allow_hosts` and `allow_cidrs` are cumulative when both exist.
- On TCP public ports, setting `allow_hosts` is a config error.
- Empty `access` means the endpoint is public with no extra restriction.

Health and state:

- `/_fn/health` keeps the legacy `host`, `port`, and `routes` fields for the primary HTTP app endpoint.
- The richer `public_endpoints` list now includes `protocol`, `routes`, `listen_port`, `allow_hosts`, and `allow_cidrs`.
- Hot resident state also includes `broker_host`, `broker_port`, `internal_host`, `internal_url`, `lifecycle_state`, and `firecracker_pid`.

## Firecracker bundle layout

When `image` points to a local directory, FastFN expects this bundle layout:

```text
images/
  admin/
    vmlinux
    rootfs.ext4
    fastfn-image.json   # optional
  mysql/
    vmlinux
    rootfs.ext4
    fastfn-image.json   # optional
```

Minimal requirements:

- `vmlinux`: the guest kernel image.
- `rootfs.ext4`: the guest root filesystem.
- The guest software must start a long-lived process that listens on the configured port.

Optional `fastfn-image.json` keys:

```json
{
  "kernel": "vmlinux",
  "rootfs": "rootfs.ext4",
  "kernel_args": "console=ttyS0 reboot=k panic=1 pci=off",
  "guest_port": 10700,
  "vcpu_count": 1,
  "memory_mib": 512,
  "config_drive_bytes": 65536
}
```

Notes:

- Paths inside `fastfn-image.json` are relative to the bundle directory.
- If the manifest is omitted, FastFN defaults to `vmlinux`, `rootfs.ext4`, guest port `10700`, `1` vCPU, and `512 MiB`.
- Local bundles are only one source option; FastFN can also pull/build OCI inputs and cache the converted bundle automatically.

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
- If an app or service says a local bundle was not found, confirm that `image` points to a local directory and that it contains `vmlinux` plus `rootfs.ext4`.
- If a workload uses `image`, `image_file`, or `dockerfile` and fails before boot, confirm that the Docker daemon is reachable because FastFN currently resolves OCI inputs through the Docker Engine API.
- If hot requests look slower than expected, inspect `/_fn/health` and verify `broker_host`, `broker_port`, `lifecycle_state`, and `firecracker_pid` stay stable across repeated requests.
- If image workloads fail immediately on macOS or Windows, that is expected in this branch; Firecracker workloads require a Linux/KVM host.
- If `allow_cidrs` appears to evaluate the proxy IP instead of the caller IP, set `FN_TRUSTED_PROXY_CIDRS` to the CIDR list of the proxies you trust.

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
