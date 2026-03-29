# Complete Config Reference

> Verified status as of **March 27, 2026**.

This page is a practical reference for the config keys that show up across FastFN docs and examples.

## Quick View

- Complexity: Reference
- Typical time: 10-20 minutes
- Use this when: you want one place to look up both global and function-level config
- Outcome: you can tell whether a setting belongs in `fastfn.json`, `fn.config.json`, or an environment variable

## Global config: `fastfn.json`

| Key | Type | What it controls |
| --- | --- | --- |
| `functions-dir` | `string` | Default functions root |
| `public-base-url` | `string` | Canonical OpenAPI server URL |
| `openapi-include-internal` | `boolean` | Whether internal endpoints appear in OpenAPI |
| `force-url` | `boolean` | Global route override behavior |
| `domains` | `array` | Input for doctor domains checks |
| `runtime-daemons` | `object` or `string` | Per-runtime daemon counts |
| `runtime-binaries` | `object` or `string` | Host executables to use |
| `hot-reload` | `boolean` | Enable or disable hot reload |

## Function config: `fn.config.json`

| Key | Type | What it controls |
| --- | --- | --- |
| `runtime` | `string` | Explicit runtime for a function root |
| `name` | `string` | Function name shown in discovery and routes |
| `entrypoint` | `string` | Explicit handler file |
| `assets` | `object` | Static asset behavior for the root |
| `home` | `object` | Folder-level home alias behavior |
| `invoke` | `object` | Route methods, docs metadata, and invoke policy |
| `schedule` | `object` | Cron or interval style scheduling |
| `worker_pool` | `object` | Per-function queue and concurrency control |
| `edge` | `object` | Edge proxy forwarding rules |
| `strict_fs` | `boolean` | Function-level strict filesystem sandbox toggle |
| `zero_config` | `object` | Zero-config discovery knobs such as ignore dirs |
| `zero_config_ignore_dirs` | `array` or `string` | Compatibility alias for extra ignored directories |

## Nested blocks worth knowing

### `assets`

Common fields:

- `directory`
- `not_found_handling`
- `run_worker_first`

Typical use:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

### `invoke`

Common fields:

- `methods`
- `summary`
- `query`
- `body`
- `force_url`

Typical use:

```json
{
  "invoke": {
    "methods": ["GET", "POST"],
    "summary": "Example handler"
  }
}
```

### `worker_pool`

Common fields:

- `enabled`
- `max_workers`
- `min_warm`
- `idle_ttl_seconds`

### `edge`

Used for responses that proxy/forward upstream traffic instead of returning a normal function payload.

## Practical precedence

1. CLI flags and explicit command arguments
2. Environment variables
3. `fastfn.json`
4. `fn.config.json`
5. Runtime defaults

If you are unsure where a setting belongs, check the examples first and then the environment variable reference.

## Related links

- [FastFN config reference](./fastfn-config.md)
- [Environment variables](./environment-variables.md)
- [Architecture](../explanation/architecture.md)
- [Run and test](../how-to/run-and-test.md)
