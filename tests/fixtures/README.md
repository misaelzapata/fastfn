# Test Fixtures

Canonical fixture root for integration and E2E scenarios.

## Layout

- `nextstyle-clean/`: file-based dynamic routing fixture (Next-style conventions).
- `scheduler-nonblocking/`: scheduled jobs should not block public routes.
- `keep-warm/`: keep-warm scheduler visibility fixture.
- `worker-pool/`: worker pool behavior and observability fixture.
- `dep-isolation/`: per-function deps isolation fixture (node/python/php/rust).
- `local-dev-samples/`: dependency-heavy local fixtures used by coverage/integration flows.
- `local-dev-samples-migrated/`: migrated local development samples previously stored in top-level `test/`.

## Usage

Run integration suite:

```bash
./tests/integration/test-api.sh
```
