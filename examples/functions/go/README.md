# Go Examples

Go handlers are compiled at invocation time by the go-daemon.

## Run

Go is not in the default native runtimes. Enable it with `FN_RUNTIMES`:

```bash
FN_RUNTIMES=go fastfn dev examples/functions/go
```

## Routes

| Route | Method | What it does |
|-------|--------|-------------|
| `/session-demo` | GET | Cookie/session inspection. Send `Cookie: session_id=abc123; theme=dark` |

## Handler contract

Go handlers must export a `handler` function (or `Handler`):

```go
package main

func handler(event map[string]interface{}) interface{} {
    return map[string]interface{}{
        "status":  200,
        "headers": map[string]string{"Content-Type": "application/json"},
        "body":    `{"hello":"world"}`,
    }
}
```

The daemon wraps and compiles this — do not use `func main()` with stdin/stdout.

## Test

```bash
curl -sS http://127.0.0.1:8080/session-demo                                    # 401
curl -sS -H 'Cookie: session_id=abc123; theme=dark' http://127.0.0.1:8080/session-demo  # 200
```
