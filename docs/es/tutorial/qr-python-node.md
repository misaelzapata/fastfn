# Tutorial: QR en Python y Node (aislamiento de dependencias)


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
En este tutorial armamos la misma funcion en dos runtimes:

- `/qr` (Python, responde SVG)
- `/qr@v2` (Node, responde PNG)

La idea es validar instalacion de dependencias por funcion (sin contaminar el sistema):

- Python instala en `functions/python/qr/.deps`
- Node instala en `functions/node/qr/v2/node_modules`

## Requisitos y alcance

- Modo desarrollo (`fastfn dev`): Docker CLI + daemon activos.
- Modo nativo (`fastfn dev --native`): OpenResty en `PATH` + runtimes instalados en el host para los lenguajes que uses.
- Este tutorial valida solo auto-instalacion de dependencias (`requirements.txt` / `package.json` por funcion).
- No instala los runtimes del host (`python`/`node`).
- El layout `functions/python/...` y `functions/node/...` de este tutorial es compatible con flujos versionados; en zero-config por archivos, el runtime se infiere por extension.

## 1) Crear carpetas

```bash
mkdir -p functions/python/qr
mkdir -p functions/node/qr/v2
```

## 2) Agregar archivos de dependencias

Python:

```bash
cat > functions/python/qr/requirements.txt <<'EOF'
qrcode>=7.4
EOF
```

Node:

```bash
cat > functions/node/qr/v2/package.json <<'EOF'
{
  "name": "fn-node-qr-v2",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "qrcode": "^1.5.4"
  }
}
EOF
```

## 3) Codigo de funcion

Python `functions/python/qr/app.py`:

```python
import io
import qrcode
import qrcode.image.svg


def handler(event):
    query = event.get("query") or {}
    text = query.get("url") or query.get("text") or "https://fastfn.io"

    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=8,
        border=2,
    )
    qr.add_data(text)
    qr.make(fit=True)

    img = qr.make_image(image_factory=qrcode.image.svg.SvgImage)
    buf = io.BytesIO()
    img.save(buf)
    svg = buf.getvalue().decode("utf-8")

    return {
        "status": 200,
        "headers": {
            "Content-Type": "image/svg+xml; charset=utf-8",
            "Cache-Control": "no-store",
        },
        "body": svg,
    }
```

Node `functions/node/qr/v2/app.js`:

```javascript
const QRCode = require('qrcode');

exports.handler = async (event) => {
  const query = event.query || {};
  const text = query.url || query.text || 'https://fastfn.io';
  const widthRaw = Number(query.size || 320);
  const width = Number.isFinite(widthRaw) ? Math.max(128, Math.min(1024, Math.floor(widthRaw))) : 320;

  const png = await QRCode.toBuffer(text, {
    type: 'png',
    width,
    margin: 2,
    errorCorrectionLevel: 'M',
  });

  return {
    status: 200,
    headers: {
      'Content-Type': 'image/png',
      'Cache-Control': 'no-store',
    },
    is_base64: true,
    body_base64: png.toString('base64'),
  };
};
```

## 4) Politica por funcion

Python `functions/python/qr/fn.config.json`:

```json
{
  "timeout_ms": 60000,
  "max_concurrency": 4,
  "max_body_bytes": 65536,
  "invoke": {
    "methods": ["GET"],
    "summary": "Generador QR en Python (SVG)",
    "query": {"text": "https://github.com/misaelzapata/fastfn"},
    "body": ""
  }
}
```

Node `functions/node/qr/v2/fn.config.json`:

```json
{
  "timeout_ms": 60000,
  "max_concurrency": 4,
  "max_body_bytes": 65536,
  "invoke": {
    "methods": ["GET"],
    "summary": "Generador QR en Node (PNG)",
    "query": {"text": "https://github.com/misaelzapata/fastfn", "size": 320},
    "body": ""
  }
}
```

## 5) Validar instalacion automatica + respuesta

Podes resetear dependencias:

```bash
rm -rf functions/python/qr/.deps functions/node/qr/v2/node_modules
```

Llamar ambos endpoints:

```bash
curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/qr@v2?text=NodeQR' -o /tmp/qr-node.png
```

Validar tipos:

```bash
file /tmp/qr-python.svg
file /tmp/qr-node.png
```

Validar que quedaron instaladas por funcion:

```bash
test -d functions/python/qr/.deps/qrcode && echo python-ok
test -d functions/node/qr/v2/node_modules/qrcode && echo node-ok
```

## Diagrama de Flujo

```mermaid
flowchart LR
  A["Request del cliente"] --> B["Discovery de rutas"]
  B --> C["Validación de políticas y método"]
  C --> D["Ejecución del handler runtime"]
  D --> E["Respuesta HTTP + paridad OpenAPI"]
```

## Objetivo

Alcance claro, resultado esperado y público al que aplica esta guía.

## Prerrequisitos

- CLI de FastFN disponible
- Dependencias por modo verificadas (Docker para `fastfn dev`, OpenResty+runtimes para `fastfn dev --native`)

## Checklist de Validación

- Los comandos de ejemplo devuelven estados esperados
- Las rutas aparecen en OpenAPI cuando aplica
- Las referencias del final son navegables

## Solución de Problemas

- Si un runtime cae, valida dependencias de host y endpoint de health
- Si faltan rutas, vuelve a ejecutar discovery y revisa layout de carpetas

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
