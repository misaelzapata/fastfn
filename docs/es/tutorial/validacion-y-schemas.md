# Validación y Schemas de Request

> Estado verificado al **13 de marzo de 2026**.

## Vista rápida

- Complejidad: Intermedio
- Tiempo típico: 30-40 minutos
- Resultado: contratos de entrada previsibles con errores claros `400`/`422`

## Handler de ejemplo usado en esta página

`node/orders/[id]/post.js`:

```js
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

exports.handler = async (event, { id }) => {
  const orderId = Number(id);
  if (!Number.isInteger(orderId) || orderId < 1 || orderId > 999999) {
    return { status: 422, body: { error: "id debe ser entero entre 1 y 999999" } };
  }

  const source = event.query?.source || "web";
  if (source.length < 2 || source.length > 20) {
    return { status: 422, body: { error: "source debe tener entre 2 y 20 caracteres" } };
  }

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch (_err) {
    return { status: 400, body: { error: "JSON body inválido" } };
  }

  if (!body.customer || typeof body.customer.name !== "string") {
    return { status: 422, body: { error: "customer.name es requerido" } };
  }

  if (!Array.isArray(body.items) || body.items.length === 0) {
    return { status: 422, body: { error: "items debe ser un array no vacío" } };
  }

  if (body.delivery_date && !ISO_DATE.test(body.delivery_date)) {
    return { status: 422, body: { error: "delivery_date debe usar YYYY-MM-DD" } };
  }

  return {
    status: 201,
    body: {
      order_id: orderId,
      source,
      customer: body.customer,
      items: body.items,
      delivery_date: body.delivery_date || null,
      gift: Boolean(body.gift)
    }
  };
};
```

## 1. Restricciones de strings en query

Reglas:

- `source` default: `"web"`
- mínimo: `2` caracteres
- máximo: `20` caracteres

```bash
curl -sS -X POST 'http://127.0.0.1:8080/orders/7?source=w' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
```

Esperado:

```json
{"error":"source debe tener entre 2 y 20 caracteres"}
```

## 2. Restricciones numéricas en path

Reglas:

- `id` debe ser entero
- mínimo: `1`
- máximo: `999999`

```bash
curl -sS -X POST 'http://127.0.0.1:8080/orders/0' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
```

Esperado:

```json
{"error":"id debe ser entero entre 1 y 999999"}
```

## 3. Contrato path + body

| Campo | Origen | Requerido | Tipo | Regla |
|---|---|---|---|---|
| `id` | path | sí | entero | 1..999999 |
| `source` | query | no | string | default `web`, len 2..20 |
| `customer.name` | body | sí | string | no vacío |
| `items` | body | sí | array | al menos 1 elemento |
| `delivery_date` | body | no | string | `YYYY-MM-DD` |

## 4. Forma de body tipo schema

Payload mínimo válido:

```json
{
  "customer": { "name": "Ana" },
  "items": [{ "sku": "A1", "qty": 1 }]
}
```

Caso inválido sin campo requerido:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/orders/7' -H 'Content-Type: application/json' -d '{"items":[{"sku":"A1","qty":1}]}'
```

Esperado:

```json
{"error":"customer.name es requerido"}
```

## 5. Objetos anidados y arrays

`customer` es objeto y `items` es array de objetos. FastFN entrega JSON raw; la validación anidada se implementa en el handler para mantener comportamiento determinista entre runtimes.

## 6. Tipos extra y nulabilidad

- `gift` acepta input booleano y se normaliza con `Boolean(...)`
- `delivery_date` es opcional; en respuesta va `null` si falta
- números se conservan como números en el JSON parseado

## Checklist de validación

- JSON inválido devuelve `400`
- violaciones de contrato devuelven `422`
- payload válido devuelve `201`
- el endpoint aparece en OpenAPI (`/openapi.json`)

## Enlaces relacionados

- [Parte 2: enrutamiento y datos](./desde-cero/2-enrutamiento-y-datos.md)
- [Metadata de request y archivos](./metadata-request-y-archivos.md)
- [Referencia API HTTP](../referencia/api-http.md)
