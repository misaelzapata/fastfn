# Capitulo 9 - Codigo Compartido y Packs

**Objetivo**: compartir codigo comun (helpers) y dependencias sin duplicar installs por funcion.

## 1) Codigo compartido (simple)

Guarda helpers en `functions/.shared/` para evitar endpoints accidentales.

Crea `functions/.shared/db.js`:

```js
const connect = () => {
  return { status: "connected" };
};

module.exports = { connect };
```

Usalo desde una funcion:

`functions/users/get.js`:

```js
const db = require("../.shared/db");

exports.handler = async () => {
  const conn = db.connect();
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: "Users list", db_status: conn.status }),
  };
};
```

## 2) Packs de dependencias compartidas (`shared_deps`)

Si varias funciones usan lo mismo (por ejemplo `dayjs`, `qrcode`, etc), crea un pack y referencialo.

Estructura:

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/<pack>/package.json
<FN_FUNCTIONS_ROOT>/.fastfn/packs/python/<pack>/requirements.txt
```

Luego en cualquier `fn.config.json`:

```json
{ "shared_deps": ["<pack>"] }
```

## 3) Estrategia simple de env compartido

Cada funcion mantiene su `fn.env.json` propio. Para valores comunes:

- usa una plantilla base en tooling interno
- merge por script en CI/CD
- overrides por funcion

Esto mantiene la runtime simple y evita hardcodeos.

## Regla importante

Usa dot-folders para shared code (por ejemplo `functions/.shared/`).

FastFN ignora dot-folders para routing, evitando rutas publicas tipo `/.shared/*`.

