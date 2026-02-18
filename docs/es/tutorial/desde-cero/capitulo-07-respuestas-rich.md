# Capítulo 7 - Respuestas HTML/CSV/PNG

**Objetivo**: devolver tipos de contenido reales (no solo JSON).

FastFN respeta tus headers, así que `Content-Type` lo controlas tú.

## 1) HTML

Crea `functions/render-html/get.js`:

```js
exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || "Mundo";
  return {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
    body: `<h1>Hola, ${name}</h1><p>Renderizado por FastFN</p>`,
  };
};
```

Prueba en el browser:

- `http://127.0.0.1:8080/render-html?name=Developer`

## 2) CSV (download)

Crea `functions/data-export/get.js`:

```js
exports.handler = async () => {
  const csv = "id,name,role\n1,Misael,Admin\n2,Ana,User\n";
  return {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="users-export.csv"',
    },
    body: csv,
  };
};
```

Prueba:

```bash
curl -i -sS 'http://127.0.0.1:8080/data-export' | sed -n '1,20p'
```

## 3) Binario (PNG) con base64

Crea `functions/png-demo/get.py`:

```python
PNG_1X1_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
)

def main(req):
    return {
        "status": 200,
        "headers": {"Content-Type": "image/png"},
        "is_base64": True,
        "body_base64": PNG_1X1_BASE64,
    }
```

Prueba:

```bash
curl -sS 'http://127.0.0.1:8080/png-demo' --output out.png
file out.png
```
