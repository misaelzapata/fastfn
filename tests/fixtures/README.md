# Test Fixtures

Canonical fixture root for integration and E2E scenarios.

## Layout

- `nextstyle-clean/`: file-based dynamic routing fixture (Next-style conventions).
- `polyglot-demo/`: mixed runtimes + `fn.routes.json` override fixture.
- `test-integration-config/`: `fastfn.toml` fixture using `functions_dir = "functions"`.
- `test-cfg-config/`: `fastfn.toml` fixture using `functions_dir = "sub"`.
- `test-config-config/`: `fastfn.toml` fixture using `functions_dir = "subdir"`.
- `local-dev-samples/`: migrated local development samples from top-level `test/`.

## Usage

Run integration suite:

```bash
./tests/integration/test-api.sh
```
