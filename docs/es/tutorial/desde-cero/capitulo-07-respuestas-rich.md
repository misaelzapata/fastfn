# Capitulo 7 - Respuestas HTML/CSV/PNG

Objetivo: devolver tipos de contenido reales.

## HTML

```js
return {
  status: 200,
  headers: { "Content-Type": "text/html; charset=utf-8" },
  body: "<h1>Hola</h1><p>UI simple</p>"
};
```

## CSV

```js
return {
  status: 200,
  headers: {
    "Content-Type": "text/csv; charset=utf-8",
    "Content-Disposition": "inline; filename=data.csv"
  },
  body: "name,value\\nfoo,1\\nbar,2\\n"
};
```

## PNG

- Devuelve bytes en base64 + header `image/png` (ver demos `png_demo` y `qr`).
