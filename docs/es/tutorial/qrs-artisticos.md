# Tutorial: QRs artisticos (opcional)

Esta pagina extiende `/fn/qr` con opciones de estilo (PNG) en Python.

Nota: es opcional y no forma parte del quickstart.

## Dependencia opcional

Si queres estilos con PIL:

```text
qrcode[pil]>=7.4
```

## Handler (PNG base64)

```python
import base64
import io
import qrcode
from qrcode.image.styledpil import StyledPilImage
from qrcode.image.styles.moduledrawers import RoundedModuleDrawer, CircleModuleDrawer, GappedSquareModuleDrawer


def handler(event):
    query = event.get("query") or {}
    text = query.get("url") or query.get("text") or "https://fastfn.io"
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

## Ejemplos

```text
/fn/qr?url=https://example.com&style=round&fill=magenta
/fn/qr?url=https://example.com&style=circle&fill=green&back=black
```

