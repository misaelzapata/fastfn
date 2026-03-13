# Tutorial: QR in Python + Node (portable pattern for PHP + Lua)


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
This tutorial builds the same function in two runtimes:

- `/qr` (Python, SVG response)
- `/qr@v2` (Node, PNG response)

The goal is to verify runtime-local dependency installation:

- Python installs to `functions/qr/.deps`
- Node installs to `functions/qr/v2/node_modules`

## Prerequisites and scope

- Development mode (`fastfn dev`): Docker CLI + daemon running.
- Native mode (`fastfn dev --native`): OpenResty in `PATH` + host runtimes installed for languages you use.
- This tutorial validates dependency auto-install only (`requirements.txt` / `package.json` per function).
- It does not install host `python`/`node` runtimes.
- The neutral `functions/...` layout used here is compatibility-friendly. If you prefer runtime-specific examples, keep them inside dedicated language tabs.

## 1) Create function folders

```bash
mkdir -p functions/qr
mkdir -p functions/qr/v2
```

## 2) Add per-runtime dependency files

Python requirements:

```bash
cat > functions/qr/requirements.txt <<'EOF'
qrcode>=7.4
EOF
```

Node package:

```bash
cat > functions/qr/v2/package.json <<'EOF'
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

## 3) Add function code

Python `functions/qr/app.py`:

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

Node `functions/qr/v2/app.js`:

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

## 4) Add per-function policy

Python `functions/qr/fn.config.json`:

```json
{
  "timeout_ms": 60000,
  "max_concurrency": 4,
  "max_body_bytes": 65536,
  "invoke": {
    "methods": ["GET"],
    "summary": "Python QR generator (SVG)",
    "query": {"text": "https://github.com/misaelzapata/fastfn"},
    "body": ""
  }
}
```

Node `functions/qr/v2/fn.config.json`:

```json
{
  "timeout_ms": 60000,
  "max_concurrency": 4,
  "max_body_bytes": 65536,
  "invoke": {
    "methods": ["GET"],
    "summary": "Node QR generator (PNG)",
    "query": {"text": "https://github.com/misaelzapata/fastfn", "size": 320},
    "body": ""
  }
}
```

## 5) Validate dependency auto-install and runtime output

You can reset local dependency folders:

```bash
rm -rf functions/qr/.deps functions/qr/v2/node_modules
```

Call both routes:

```bash
curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/qr@v2?text=NodeQR' -o /tmp/qr-node.png
```

Validate payload types:

```bash
file /tmp/qr-python.svg
file /tmp/qr-node.png
```

Validate runtime-local dependency directories:

```bash
test -d functions/qr/.deps/qrcode && echo python-ok
test -d functions/qr/v2/node_modules/qrcode && echo node-ok
```

## 6) What this proves

- Discovery works on public mapped routes, and also supports versioned compatibility routes like `/<name>@<version>`.
- Python and Node can implement the same endpoint independently, and the same contract pattern extends to PHP and Lua handlers.
- Each runtime installs dependencies inside its own function directory.
- Both binary content types are served correctly through the same gateway.

## Flow Diagram

```mermaid
flowchart LR
  A["Client request"] --> B["Route discovery"]
  B --> C["Policy and method validation"]
  C --> D["Runtime handler execution"]
  D --> E["HTTP response + OpenAPI parity"]
```

## Objective

Clear scope, expected outcome, and who should use this page.

## Validation Checklist

- Command examples execute with expected status codes
- Routes appear in OpenAPI where applicable
- References at the end are reachable

## Troubleshooting

- If runtime is down, verify host dependencies and health endpoint
- If routes are missing, re-run discovery and check folder layout

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
