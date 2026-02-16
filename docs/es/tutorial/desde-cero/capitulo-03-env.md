# Capitulo 3 - Variables de Entorno (`fn.env.json`)

Objetivo: configurar secretos y flags por funcion.

## Archivo

`/srv/fn/functions/node/hello-world/fn.env.json`

```json
{
  "APP_MODE": { "value": "dev", "is_secret": false },
  "MY_API_KEY": { "value": "cambiar-en-local", "is_secret": true }
}
```

## Handler

```js
exports.handler = async (event) => {
  const env = event.env || {};
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      app_mode: env.APP_MODE || "unknown",
      has_api_key: Boolean(env.MY_API_KEY),
    }),
  };
};
```

Nota: en la consola/API, `is_secret=true` evita exponer valor.
