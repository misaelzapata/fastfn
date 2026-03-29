# Lua Examples

Lua handlers run in-process inside the OpenResty gateway, with no external daemon.

## Run

```bash
fastfn dev examples/functions/lua
```

## Routes

| Route | Method | What it does |
|-------|--------|-------------|
| `/session-demo` | GET | Cookie/session inspection. Send `Cookie: session_id=abc123; theme=dark` |

## Handler contract

Lua handlers export a function:

```lua
local function handler(event)
    return {
        status = 200,
        headers = {["Content-Type"] = "application/json"},
        body = '{"hello":"world"}'
    }
end
return handler
```

## Test

```bash
curl -sS http://127.0.0.1:8080/session-demo                                    # 401
curl -sS -H 'Cookie: session_id=abc123; theme=dark' http://127.0.0.1:8080/session-demo  # 200
```
