# auto-infer-python-multi-deps

Small Python example for optional dependency inference with several imports.

What it shows:

- multiple external imports in one handler
- the conservative default `native` backend
- the optional `pipreqs` backend when you want a bootstrap assist
- obvious import-to-package names so the default backend works without aliases

Recommended way to run it:

```bash
FN_PY_INFER_BACKEND=native fastfn dev examples/functions/python
curl -sS 'http://127.0.0.1:8080/auto-infer-python-multi-deps'
```

Optional backend:

```bash
FN_PY_INFER_BACKEND=pipreqs fastfn dev examples/functions/python
```

Notes:

- explicit `requirements.txt` or `#@requirements` stays faster and more predictable
- if your import name differs from the package name, declare it explicitly instead of expecting the default backend to guess
- use this example to compare backends, not as a reason to avoid explicit manifests forever
