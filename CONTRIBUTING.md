# Contributing

Thanks for contributing.

## Before you start

Read:

- `README.md`
- `docs/en/explanation/architecture.md`

## Recommended workflow

1. Create a branch for your change.
2. Make small, focused changes.
3. Make sure public behavior is documented.
4. Run the full test suite:
   - `make test` or `./scripts/test-all.sh`
   - `./cli/coverage.sh`
5. Open a PR with:
   - Summary of the change
   - Risks/possible regressions
   - Test plan executed

## Technical rules

- Do not introduce dynamic imports/paths from user input.
- Do not allow read/write outside `srv/fn/functions`.
- Maintain the runtime contract:
  - request: `{fn, version, event}`
  - response: `{status, headers, body}` or base64 for binary.
- Maintain `invoke.methods` as source of truth for:
  - gateway (`405`)
  - `/_fn/invoke`
  - OpenAPI/Swagger
- Maintain consistent public routing:
  - public mapped routes (filesystem/manifest) without special prefixes
  - versioning via `/<name>@<version>` when applicable

## PR checklist

- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Coverage updated with no major regressions
- [ ] README updated if API/flow changed
- [ ] `docs/en/explanation/architecture.md` updated if architecture changed
- [ ] No hardcoded secrets in examples

## CI

GitHub Actions workflow: `.github/workflows/ci.yml`

Stages:

1. `unit`: Python (pytest) + Node (Jest) + Go + Lua coverage.
2. `e2e`: Full suite with Docker Compose/OpenResty.
