# Chapter 9 - Shared Dependencies and Shared Config Patterns

Goal: reduce duplication across many functions.

## Shared dependency pack

In function config:

```json
{
  "shared_deps": ["qrcode_pack"]
}
```

Pack location:

`<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/qrcode_pack/package.json`

This allows several functions to reuse the same install.

## Shared env strategy (simple and practical)

Keep per-function `fn.env.json`, but generate it from a base template in CI/CD.

Recommended approach:

1. `env.base.json` in internal tooling repo
2. per-function override files
3. merge script outputs final `fn.env.json`

This keeps runtime simple while avoiding duplicated manual edits.
