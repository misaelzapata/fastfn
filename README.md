# FastFN

<p align="center">
  Build serverless-style APIs from files.
  <br/>
  Polyglot runtimes, generated OpenAPI, production-ready gateway.
</p>

<p align="center">
  <a href="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml"><img alt="Docs" src="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/misaelzapata/fastfn"><img alt="Coverage" src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg"></a>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-green.svg"></a>
  <a href="./docs/en/reference/http-api.md"><img alt="OpenAPI" src="https://img.shields.io/badge/OpenAPI-3.1-6BA539?logo=openapiinitiative&logoColor=white"></a>
  <a href="./docs/en/reference/function-spec.md"><img alt="Runtimes" src="https://img.shields.io/badge/runtimes-python%20%7C%20node%20%7C%20php%20%7C%20lua%20%7C%20rust%20%7C%20go-0A7EA4"></a>
</p>

<p align="center">
  <a href="./docs/en/index.md"><strong>Documentation</strong></a>
  ·
  <a href="./examples"><strong>Examples</strong></a>
  ·
  <a href="./docs/en/explanation/comparison.md"><strong>Comparison</strong></a>
</p>

> [!IMPORTANT]
> picture_here_X_function

## Table of Contents

- [Why FastFN](#why-fastfn)
- [Highlights](#highlights)
- [Quick Start (2 commands)](#quick-start-2-commands)
- [Install](#install)
- [Configuration (`fastfn.json`)](#configuration-fastfnjson)
- [Domains and Host Restrictions](#domains-and-host-restrictions)
- [CLI and CI/CD](#cli-and-cicd)
- [Quality Checks](#quality-checks)
- [Repository Layout](#repository-layout)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Why FastFN

FastFN is built for teams that want local-file speed with production API behavior.

- Routing from files: `functions/hello/get.py` -> `GET /hello`
- Mix runtimes in one project: Python, Node.js, PHP, Lua, Rust, Go
- OpenAPI and Swagger generated from discovered routes
- Internal/admin endpoints hidden from Swagger by default
- Same CLI surface for native and portable execution modes

| What You Want | With FastFN |
| --- | --- |
| Start fast | One file, one command |
| Scale language choice | Mix runtimes in one API |
| Keep docs current | OpenAPI generated from real routes |
| Keep ops predictable | Gateway + contracts + tests in repo |

## Highlights

- File-based function discovery without maintaining a static route table
- Per-function policy controls (`timeout_ms`, `max_concurrency`, methods, host allowlist)
- OpenAPI + Swagger from live routing catalog
- Polyglot runtime model with aligned request/response contract
- CI-ready checks for unit, integration, e2e, and coverage

## Quick Start (2 commands)

1. Create one function:

`functions/hello/get.py`

```python
def main(req):
    name = (req.get("query") or {}).get("name", "World")
    return {"message": f"Hello, {name}!"}
```

2. Run:

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

## Install

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

FastFN reads `fastfn.json` in the current directory by default.

```json
{
  "functions-dir": "functions",
  "public-base-url": "https://api.example.com",
  "openapi-include-internal": false
}
```

Notes:

- `openapi-include-internal` defaults to `false`
- Env override for internal visibility: `FN_OPENAPI_INCLUDE_INTERNAL`
- `public-base-url` controls `servers[0].url` in generated OpenAPI

Reference:

- [`docs/en/reference/fastfn-config.md`](./docs/en/reference/fastfn-config.md)

## Domains and Host Restrictions

`domains` in `fastfn.json` is used for doctor checks. It does not enforce host filtering by itself.

For runtime host restrictions per function, use `fn.config.json`:

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

## CLI and CI/CD

Common local commands:

```bash
fastfn --help
fastfn dev examples/functions/next-style
```

Release flow:

- CI and docs workflows run on pushes to `main`
- Release workflow runs on tag pushes matching `v*` (for example `v0.1.0`)

## Quality Checks

```bash
cd cli && go test ./...
bash cli/coverage.sh
bash cli/test-all.sh
bash cli/test-playwright.sh
bash tests/integration/test-api.sh
sh scripts/ci/test-pipeline.sh
```

## Repository Layout

- `cli/`: Go CLI source and local test runners
- `cli/tools/`: local helper scripts
- `openresty/`: gateway/runtime Lua and console assets
- `examples/`: runnable examples and demos
- `tests/unit/`: runtime and SDK unit checks
- `tests/integration/`: API/OpenAPI/native/hot-reload checks
- `tests/e2e/`: browser/UI tests
- `tests/stress/`: benchmark scenarios
- `tests/results/`: generated artifacts from test runs
- `docs/`: MkDocs source (`docs/en`, `docs/es`) and theme overrides

## Documentation

- Start: [`docs/en/index.md`](./docs/en/index.md)
- First steps: [`docs/en/tutorial/first-steps.md`](./docs/en/tutorial/first-steps.md)
- Routing: [`docs/en/tutorial/routing.md`](./docs/en/tutorial/routing.md)
- CLI reference: [`docs/en/reference/cli.md`](./docs/en/reference/cli.md)
- HTTP/OpenAPI: [`docs/en/reference/http-api.md`](./docs/en/reference/http-api.md)
- Function spec: [`docs/en/reference/function-spec.md`](./docs/en/reference/function-spec.md)
- Architecture: [`docs/en/explanation/architecture.md`](./docs/en/explanation/architecture.md)
- Comparison: [`docs/en/explanation/comparison.md`](./docs/en/explanation/comparison.md)

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## License

MIT. See [`LICENSE`](./LICENSE).
