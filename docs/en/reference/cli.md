# CLI Reference


> Verified status as of **March 22, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes/tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
The **fastfn** CLI is the entrypoint for local development, diagnostics, docs, and scaffolding.

## Quick checks

Print the CLI version:

```bash
fastfn version
fastfn --version
```

Current output format:

```text
FastFN <version>
```

## Installation

Build the binary and place it on your `PATH`:

```bash
make build-cli
export PATH="$PWD/bin:$PATH"
```

The binary is written to `./bin/fastfn`.

## Commands

### `init`

Create a runtime-specific starter scaffold.

**Usage:**

```bash
fastfn init <name> -t <runtime>
```

**Arguments:**

- `<name>`: function directory name.

**Flags:**

- `-t, --template`: `node` (default), `python`, `php`, `lua`, `rust` (experimental).

**Scaffold behavior:**

- `fastfn init hello -t node` creates `./hello/` with `handler.js` and `fn.config.json`.
- `fastfn init hello -t python` creates `./hello/` with `handler.py`, `fn.config.json`, and `requirements.txt`.

The scaffold uses path-neutral layout (no runtime prefix). All templates create `handler.<ext>` with a `handler(event)` function.

**Example:**

```bash
fastfn init hello -t node
fastfn init hello -t python
```

Generated files:

- `fn.config.json`
- `handler.<ext>` (`handler.js`, `handler.py`, `handler.php`, `handler.lua`, or `handler.rs`)
- `requirements.txt` (Python only)

### `dev`

Start the development server with hot reload.

**Usage:**

```bash
fastfn dev [directory]
```

**Arguments:**

- `[directory]`: functions root to scan. Defaults to the current directory, or `fastfn.json` `functions-dir` when configured.

**Flags:**

- `--native`: run on the host using local runtimes instead of Docker.
- `--build`: rebuild the runtime image before starting.
- `--dry-run`: print generated Docker Compose config and exit.
- `--force-url`: allow config/policy routes to override existing mapped URLs.

**Examples:**

```bash
fastfn dev .
fastfn dev functions
fastfn dev --native functions
```

### `run`

Start the stack with production-oriented defaults.

**Usage:**

```bash
fastfn run [directory] --native
```

**Flags:**

- `--native`: required today; production Docker mode is not wired yet.
- `--force-url`: allow config/policy routes to override existing mapped URLs.

Hot reload is **enabled by default**. Precedence: `--hot-reload` flag > `FN_HOT_RELOAD` env > `hot-reload` in `fastfn.json` > default (`true`). Set `FN_HOT_RELOAD=0` to disable.

### `doctor` / `check`

Run environment and project diagnostics. Exit status is non-zero when any check fails.

**Usage:**

```bash
fastfn doctor [subcommand] [flags]
fastfn check [subcommand] [flags]
```

**Subcommands:**

- `domains`: validate DNS setup for custom domains.

**Flags:**

- `--json`: machine-readable JSON output.
- `--fix`: apply safe local auto-fixes when possible.

**Examples:**

```bash
fastfn doctor
fastfn doctor domains --domain api.example.com
fastfn check --json
```

### `logs`

Stream logs from a running FastFN stack.

**Usage:**

```bash
fastfn logs
```

**Flags:**

- `--file`: native log target: `error|access|runtime|all` (default `all`).
- `--lines`: tail line count (default `200`).
- `--no-follow`: print current logs and exit.
- `--native`: force native log backend.
- `--docker`: force Docker log backend.

**Examples:**

```bash
fastfn logs --native --file error --lines 200
fastfn logs --native --file runtime --lines 100
```

Use `--file runtime` when you want the full handler `stdout`/`stderr` stream in native mode.

### `docs`

Open the local Swagger UI when the server is already running.

```bash
fastfn docs
```

## Notes

- `fastfn dev` is the normal development entrypoint.
- `fastfn run --native` is the production-like local mode.
- `fastfn version` and `fastfn --version` are equivalent.
- `fastfn init` creates path-neutral scaffolds with `handler.<ext>` as the entry file.

## See also

- [Function Specification](function-spec.md)
- [HTTP API Reference](http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
