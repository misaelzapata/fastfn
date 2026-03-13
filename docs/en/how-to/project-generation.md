# Project Generation

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Beginner
- Typical time: 5-10 minutes
- Outcome: reproducible starter project with next steps and validation commands

## Generate a Starter

```bash
mkdir my-fastfn-app
cd my-fastfn-app
fastfn init hello -t node
fastfn dev
```

Then validate:

```bash
curl -sS 'http://127.0.0.1:8080/hello'
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.info'
```

## What `init` Sets Up

- project config (`fastfn.json`)
- functions root
- runtime templates
- discovery-compatible layout

## Validation

- new function is discovered automatically
- request returns `200`
- OpenAPI includes the new route

## Troubleshooting

- If `fastfn` is missing, install CLI and re-open shell.
- If native mode fails, install host deps or use Docker mode.

## Related links

- [First steps](../tutorial/first-steps.md)
- [Your first function](../tutorial/your-first-function.md)
- [Homebrew install](./homebrew.md)
