# AGENTS.md

Guidelines for coding agents working in this repository.

## Scope

- Make focused changes tied to the user request.
- Do not modify unrelated files.
- Do not add temporary artifacts, scratch files, or local-only outputs to the repo.

## Repository Layout

```
cli/                  # Go CLI (dev, run, doctor, init commands)
openresty/            # Lua source for OpenResty gateway
cli/embed/runtime/    # Embedded copy of openresty/ + srv/ (must stay in sync)
srv/fn/runtimes/      # Runtime daemons (python, node, php, rust, go)
examples/functions/   # Example functions (node/, python/, php/, rust/, lua/)
tests/unit/python/    # Python tests (pytest)
tests/unit/node/      # Node tests (Jest)
tests/unit/lua/       # Lua tests (custom runner, runs in Docker)
tests/integration/    # Integration tests (Docker Compose)
docs/en/              # English documentation
docs/es/              # Spanish documentation
scripts/ci/           # CI helper scripts
```

## Runtime Contract

Request (daemon receives via Unix socket frame):
```json
{"fn": "hello", "version": "v1", "event": {"method": "GET", "path": "/hello", "query": {}, "headers": {}, "body": ""}}
```

Response (daemon returns):
```json
{"status": 200, "headers": {"Content-Type": "text/plain"}, "body": "hello"}
```

Binary response uses `is_base64: true` + `body_base64` instead of `body`.

## Embedded File Sync

`openresty/` and `srv/fn/runtimes/` are the source of truth. Their copies under `cli/embed/runtime/` must match exactly. The pre-commit hook checks this automatically. If you modify a runtime or Lua file, copy it to the embedded path too.

## Tests

- **Go**: `cd cli && go test ./...`
- **Python**: `pytest tests/unit/python/ -v` (requires `.venv`)
- **Node**: `npx jest tests/unit/node/` (requires `npm install`)
- **Lua**: `LUA_COVERAGE=1 bash cli/test-lua.sh` (requires Docker)
- **Integration**: `bash tests/integration/test-api.sh` (requires Docker + built binary)

## Code Changes

- Prefer minimal, reversible changes.
- Keep native and embedded runtime behavior aligned.
- If changing contracts or endpoints, add/update tests in the same change.
- Never use `git commit --no-verify` — fix hook failures first.
- Never add `Co-Authored-By: Claude` to commits.

## CI/CD

- CI runs on every push to `main` via `.github/workflows/ci.yml`.
- Coverage gates enforce 100% on all runtimes.
- Keep CI scripts reproducible and non-interactive.

## Session Completion

When ending a work session:

1. Run quality gates (tests, coverage).
2. Commit and push — work is not complete until `git push` succeeds.
3. Do not require `bd sync` as part of session completion in this repo.
4. If push fails, resolve and retry.
