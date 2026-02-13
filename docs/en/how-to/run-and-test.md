# Run and Test

Reproducible local validation checklist.

## What this validates

- platform boots in Docker
- runtimes are healthy
- public routes respond
- docs endpoints are available
- smoke + integration + stress smoke pass

## Prerequisites

- Docker Desktop running
- `docker compose` available
- host port `8080` free

## 1) Automated Testing (Recommended)

The fastest way to validate the entire platform is using the built-in test suites.

```bash
# Run Unit Tests (Isolated logic)
make test-unit

# Run Integration Tests (Spin up stack & test endpoints)
make test-integration
```

If these pass, the platform is healthy.

## 2) Manual Verification

If you prefer to run the stack manually and check endpoints:

### Boot platform

```bash
make dev
```

### Verify System Health

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
```

### Verify Test Function

If you initialized a function (e.g., `my-func`), call it:

```bash
curl -sS 'http://127.0.0.1:8080/fn/my-func'
```

Optional dependency isolation check:

```bash
docker compose exec -T openresty sh -lc "rm -rf /app/srv/fn/functions/python/qr/.deps /app/srv/fn/functions/node/qr/v2/node_modules"
curl -sS 'http://127.0.0.1:8080/fn/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' -o /tmp/qr-node.png
docker compose exec -T openresty sh -lc "ls -la /app/srv/fn/functions/python/qr/.deps | head"
docker compose exec -T openresty sh -lc "ls -la /app/srv/fn/functions/node/qr/v2/node_modules | head"
```

## 4) Verify docs endpoints

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | head -c 300
```

- Swagger: [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)
- Console: [http://127.0.0.1:8080/console](http://127.0.0.1:8080/console)

## 5) Run packaged checks

```bash
./scripts/smoke.sh
./scripts/curl-examples.sh
./scripts/stress.sh
```

## 6) Full quality suite

```bash
./scripts/test-all.sh
```

## 7) QR benchmark snapshots

```bash
./scripts/benchmark-qr.sh default
./scripts/benchmark-qr.sh no-throttle
```

Results are stored in `tests/stress/results/`.

Reference report:

- `docs/en/explanation/performance-benchmarks.md`

## 8) Stop clean

```bash
docker compose down --remove-orphans
```

## Notes on configurable function root

Function discovery root is configurable via `FN_FUNCTIONS_ROOT`.

Resolution order:

1. `FN_FUNCTIONS_ROOT`
2. `/app/srv/fn/functions`
3. `$PWD/srv/fn/functions`
4. `/srv/fn/functions`
