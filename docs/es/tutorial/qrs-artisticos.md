# Tutorial: Variantes de QR con estilo (opcional)

Esta página agrega una variante PNG del generador de QR (con opciones de estilo).

Nota: este tutorial es opcional y no forma parte del camino de inicio rápido.

Prerequisito: completa primero el tutorial base:

- [`QR en Python + Node (aislamiento de dependencias)`](./qr-python-node.md)

## 1) Crear una nueva versión (Python)

Vamos a crear una versión `v3` para que `/qr@v3` sea un endpoint separado.

```bash
mkdir -p functions/python/qr/v3
```

## 2) Dependencia opcional (estilos con PIL)

Si quieres estilos con PIL:

```text
qrcode[pil]>=7.4
```

Guárdalo en `functions/python/qr/v3/requirements.txt`:

```bash
cat > functions/python/qr/v3/requirements.txt <<'EOF'
qrcode[pil]>=7.4
EOF
```

## 3) Handler (PNG base64)

Al devolver PNG desde un handler, usa payload base64 (`is_base64=true`).

Crea `functions/python/qr/v3/app.py`:

```python
import base64
import io
import qrcode
from qrcode.image.styledpil import StyledPilImage
from qrcode.image.styles.moduledrawers import RoundedModuleDrawer, CircleModuleDrawer, GappedSquareModuleDrawer


def handler(event):
    query = event.get("query") or {}
    text = query.get("url") or query.get("text") or "https://example.com"
    fill_color = query.get("fill", "black")
    back_color = query.get("back", "white")
    style = query.get("style", "square")

    if style == "round":
        drawer = RoundedModuleDrawer()
    elif style == "circle":
        drawer = CircleModuleDrawer()
    else:
        drawer = GappedSquareModuleDrawer()

    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=10,
        border=4,
    )
    qr.add_data(text)
    qr.make(fit=True)

    img = qr.make_image(
        image_factory=StyledPilImage,
        module_drawer=drawer,
        fill_color=fill_color,
        back_color=back_color,
    )

    buf = io.BytesIO()
    img.save(buf, format="PNG")

    return {
        "status": 200,
        "headers": {"Content-Type": "image/png"},
        "is_base64": True,
        "body_base64": base64.b64encode(buf.getvalue()).decode("ascii"),
    }
```

## 4) Política de función (opcional, recomendado)

Crea `functions/python/qr/v3/fn.config.json`:

```json
{
  "timeout_ms": 60000,
  "max_concurrency": 4,
  "max_body_bytes": 65536,
  "invoke": {
    "methods": ["GET"],
    "summary": "Generador QR (PNG, estilizado)",
    "query": {"text": "https://example.com", "style": "round", "fill": "magenta"},
    "body": ""
  }
}
```

## 5) Ejemplos

```text
/qr@v3?url=https://example.com&style=round&fill=magenta
/qr@v3?url=https://example.com&style=circle&fill=green&back=black
```

También puedes guardar el PNG:

```bash
curl -sS 'http://127.0.0.1:8080/qr@v3?text=Hola' -o /tmp/qr-v3.png
file /tmp/qr-v3.png
```
