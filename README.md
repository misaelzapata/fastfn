# FastFN

[![CI](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![OpenAPI](https://img.shields.io/badge/OpenAPI-3.1-6BA539?logo=openapiinitiative&logoColor=white)](./docs/en/reference/http-api.md)
[![Runtimes](https://img.shields.io/badge/runtimes-python%20%7C%20node%20%7C%20php%20%7C%20rust%20%7C%20go-0A7EA4)](./docs/en/reference/function-spec.md)

FastFN is a polyglot function runtime with file-based routing, generated OpenAPI, and a production gateway.
It is designed to keep local development simple and deployment behavior predictable.

> [!IMPORTANT]
> picture_here_X_function

## Table of Contents

- [Why FastFN](#why-fastfn)
- [Quick Start (2 commands)](#quick-start-2-commands)
- [Configuration (`fastfn.json`)](#configuration-fastfnjson)
- [Domains and Host Restrictions](#domains-and-host-restrictions)
- [CLI and Test Workflow](#cli-and-test-workflow)
- [Repository Layout](#repository-layout)
- [Documentation](#documentation)
- [License](#license)

## Why FastFN

- File-based routes (`functions/hello/get.py` -> `GET /hello`).
- Same project can mix Python, Node.js, PHP, Rust and Go.
- OpenAPI and Swagger are generated out of the box.
- Internal/admin APIs stay hidden from Swagger by default.
- Native and portable dev modes are aligned under the same CLI.

## Quick Start (2 commands)

1) Create one function:

`functions/hello/get.py`

```python
def main(req):
    name = (req.get("query") or {}).get("name", "World")
    return {"message": f"Hello, {name}!"}
```

2) Run:

```bash
fastfn dev functions
```

Try it:

```bash
curl -sS "http://127.0.0.1:8080/hello?name=Developer"
```

Open docs:

- Swagger UI: `http://127.0.0.1:8080/docs`
- OpenAPI JSON: `http://127.0.0.1:8080/_fn/openapi.json`

### Install

Homebrew:

```bash
brew tap misaelzapata/homebrew-fastfn
brew install fastfn
```

From source:

```bash
cd cli && go build -o ../bin/fastfn
./bin/fastfn --help
```

## Configuration (`fastfn.json`)

FastFN reads `fastfn.json` by default in the current directory.

```json
{
  "functions-dir": "functions",
  "public-base-url": "https://api.example.com",
  "openapi-include-internal": false
}
```

Notes:

- `openapi-include-internal` defaults to `false`.
- You can also control internal OpenAPI visibility via env var `FN_OPENAPI_INCLUDE_INTERNAL`.
- `public-base-url` controls `servers[0].url` in generated OpenAPI.

Full reference: [`docs/en/reference/fastfn-config.md`](./docs/en/reference/fastfn-config.md)

## Domains and Host Restrictions

`domains` in `fastfn.json` is used by doctor checks.
It does not enforce routing restrictions by itself.

For inbound host restrictions, use function config:

`fn.config.json`

```json
{
  "invoke": {
    "allow_hosts": ["api.example.com", "admin.example.com"]
  }
}
```

References:

- [`docs/en/reference/fastfn-config.md`](./docs/en/reference/fastfn-config.md)
- [`docs/en/reference/function-spec.md`](./docs/en/reference/function-spec.md)
- [`docs/en/articles/doctor-domains-and-ci.md`](./docs/en/articles/doctor-domains-and-ci.md)

## CLI and Test Workflow

Common local commands:

```bash
fastfn --help
fastfn dev examples/functions/next-style
```

Project validation:

```bash
cd cli && go test ./...
bash cli/coverage.sh
bash cli/test-all.sh
bash cli/test-playwright.sh
sh scripts/ci/test-pipeline.sh
```

## Repository Layout

- `cli/`: Go CLI source and local test runners.
- `cli/tools/`: utility scripts used during local development and debugging flows.
- `openresty/`: gateway/runtime Lua and console assets.
- `examples/`: runnable function examples and demo workloads.
- `tests/unit/`: runtime and SDK unit-level checks.
- `tests/integration/`: API/OpenAPI/native/hot-reload end-to-end tests.
- `tests/e2e/`: browser/UI tests.
- `tests/stress/`: benchmark runners and performance scenarios.
- `tests/results/`: generated artifacts from automated test runs.
- `docs/`: MkDocs source (`docs/en`, `docs/es`) and theme overrides.

## Documentation

- Start here: [`docs/en/index.md`](./docs/en/index.md)
- First steps: [`docs/en/tutorial/first-steps.md`](./docs/en/tutorial/first-steps.md)
- Routing: [`docs/en/tutorial/routing.md`](./docs/en/tutorial/routing.md)
- CLI reference: [`docs/en/reference/cli.md`](./docs/en/reference/cli.md)
- HTTP/OpenAPI: [`docs/en/reference/http-api.md`](./docs/en/reference/http-api.md)
- Function spec: [`docs/en/reference/function-spec.md`](./docs/en/reference/function-spec.md)
- Architecture: [`docs/en/explanation/architecture.md`](./docs/en/explanation/architecture.md)
- Comparison: [`docs/en/explanation/comparison.md`](./docs/en/explanation/comparison.md)

## License

MIT. See [`LICENSE`](./LICENSE).
