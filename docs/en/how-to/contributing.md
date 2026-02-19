# Contributing

## Quick View

- Complexity: Basic
- Typical time: 5-10 minutes
- Use this when: you are preparing a change or pull request
- Outcome: you follow the expected repo workflow and checks


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
