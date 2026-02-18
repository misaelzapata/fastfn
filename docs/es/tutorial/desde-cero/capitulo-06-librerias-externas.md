# Capitulo 6 - Librerias Externas (Dependencias)

**Objetivo**: instalar dependencias por funcion (auto-install) y entender los Cold Starts.

## Como funciona

FastFN detecta archivos de dependencias en la carpeta de la funcion e instala automaticamente:

- Node.js: `package.json` -> `npm install` (o `npm ci` si hay `package-lock.json`)
- Python: `requirements.txt` -> `pip install`
- PHP: `composer.json` -> `composer install`

## Ejemplo Node.js

### Paso 1: crea `package.json`

`functions/hello-world/package.json`:

```json
{
  "name": "hello-world",
  "private": true,
  "dependencies": {
    "dayjs": "^1.11.13"
  }
}
```

### Paso 2: usa la libreria

Edita `functions/hello-world/get.js`:

```js
const dayjs = require("dayjs");

exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    message: "Usando dependencia",
    now: dayjs().toISOString(),
  }),
});
```

### Paso 3: invoca (Cold Start)

```bash
curl -sS 'http://127.0.0.1:8080/hello-world'
```

La primera petición después de agregar deps puede tardar más (por la instalación).

## Ejemplo Python

Para no mezclar runtimes en la misma carpeta, crea una función nueva.

Crea:

- `functions/http-client/get.py`
- `functions/http-client/requirements.txt`

`functions/http-client/requirements.txt`:

```text
requests==2.31.0
```

`functions/http-client/get.py`:

```python
import requests

def main(req):
    return {"requests_version": requests.__version__}
```

Prueba:

```bash
curl -sS 'http://127.0.0.1:8080/http-client'
```
