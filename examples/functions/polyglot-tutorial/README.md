# Polyglot Tutorial Example (Functions Calling Functions)

This example is a step-by-step composition flow where functions call each other across runtimes.

Routes:

- `GET /polyglot-tutorial/step-1` (Node)
- `GET /polyglot-tutorial/step-2?name=<name>` (Python)
- `GET /polyglot-tutorial/step-3?name=<name>` (PHP)
- `GET /polyglot-tutorial/step-4` (Rust)
- `GET /polyglot-tutorial/step-4/status` (Rust alias)
- `GET /polyglot-tutorial/step-5?name=<name>` (Node orchestrator, calls steps 1-4)

## Run

```bash
./bin/fastfn dev examples/functions
```

## Step-by-step checks

```bash
curl -sS http://127.0.0.1:8080/polyglot-tutorial/step-1 | jq .
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-2?name=Ana' | jq .
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-3?name=Ana' | jq .
curl -sS http://127.0.0.1:8080/polyglot-tutorial/step-4 | jq .
```

Final composed call:

```bash
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-5?name=Ana' | jq .
```

You should get a `flow` array with outputs from all runtimes.
