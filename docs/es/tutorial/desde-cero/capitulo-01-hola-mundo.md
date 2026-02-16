# Capitulo 1 - Hola Mundo

Objetivo: publicar una funcion y responder JSON.

## Paso 1: crea la funcion

Ruta sugerida:

`/srv/fn/functions/node/hello-world/app.js`

```js
exports.handler = async (event) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    ok: true,
    message: "Hola fastfn",
    method: event.method,
  }),
});
```

## Paso 2: prueba

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello-world' | jq .
```

## Resultado esperado

- `200 OK`
- JSON con `ok: true`
