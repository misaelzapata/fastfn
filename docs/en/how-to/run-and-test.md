# Run and Test

Practical local validation checklist.

## What this validates

- FastFN boots in portable mode (Docker)
- runtimes are healthy
- public routes respond
- OpenAPI + Swagger UI are available
- unit + integration + UI E2E tests pass

## Prerequisites

- Docker Desktop running
- `bin/fastfn` built or installed
- host port `8080` is free

## 1) Automated Testing (Recommended)

The fastest way to validate the entire platform is to run the CI-like pipeline locally:

```bash
bash scripts/ci/test-pipeline.sh
```

If these pass, the platform is healthy.

## 2) Manual Verification

If you prefer to run the stack manually and check endpoints:

### Boot a demo app

```bash
bin/fastfn dev examples/functions/next-style
```

### Verify System Health

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
```

### Verify a public function

Call a JSON endpoint:

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

Optional dependency isolation check:

```bash
bin/fastfn dev examples/functions

curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/qr@v2?text=NodeQR' -o /tmp/qr-node.png

# Force a reinstall (these folders are created at runtime):
rm -rf examples/functions/python/qr/.deps
rm -rf examples/functions/node/qr/v2/node_modules
```

## 3) Verify docs endpoints

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | head -c 300
```

- Swagger: [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)
- Console: [http://127.0.0.1:8080/console](http://127.0.0.1:8080/console)

## 4) Stop clean

```bash
docker compose down --remove-orphans
```

## 5) Function root

FastFN scans the directory you pass to `fastfn dev`.

Recommendations:

- Put your code under `functions/` and run: `fastfn dev functions`
- Or set a default in `fastfn.json` via `functions-dir`
