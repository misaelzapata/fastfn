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
    // Nota: los paths del control-plane (`/_fn/*` y `/console/*`) están bloqueados para edge proxy.
    // Proxeá a un endpoint público (en este tutorial: `/hello`).
    path: "/hello?name=edge",
    method: "GET",
    headers: { "x-fastfn-edge": "1" }
  }
});
```

## Prueba

```bash
curl -sS 'http://127.0.0.1:8080/mi-proxy' | jq .
```
