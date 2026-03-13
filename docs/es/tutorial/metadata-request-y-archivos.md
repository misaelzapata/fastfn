# Metadata de Request y Archivos

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: esta guía refleja el comportamiento actual de FastFN, incluyendo manejo de body raw para forms y multipart.

## Complejidad
Intermedia

## Tiempo
20-30 minutos

## Resultado
Entendés cómo llegan hoy headers, cookies, query, JSON, forms y uploads en FastFN, y dónde el parseo es explícito.

## Validación
1. Levantá runtime local: `fastfn dev examples/functions`.
2. Probá metadata de request:
   ```bash
   curl -sS http://127.0.0.1:8080/request-inspector \
     -H "x-request-id: req-123" \
     -H "Cookie: session_id=abc123; theme=dark"
   ```
3. Probá body JSON:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/tasks \
     -H "Content-Type: application/json" \
     -d '{"title":"Escribir docs","priority":"2"}'
   ```
4. Probá form-urlencoded raw:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/contact \
     -H "Content-Type: application/x-www-form-urlencoded" \
     --data 'name=Misael&role=admin'
   ```

## Solución de problemas
- Si faltan headers, revisá casing y forwarding del proxy.
- Si cookies llegan vacías, verificá que el header `Cookie` alcance FastFN.
- Si falla parseo JSON, validá `Content-Type` y formato del payload.
- Si necesitás multipart parseado, considerá soporte actual como raw-body únicamente.

## Matriz de soporte

| Tipo de input | Estado actual | Cómo llega |
| :--- | :--- | :--- |
| Headers | Soportado | `event.headers` |
| Cookies | Soportado | `event.session.cookies` |
| Query string | Soportado | `event.query` |
| Body JSON | Soportado con parseo explícito | `event.body` string raw |
| Body texto plano | Soportado | `event.body` string raw |
| `application/x-www-form-urlencoded` | Solo raw | `event.body` string raw |
| `multipart/form-data` | Solo raw (sin parser first-class) | `event.body` string raw |
| Payload binario de request | Limitado | no asumir parseo estructurado automático |

## Headers

```text
event.headers
```

Python:
```python

def handler(event):
    headers = event.get("headers") or {}
    return {
        "status": 200,
        "body": {
            "request_id": headers.get("x-request-id"),
            "authorized": bool(headers.get("x-api-key")),
        },
    }
```

Node:
```javascript
exports.handler = async (event) => {
  const headers = event.headers || {};
  return {
    status: 200,
    body: {
      request_id: headers["x-request-id"] || null,
      authorized: Boolean(headers["x-api-key"] || null),
    },
  };
};
```

## Cookies
FastFN expone cookies parseadas en `event.session.cookies`.

```json
{
  "session": {
    "id": "abc123",
    "cookies": {
      "session_id": "abc123",
      "theme": "dark"
    }
  }
}
```

Python:
```python

def handler(event):
    session = event.get("session") or {}
    cookies = session.get("cookies") or {}
    return {"status": 200, "body": {"theme": cookies.get("theme", "light")}}
```

## Body JSON y texto plano
El body llega como texto raw. Parsealo explícitamente.

Python:
```python
import json


def handler(event):
    payload = json.loads(event.get("body") or "{}")
    return {
        "status": 200,
        "body": {
            "title": payload.get("title"),
            "priority": int(payload.get("priority", 1)),
        },
    }
```

Node:
```javascript
exports.handler = async (event) => {
  const payload = JSON.parse(event.body || "{}");
  return {
    status: 200,
    body: {
      title: payload.title || null,
      priority: Number(payload.priority || 1),
    },
  };
};
```

## Forms y multipart
- `application/x-www-form-urlencoded`: disponible como string raw en `event.body`.
- `multipart/form-data`: hoy es raw-only en el contrato gateway; no hay abstracción builtin de campos/archivos.

Recomendación práctica:
1. Preferí JSON para contratos API.
2. Mantené parseo multipart explícito en runtime solo cuando controlás el formato.
3. Para cargas pesadas, usá componentes upstream especializados.

## Límites importantes
- Tamaño de request limitado por `max_body_bytes`.
- La política por función aplica antes de ejecutar el handler.
- Metadata de respuesta (cookies/headers) se define en el envelope de respuesta.

## Enlaces relacionados
- [Contrato runtime](../referencia/contrato-runtime.md)
- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Inputs y Respuestas Tipadas](./inputs-y-respuestas-tipadas.md)
- [Desde Cero: Respuestas Avanzadas](./desde-cero/4-respuestas-avanzadas.md)
