# Request Validation and Schemas

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 30-40 minutes
- Outcome: predictable input contracts with clear `400`/`422` errors

## Example handler used in this page

`node/orders/[id]/post.js`:

```js
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

exports.handler = async (event, { id }) => {
  const orderId = Number(id);
  if (!Number.isInteger(orderId) || orderId < 1 || orderId > 999999) {
    return { status: 422, body: { error: "id must be an integer between 1 and 999999" } };
  }

  const source = event.query?.source || "web";
  if (source.length < 2 || source.length > 20) {
    return { status: 422, body: { error: "source length must be between 2 and 20" } };
  }

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch (_err) {
    return { status: 400, body: { error: "invalid JSON body" } };
  }

  if (!body.customer || typeof body.customer.name !== "string") {
    return { status: 422, body: { error: "customer.name is required" } };
  }

  if (!Array.isArray(body.items) || body.items.length === 0) {
    return { status: 422, body: { error: "items must be a non-empty array" } };
  }

  if (body.delivery_date && !ISO_DATE.test(body.delivery_date)) {
    return { status: 422, body: { error: "delivery_date must use YYYY-MM-DD" } };
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

## 1. String query constraints

Rules from the handler:

- `source` default: `"web"`
- min length: `2`
- max length: `20`

```bash
curl -sS -X POST 'http://127.0.0.1:8080/orders/7?source=w' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
```

Expected:

```json
{"error":"source length must be between 2 and 20"}
```

## 2. Numeric path constraints

Rules:

- `id` must be integer
- lower bound: `1`
- upper bound: `999999`

```bash
curl -sS -X POST 'http://127.0.0.1:8080/orders/0' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
```

Expected:

```json
{"error":"id must be an integer between 1 and 999999"}
```

## 3. Path + body contract

| Field | Source | Required | Type | Rule |
|---|---|---|---|---|
| `id` | path | yes | integer | 1..999999 |
| `source` | query | no | string | default `web`, len 2..20 |
| `customer.name` | body | yes | string | non-empty |
| `items` | body | yes | array | at least 1 element |
| `delivery_date` | body | no | string | `YYYY-MM-DD` |

## 4. Schema-like body shape

Minimal valid payload:

```json
{
  "customer": { "name": "Ana" },
  "items": [{ "sku": "A1", "qty": 1 }]
}
```

Missing required field example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/orders/7' -H 'Content-Type: application/json' -d '{"items":[{"sku":"A1","qty":1}]}'
```

Expected:

```json
{"error":"customer.name is required"}
```

## 5. Nested objects and arrays

`customer` is an object and `items` is an array of objects. FastFN forwards raw JSON; nested validation is implemented in handler logic, so behavior is deterministic across runtimes.

## 6. Extra data types and nullability

- `gift` accepts boolean-like input and is normalized with `Boolean(...)`
- `delivery_date` is optional; response uses `null` when missing
- numbers remain numbers in parsed JSON body

## Validation checklist

- Invalid JSON returns `400`
- Contract violations return `422`
- Valid payload returns `201`
- Endpoint appears in OpenAPI at `/openapi.json`

## Related links

- [Part 2: Routing and data](./from-zero/2-routing-and-data.md)
- [Request metadata and files](./request-metadata-and-files.md)
- [HTTP API reference](../reference/http-api.md)
