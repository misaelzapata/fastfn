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

Creates a new function project structure.

**Usage:**
```bash
fastfn init <function-name> --template <runtime>
```

**Arguments:**
- `<function-name>`: The name of the function (and directory).

**Flags:**
- `-t, --template`: Runtime template to use. Options: `node` (default), `python`, `php`, `rust`.

**Example:**
```bash
fastfn init my-api -t python
```

---

### `dev`

Starts the development server with hot-reloading. It wraps `docker compose` but automatically mounts any function directories found in the current path.

**Usage:**
```bash
fastfn dev [directory]
```

**Arguments:**
- `[directory]`: The root directory to scan for functions (default: `.`).

**Flags:**
- `--dry-run`: Print the generated docker-compose configuration without running it.
- `--force-url`: Allow config/policy routes to override already-mapped URLs (unsafe; prefer fixing route conflicts).

**Behavior:**
1. Scans the target directory using the same discovery rules as the runtime.
2. Uses a dual/hybrid mount strategy:
   - file-based routes: mounts the project root to `/app/srv/fn/functions`
   - `fn.config.json` functions: mounts each function dir to `/app/srv/fn/functions/<runtime>/<name>`
   - mixed projects include both mount styles
3. Starts the stack and tails the logs.

---

### `up` / `down` / `logs`

Use the standard `docker compose` commands or the `Makefile` shortcuts.
