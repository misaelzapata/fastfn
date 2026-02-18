# CLI Reference

The **fastfn** CLI automates project creation and local development.

## Installation

Ensure you have the binary in your path (e.g., by building with `make build-cli`).

```bash
make build-cli
# Output is located at ./bin/fastfn
export PATH=$PWD/bin:$PATH
```

## Commands

### `init`

Create a new function scaffold.

**Usage:**
```bash
fastfn init <name> -t <runtime>
```

**Arguments:**
- `<name>`: Function directory name.

**Flags:**
- `-t, --template`: `node` (default), `python`, `php`, `lua`, `rust` (experimental).

**Example:**
```bash
fastfn init hello -t node
```

---

### `dev`

Start the development server with hot reload.

**Usage:**
```bash
fastfn dev [directory]
```

**Arguments:**
- `[directory]`: The root directory to scan for functions (default: `.`).

**Flags:**
- `--native`: Run on host using the embedded runtime stack (no Docker).
- `--build`: Build the runtime image before starting (slower).
- `--dry-run`: Print generated `docker-compose.yml` and exit.
- `--force-url`: Allow config/policy routes to override existing mapped URLs.

---

### `run`

Start the server with production-oriented defaults (no hot reload).

**Usage:**
```bash
fastfn run [directory] --native
```

**Flags:**
- `--native`: Run on host (required; Docker production mode is not wired yet).
- `--force-url`: Allow config/policy routes to override existing mapped URLs.

---

### `doctor` (alias: `check`)

Run environment and project diagnostics. Exits non-zero if any check fails.

**Usage:**
```bash
fastfn doctor [subcommand] [flags]
fastfn check [subcommand] [flags]
```

**Subcommands:**
- `domains`: Check DNS configuration for custom domains.

**Flags:**
- `--json`: Print machine-readable JSON output.
- `--fix`: Apply safe local auto-fixes when possible.

**Example:**
```bash
fastfn doctor
fastfn doctor domains --domain api.example.com
fastfn check --json
```

---

### `logs`

Stream logs from a running FastFN stack.

**Usage:**
```bash
fastfn logs
```

**Flags:**
- `--file`: Native log file(s): `error|access|all` (default: `all`).
- `--lines`: Tail N lines (default: 200).
- `--no-follow`: Print current logs and exit (do not follow).
- `--native`: Force native logs backend.
- `--docker`: Force Docker logs backend.

**Example:**
```bash
fastfn logs --native --file error --lines 200
```

---

### `docs`

Open the local Swagger UI (when the server is running).

```bash
fastfn docs
```
