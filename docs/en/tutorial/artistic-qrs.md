# Tutorial: Artistic QR Variants (Optional)

This page adds a PNG variant of the QR function with styling options.

Note: this tutorial is optional and not part of the default quickstart path.

Prerequisite: complete the basic QR tutorial first:

- [`QR in Python + Node (Dependency Isolation)`](./qr-in-python-node.md)

## 1) Create a new version folder (Python)

We will create a new version `v3` so `/fn/qr@v3` is a distinct endpoint.

```bash
mkdir -p srv/fn/functions/python/qr/v3
```

## 2) Optional dependency upgrade (PIL styling)

If you want PIL styling, use:

```text
qrcode[pil]>=7.4
```

Put it in `srv/fn/functions/python/qr/v3/requirements.txt`:

```bash
cat > srv/fn/functions/python/qr/v3/requirements.txt <<'EOF'
qrcode[pil]>=7.4
EOF
```

## 3) Add the handler (PNG base64)

When returning PNG from a handler, use base64 payload (`is_base64=true`).

Create `srv/fn/functions/python/qr/v3/app.py`:

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

## 4) Add function policy (optional, but recommended)

Create `srv/fn/functions/python/qr/v3/fn.config.json`:

```json
{
  "timeout_ms": 60000,
  "max_concurrency": 4,
  "max_body_bytes": 65536,
  "invoke": {
    "methods": ["GET"],
    "summary": "Python QR generator (PNG, styled)",
    "query": {"text": "https://example.com", "style": "round", "fill": "magenta"},
    "body": ""
  }
}
```

## 5) Examples

```text
/fn/qr@v3?url=https://example.com&style=round&fill=magenta
/fn/qr@v3?url=https://example.com&style=circle&fill=green&back=black
```

You can also save a PNG file:

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr@v3?text=Hello' -o /tmp/qr-v3.png
file /tmp/qr-v3.png
```

## 6) Node composition pattern

A Node function can prepare a URL and redirect to `/fn/qr`.

```js
exports.handler = async (event) => {
  const query = event.query || {};
  const phone = query.phone;
  const text = query.text || 'Hello from fastfn';
  if (!phone) {
    return {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'phone query param is required' }),
    };
  }

  const waUrl = `https://wa.me/${phone}?text=${encodeURIComponent(text)}`;
  return {
    status: 302,
    headers: { Location: `/fn/qr@v3?url=${encodeURIComponent(waUrl)}` },
    body: '',
  };
};
```
