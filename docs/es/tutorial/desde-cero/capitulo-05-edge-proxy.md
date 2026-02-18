# Capítulo 5 - Edge Proxy (estilo Workers)

**Objetivo**: devolver un `proxy` desde la función para que el gateway haga el fetch por ti.

Es útil cuando quieres:

- validar/auth en tu handler,
- reescribir el request,
- y que OpenResty/Lua haga el HTTP outbound (rapido y controlado).

Comportamiento de seguridad importante:

- el proxy a control-plane esta bloqueado: `/_fn/*` y `/console/*` nunca se permiten.

## Paso 1: crea la funcion proxy

Crea:

- `functions/edge-proxy/get.js`
- `functions/edge-proxy/fn.config.json`

`functions/edge-proxy/fn.config.json`:

```json
{
  "edge": {
    "base_url": "http://127.0.0.1:8080",
    "allow_hosts": ["127.0.0.1:8080", "api.github.com"],
    "allow_private": true
  },
  "invoke": {
    "summary": "Demo edge proxy (auth + passthrough)"
  }
}
```

`functions/edge-proxy/get.js`:

```js
exports.handler = async (event) => {
  const headers = event.headers || {};
  const secret = headers["x-secret"] || headers["X-Secret"];

  if (!secret) {
    return {
      status: 401,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
      body: "Unauthorized (falta x-secret)",
    };
  }

  return {
    proxy: {
      path: "/hello-world?name=edge",
      method: "GET",
      headers: { "x-edge-proxy": "1" },
    },
  };
};
```

## Paso 2: prueba

No autorizado:

```bash
curl -i -sS 'http://127.0.0.1:8080/edge-proxy' | sed -n '1,20p'
```

Autorizado:

```bash
curl -sS 'http://127.0.0.1:8080/edge-proxy' -H 'x-secret: demo'
```

Deberias ver la respuesta de `/hello-world`, entregada a traves de tu funcion.
