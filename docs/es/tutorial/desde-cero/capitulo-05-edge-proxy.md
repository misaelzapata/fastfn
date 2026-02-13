# Capitulo 5 - Edge Proxy (estilo Workers)

Objetivo: devolver `proxy` desde la funcion y que el gateway haga la llamada saliente.

## Config

```json
{
  "edge": {
    "base_url": "http://127.0.0.1:8080",
    "allow_hosts": ["127.0.0.1:8080"],
    "allow_private": true,
    "max_response_bytes": 1048576
  }
}
```

## Handler

```js
exports.handler = async () => ({
  status: 200,
  proxy: {
    path: "/_fn/health",
    method: "GET",
    headers: { "x-fastfn-edge": "1" }
  }
});
```

## Prueba

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello_world' | jq .
```
