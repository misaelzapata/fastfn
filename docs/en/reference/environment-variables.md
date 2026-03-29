# Environment Variables

> Verified status as of **March 27, 2026**.

This page is a practical index of the environment variables that show up most often in FastFN docs and runtime behavior.

## Quick View

- Complexity: Reference
- Typical time: 10-15 minutes
- Use this when: you want to know which `FN_*` variables matter and what each one does
- Outcome: you can set the right variable in the right place without guessing

## Core project and routing variables

| Variable | Default | What it controls |
| --- | --- | --- |
| `FN_FUNCTIONS_ROOT` | project-specific | Root directory for functions and discovery |
| `FN_RUNTIMES` | all enabled runtimes | Which runtimes are considered available |
| `FN_NAMESPACE_DEPTH` | `3` | How deep runtime-grouped discovery recurses |
| `FN_ZERO_CONFIG_IGNORE_DIRS` | empty | Extra directories ignored by zero-config discovery |
| `FN_FORCE_URL` | `0` | Global config route override behavior |
| `FN_PUBLIC_BASE_URL` | request-derived | Canonical OpenAPI server URL |
| `FN_OPENAPI_INCLUDE_INTERNAL` | `0` | Whether internal `/_fn/*` paths appear in OpenAPI |
| `FN_HOT_RELOAD` | `1` | Enables hot reload in `dev` and `run` |

## Daemons, sockets, and runtime wiring

| Variable | Default | What it controls |
| --- | --- | --- |
| `FN_RUNTIME_DAEMONS` | one per runtime | Number of external runtime daemons to launch |
| `FN_RUNTIME_SOCKETS` | generated sockets | Explicit socket map for runtimes |
| `FN_SOCKET_BASE_DIR` | internal default | Base directory for generated socket paths |
| `FN_RUNTIME_LOG_FILE` | empty | File used for runtime log capture |
| `FN_MAX_FRAME_BYTES` | `2097152` | Maximum socket frame size accepted by runtimes |
| `FN_*_BIN` | runtime default | Host binary used by a specific runtime/tool |

Common binary overrides:

- `FN_OPENRESTY_BIN`
- `FN_DOCKER_BIN`
- `FN_PYTHON_BIN`
- `FN_NODE_BIN`
- `FN_NPM_BIN`
- `FN_PHP_BIN`
- `FN_COMPOSER_BIN`
- `FN_CARGO_BIN`
- `FN_GO_BIN`

## Runtime safety variables

| Variable | Default | What it controls |
| --- | --- | --- |
| `FN_STRICT_FS` | `1` | Handler filesystem sandboxing |
| `FN_STRICT_FS_ALLOW` | empty | Extra allowed roots for strict fs access |
| `FN_PREINSTALL_PY_DEPS_ON_START` | `1` | Preinstall Python deps before serving |
| `FN_AUTO_INFER_PY_DEPS` | `1` | Infer Python deps from imports |
| `FN_PY_INFER_BACKEND` | `native` | Python inference backend (`native`, `pipreqs`) |
| `FN_AUTO_INFER_WRITE_MANIFEST` | `1` | Write inferred dependency manifests |
| `FN_AUTO_INFER_STRICT` | `1` | Make dependency inference stricter |
| `FN_PY_RUNTIME_WORKER_POOL` | `1` | Enable Python persistent worker pool |
| `FN_GO_RUNTIME_WORKER_POOL` | `1` | Enable Go persistent worker pool |
| `FN_NODE_RUNTIME_PROCESS_POOL` | `1` | Enable Node persistent worker pool |
| `FN_NODE_INFER_BACKEND` | `native` | Node inference backend (`native`, `detective`, `require-analyzer`) |

## Console and admin variables

| Variable | Default | What it controls |
| --- | --- | --- |
| `FN_UI_ENABLED` | `0` | Console UI availability |
| `FN_CONSOLE_API_ENABLED` | `1` | Console API availability |
| `FN_CONSOLE_WRITE_ENABLED` | `0` | Console write operations |
| `FN_CONSOLE_LOCAL_ONLY` | `1` | Local-only access guard |
| `FN_ADMIN_TOKEN` | empty | Admin override token |
| `FN_CONSOLE_LOGIN_ENABLED` | `0` | Console UI login screen |
| `FN_CONSOLE_LOGIN_API` | `0` | Whether login also protects console API |
| `FN_CONSOLE_LOGIN_USERNAME` | empty | Login username |
| `FN_CONSOLE_LOGIN_PASSWORD_HASH` | empty | Recommended login hash (`pbkdf2-sha256:<iterations>:<salt_hex>:<digest_hex>`) |
| `FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE` | empty | File that contains the login password hash |
| `FN_CONSOLE_LOGIN_PASSWORD` | empty | Legacy plaintext login password fallback |
| `FN_CONSOLE_LOGIN_PASSWORD_FILE` | empty | File that contains the legacy plaintext login password |
| `FN_CONSOLE_SESSION_SECRET` | empty | Signed session cookie secret |
| `FN_CONSOLE_SESSION_SECRET_FILE` | empty | File that contains the signed session secret |
| `FN_CONSOLE_SESSION_TTL_S` | `43200` | Session cookie lifetime |
| `FN_CONSOLE_LOGIN_RATE_LIMIT_MAX` | `5` | Maximum login attempts per window |
| `FN_CONSOLE_LOGIN_RATE_LIMIT_WINDOW_S` | `300` | Login rate-limit window in seconds |
| `FN_CONSOLE_RATE_LIMIT_MAX` | `120` | Max read/UI console requests per window |
| `FN_CONSOLE_RATE_LIMIT_WINDOW_S` | `60` | General console rate-limit window in seconds |
| `FN_CONSOLE_WRITE_RATE_LIMIT_MAX` | `30` | Max write/admin console requests per window |

## Assets and discovery helpers

| Variable | Default | What it controls |
| --- | --- | --- |
| `FN_MAX_ASSET_BYTES` | `33554432` | Maximum asset size served from memory |
| `FN_HOT_RELOAD_WATCHDOG` | `0` or runtime default | File watcher mode for dev workflows |
| `FN_HOT_RELOAD_WATCHDOG_POLL` | runtime default | Watchdog poll interval |
| `FN_HOT_RELOAD_DEBOUNCE_MS` | runtime default | Debounce for reload events |

## Notes

- Some variables are read by the CLI, some by the gateway, and some by runtime daemons.
- The same `FN_*` prefix can mean different scopes depending on the file or service that reads it.
- If a variable does nothing, check which process is actually reading it.
- For console login, PBKDF2 is the recommended hash format; `sha256:<hex>` remains accepted only as a legacy compatibility format.
- Dependency inference backends are optional. Explicit manifests stay faster and more predictable than invoking `pipreqs`, `detective`, or `require-analyzer`.

## Related links

- [FastFN config reference](./fastfn-config.md)
- [Complete config reference](./fn-config-complete.md)
- [Console and admin access](../how-to/console-admin-access.md)
- [Architecture](../explanation/architecture.md)
- [Debugging and troubleshooting](../how-to/debugging-and-troubleshooting.md)
