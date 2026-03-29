# Inputs y Respuestas Tipadas

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: `fastfn dev --native` requiere runtimes en host; `fastfn dev` usa Docker.

## Complejidad
Intermedia

## Tiempo
20-30 minutos

## Resultado
Podés diseñar contratos de request/response estables en FastFN e implementar normalización de tipos explícita en rutas Python y Node.

## Validación
1. Levantá runtime local: `fastfn dev examples/functions`.
2. Ejecutá una llamada con coerción tipada:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/tasks \
     -H "Content-Type: application/json" \
     -d '{"title":"Escribir docs","priority":"2","done":false}'
   ```
3. Confirmá tipos de salida (`priority` número, `done` boolean).
4. Confirmá visibilidad en OpenAPI (`/openapi.json`) cuando esté habilitado.

## Solución de problemas
- Si aparece error de parseo JSON, verificá `Content-Type` y formato del body.
- Si faltan params, verificá naming de ruta en filesystem (`[id]`, `[slug]`, etc.).
- Si hay diferencias por runtime, normalizá explícitamente dentro del handler.

## Modelo mental
FastFN te da un envelope estable de request y uno estable de response.

Request:
- Los params de ruta vienen del enrutamiento por archivos.
- Query, headers, cookies y body llegan en `event`.
- El body llega raw por defecto y se parsea explícitamente cuando hace falta.

Response:
- Devolvés `status`, `headers`, `body`.
- El `body` contiene tu payload de dominio tipado.

## Patrones de inputs tipados

### Params de ruta
La forma de la ruta es la primera pista de tipos.

Python:
```python

def handler(event, id):
    item_id = int(id)
    return {"status": 200, "body": {"id": item_id}}
```

Node:
```javascript
exports.handler = async (_event, { id }) => {
  return { status: 200, body: { id: Number(id) } };
};
```

### Query + body
Normalizá tipos al principio del handler.

Python:
```python
import json


def handler(event):
    query = event.get("query") or {}
    payload = json.loads(event.get("body") or "{}")

    limit = int(query.get("limit", 10))
    title = str(payload.get("title", "sin-titulo"))
    done = bool(payload.get("done", False))

    return {
        "status": 200,
        "body": {"limit": limit, "title": title, "done": done},
    }
```

Node:
```javascript
exports.handler = async (event) => {
  const query = event.query || {};
  const payload = JSON.parse(event.body || "{}");

  const limit = Number(query.limit || 10);
  const title = String(payload.title || "sin-titulo");
  const done = Boolean(payload.done || false);

  return {
    status: 200,
    body: { limit, title, done },
  };
};
```

### Metadata de request
Usá headers/cookies para auth, tracing, locale y política.

```text
event.headers["authorization"]
event.headers["x-request-id"]
event.session.cookies
event.query
event.body
```

## Patrones de respuestas tipadas
Envelope canónico:

```json
{
  "status": 200,
  "headers": {
    "Content-Type": "application/json"
  },
  "body": {
    "ok": true
  }
}
```

Reglas prácticas:
- Definí `status` explícitamente.
- Usá `headers` para content type y política de respuesta.
- Mantené `body` mínimo, tipado y orientado a cliente.

## Ejemplo end-to-end

```bash
curl -sS -X POST http://127.0.0.1:8080/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Escribir docs","priority":"2","done":false}'
```

Body esperado:
```json
{
  "title": "Escribir docs",
  "priority": 2,
  "done": false
}
```

## Estrategia de validación
1. Convertí primitivos temprano.
2. Validá campos requeridos antes de lógica de negocio.
3. Devolvé errores `400` explícitos cuando falle la conversión.
4. Extraé validación compartida solo cuando realmente se reutilice.

## Enlaces relacionados
- [Inyección Directa de Params](./parametros-directos.md)
- [Enrutamiento por Archivos](./routing.md)
- [Metadata de Request y Archivos](./metadata-request-y-archivos.md)
- [Desde Cero: Enrutamiento y Datos](./desde-cero/2-enrutamiento-y-datos.md)
- [Desde Cero: Respuestas Avanzadas](./desde-cero/4-respuestas-avanzadas.md)
- [API HTTP](../referencia/api-http.md)
