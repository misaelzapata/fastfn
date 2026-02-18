# Capitulo 3 - Variables de Entorno (`fn.env.json`)

Objetivo: configurar valores y secretos por funcion, sin hardcodear en el codigo.

## Paso 1: crea `fn.env.json`

Crea `functions/hello-world/fn.env.json`:

```json
{
  "APP_MODE": { "value": "dev", "is_secret": false },
  "WELCOME_PREFIX": { "value": "Hola", "is_secret": false },
  "MY_API_KEY": { "value": "cambiar-en-local", "is_secret": true }
}
```

`is_secret=true` significa:

- UI/API deberia enmascarar el valor
- igual llega al handler en `event.env`

## Paso 2: usa env en el handler

Edita `functions/hello-world/get.js`:

```js
exports.handler = async (event) => {
  const env = event.env || {};
  const query = event.query || {};
  const name = query.name || "mundo";

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: `${env.WELCOME_PREFIX || "Hola"} ${name}`,
      app_mode: env.APP_MODE || "unknown",
      has_api_key: Boolean(env.MY_API_KEY),
    }),
  };
};
```

## Paso 3: prueba

```bash
curl -sS 'http://127.0.0.1:8080/hello-world?name=Ana'
```

Salida esperada (forma):

```json
{"message":"Hola Ana","app_mode":"dev","has_api_key":true}
```

## Si no ves cambios

1. Confirma el path: `functions/hello-world/fn.env.json`.
2. Confirma que el JSON es valido.
3. Espera unos segundos (hot reload).

