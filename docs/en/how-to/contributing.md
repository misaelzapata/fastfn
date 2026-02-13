# Contributing

Read first:

- `README.md`
- `docs/en/explanation/architecture.md`
- `docs/internal/TASK_QUEUE.md`

Workflow:

1. Create a branch.
2. Keep changes small and focused.
3. Update docs for any public behavior/API change.
4. Run full suite before PR:

```bash
./scripts/test-all.sh
```

PR checklist:

- unit tests pass
- integration tests pass
- README/docs updated
- no hardcoded secrets in examples
- method policy (`invoke.methods`) reflected in gateway and OpenAPI
