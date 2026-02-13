# Capitulo 6 - Librerias Externas

Objetivo: usar dependencias de npm/pip por funcion.

## Node

`/srv/fn/functions/node/my_fn/package.json`

```json
{
  "name": "my_fn",
  "private": true,
  "dependencies": {
    "dayjs": "^1.11.13"
  }
}
```

Luego en `app.js`:

```js
const dayjs = require("dayjs");
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ now: dayjs().toISOString() })
});
```

## Python

`requirements.txt`:

```txt
python-dateutil==2.9.0.post0
```

`app.py` usa la libreria y responde JSON.
