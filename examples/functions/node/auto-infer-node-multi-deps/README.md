# auto-infer-node-multi-deps

Small Node example for optional dependency inference with several packages.

What it shows:

- multiple package references in one handler
- the default `native` inference backend
- the optional `detective` and `require-analyzer` backends

Recommended way to run it:

```bash
FN_NODE_INFER_BACKEND=native fastfn dev examples/functions/node
curl -sS 'http://127.0.0.1:8080/auto-infer-node-multi-deps'
```

Optional backends:

```bash
FN_NODE_INFER_BACKEND=detective fastfn dev examples/functions/node
FN_NODE_INFER_BACKEND=require-analyzer fastfn dev examples/functions/node
```

Notes:

- explicit `package.json` is still the fastest and most predictable steady-state workflow
- use this example to compare bootstrap options, not to hide dependencies long term
